import Foundation

struct PgyerUploadRequest: Sendable {
    let apiKey: String
    let ipaPath: String
    let updateDescription: String
}

struct PgyerUploadResult: Sendable {
    let appName: String
    let version: String
    let buildNumber: String
    let downloadURL: String
}

enum PgyerUploadError: LocalizedError {
    case invalidResponse(String)
    case apiError(Int, String)
    case uploadFailed(String)
    case processingTimeout

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): return "蒲公英响应解析失败：\(message)"
        case .apiError(let code, let message): return "蒲公英 API 错误（\(code)）：\(message)"
        case .uploadFailed(let message): return "IPA 上传失败：\(message)"
        case .processingTimeout: return "IPA 已上传，但蒲公英处理超时，请稍后到蒲公英后台查看。"
        }
    }
}

nonisolated enum PgyerUploader {
    private static let apiBaseURL = URL(string: "https://api.pgyer.com/apiv2")!
    private static let webBaseURL = "https://www.pgyer.com/"

    static func upload(
        _ request: PgyerUploadRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> PgyerUploadResult {
        onOutput("\n===== 上传到蒲公英 =====\n")
        onOutput("正在获取上传凭证…\n")
        let token = try await getUploadToken(request)

        onOutput("正在上传 IPA…\n")
        try await uploadFile(at: request.ipaPath, token: token)
        onOutput("IPA 上传完成，等待蒲公英解析…\n")

        for attempt in 1...60 {
            do {
                let result = try await getBuildInfo(apiKey: request.apiKey, buildKey: token.buildKey)
                onOutput("蒲公英处理完成：\(result.downloadURL)\n")
                return result
            } catch PgyerUploadError.apiError(let code, _) where code == 1246 || code == 1247 {
                onOutput("蒲公英处理中（\(attempt)/60）…\n")
                try await Task.sleep(for: .seconds(1))
            }
        }

        throw PgyerUploadError.processingTimeout
    }

    private struct UploadToken: Sendable {
        let endpoint: URL
        let buildKey: String
        let uploadKey: String
        let signature: String
        let securityToken: String
    }

    private static func getUploadToken(_ request: PgyerUploadRequest) async throws -> UploadToken {
        let url = apiBaseURL.appendingPathComponent("app/getCOSToken")
        var fields = [
            "_api_key": request.apiKey,
            "buildType": "ipa",
            "buildInstallType": "1"
        ]
        if !request.updateDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields["buildUpdateDescription"] = request.updateDescription
        }

        let responseData = try await postForm(url: url, fields: fields)
        let response = try decodeAPIResponse(responseData)
        guard response.code == 0,
              let data = response.data,
              let endpointString = data.endpoint,
              let endpoint = URL(string: endpointString),
              let buildKey = data.key,
              let params = data.params,
              let uploadKey = params.key,
              let signature = params.signature,
              let securityToken = params.securityToken else {
            throw PgyerUploadError.apiError(response.code, response.message ?? "无法获取上传凭证")
        }

        return UploadToken(
            endpoint: endpoint,
            buildKey: buildKey,
            uploadKey: uploadKey,
            signature: signature,
            securityToken: securityToken
        )
    }

    private static func uploadFile(at path: String, token: UploadToken) async throws {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PgyerUploadError.uploadFailed("IPA 文件不存在")
        }

        let boundary = "ZXAutoPackager-\(UUID().uuidString)"
        var request = URLRequest(url: token.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let temporaryBodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PgyerUpload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporaryBodyURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporaryBodyURL) }

        let handle = try FileHandle(forWritingTo: temporaryBodyURL)
        defer { try? handle.close() }

        try writeField("key", value: token.uploadKey, boundary: boundary, to: handle)
        try writeField("signature", value: token.signature, boundary: boundary, to: handle)
        try writeField("x-cos-security-token", value: token.securityToken, boundary: boundary, to: handle)
        try writeField("x-cos-meta-file-name", value: fileURL.lastPathComponent, boundary: boundary, to: handle)
        try handle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))

        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? readHandle.close() }
        while let chunk = try readHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try handle.synchronize()

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: temporaryBodyURL)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 204 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PgyerUploadError.uploadFailed("HTTP 状态码 \(code)")
        }
    }

    private static func getBuildInfo(apiKey: String, buildKey: String) async throws -> PgyerUploadResult {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("app/buildInfo"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "_api_key", value: apiKey),
            URLQueryItem(name: "buildKey", value: buildKey)
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let response = try decodeAPIResponse(data)
        guard response.code == 0, let build = response.data else {
            throw PgyerUploadError.apiError(response.code, response.message ?? "处理中")
        }

        let shortcut = build.buildShortcutURL ?? ""
        return PgyerUploadResult(
            appName: build.buildName ?? "",
            version: build.buildVersion ?? "",
            buildNumber: build.buildVersionNo ?? "",
            downloadURL: webBaseURL + shortcut
        )
    }

    private static func postForm(url: URL, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { key, value in
                "\(formEncode(key))=\(formEncode(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func writeField(
        _ name: String,
        value: String,
        boundary: String,
        to handle: FileHandle
    ) throws {
        let content = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        try handle.write(contentsOf: Data(content.utf8))
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func decodeAPIResponse(_ data: Data) throws -> APIResponse {
        do {
            return try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            let raw = String(decoding: data, as: UTF8.self)
            throw PgyerUploadError.invalidResponse(raw)
        }
    }

    private struct APIResponse: Decodable {
        let code: Int
        let message: String?
        let data: ResponseData?
    }

    private struct ResponseData: Decodable {
        let endpoint: String?
        let key: String?
        let params: UploadParams?
        let buildName: String?
        let buildVersion: String?
        let buildVersionNo: String?
        let buildShortcutURL: String?

        enum CodingKeys: String, CodingKey {
            case endpoint
            case key
            case params
            case buildName
            case buildVersion
            case buildVersionNo
            case buildShortcutURL = "buildShortcutUrl"
        }
    }

    private struct UploadParams: Decodable {
        let key: String?
        let signature: String?
        let securityToken: String?

        enum CodingKeys: String, CodingKey {
            case key
            case signature
            case securityToken = "x-cos-security-token"
        }
    }
}
