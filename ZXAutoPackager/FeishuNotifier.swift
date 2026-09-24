import Foundation

struct FeishuNotification: Sendable {
    let scheme: String
    let platform: PackagePlatform
    let result: PackageResult
    let downloadURL: String?
    let updateDescription: String
}

enum FeishuNotifyError: LocalizedError {
    case invalidWebhook
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidWebhook: return "飞书 Webhook 必须是飞书开放平台的 HTTPS 机器人地址。"
        case .invalidResponse(let message): return "飞书通知失败：\(message)"
        }
    }
}

nonisolated enum FeishuNotifier {
    static func validWebhook(_ value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme == "https",
              ["open.feishu.cn", "open.larksuite.com"].contains(url.host?.lowercased() ?? ""),
              url.path.hasPrefix("/open-apis/bot/v2/hook/") else { return nil }
        return url
    }

    static func send(
        _ notification: FeishuNotification,
        webhook: String,
        imageKey: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let url = validWebhook(webhook) else { throw FeishuNotifyError.invalidWebhook }
        let card = messageContent(notification, imageKey: imageKey)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "msg_type": "interactive",
            "card": card
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(data, response: response)
        onOutput("飞书卡片发送成功\(imageKey.isEmpty ? "（无图片）" : "（含图片）")。\n")
    }

    static func messageContent(_ notification: FeishuNotification, imageKey: String) -> [String: Any] {
        let result = notification.result
        let fileName = URL(fileURLWithPath: result.artifactPath).lastPathComponent
        let size = ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file)
        var lines = [
            "**应用：** \(notification.scheme)（\(notification.platform.rawValue)）",
            "**文件：** \(fileName)（\(size)）",
            "**版本：** \(result.versionNumber)　**Build：** \(result.buildNumber)　**环境：** \(result.configuration)"
        ]
        if let downloadURL = notification.downloadURL {
            lines.append("**下载地址：** [点击下载](\(downloadURL))")
        } else {
            lines.append("**下载地址：** 未上传蒲公英，暂无公网下载链接")
        }
        if !notification.updateDescription.isEmpty {
            lines.append("**更新说明：** \(notification.updateDescription)")
        }
        let text: [String: Any] = [
            "tag": "div", "text": ["tag": "lark_md", "content": lines.joined(separator: "\n")]
        ]
        let key = imageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var elements: [[String: Any]] = [text]
        if !key.isEmpty {
            elements = [[
                "tag": "column_set",
                "flex_mode": "none",
                "columns": [
                    [
                        "tag": "column",
                        "width": "weighted",
                        "weight": 1,
                        "elements": [[
                            "tag": "img",
                            "img_key": key,
                            "alt": ["tag": "plain_text", "content": "打包下载图片"]
                        ]]
                    ],
                    [
                        "tag": "column",
                        "width": "weighted",
                        "weight": 4,
                        "elements": [text]
                    ]
                ]
            ]]
        }
        return [
            "header": ["title": ["tag": "plain_text", "content": "打包完成 · \(notification.scheme)"]],
            "elements": elements
        ]
    }

    @discardableResult
    private static func checkResponse(_ data: Data, response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else {
            throw FeishuNotifyError.invalidResponse("无效的 HTTP 响应")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["msg"] as? String) ?? (json?["message"] as? String) ?? "HTTP \(http.statusCode)"
        guard (200..<300).contains(http.statusCode) else {
            throw FeishuNotifyError.invalidResponse(message)
        }
        if let code = json?["code"] as? Int, code != 0 {
            throw FeishuNotifyError.invalidResponse("\(code)：\(message)")
        }
        guard let json else { throw FeishuNotifyError.invalidResponse("响应不是 JSON") }
        return json
    }
}
