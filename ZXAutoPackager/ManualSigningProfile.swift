import CryptoKit
import Foundation
import Security

nonisolated struct ManualSigningProfile: Sendable {
    let uuid: String
    let name: String
    let teamID: String
    let appIdentifier: String
    let expiration: Date
    let exportMethod: String
    let certificateHash: String

    static func installedURL(for uuid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)
            .appendingPathComponent("\(uuid).mobileprovision")
    }

    static func read(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw PackageError.invalidInput("描述文件为空。") }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw PackageError.invalidInput("无法解析描述文件。")
        }
        let update = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        var content: CFData?
        guard update == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content,
              let info = try PropertyListSerialization.propertyList(from: content as Data, options: [], format: nil) as? [String: Any],
              let uuid = info["UUID"] as? String, UUID(uuidString: uuid) != nil,
              let name = info["Name"] as? String, !name.isEmpty,
              let teamID = (info["TeamIdentifier"] as? [String])?.first, !teamID.isEmpty,
              let entitlements = info["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              appID.hasPrefix(teamID + "."),
              let expiration = info["ExpirationDate"] as? Date,
              let certificates = info["DeveloperCertificates"] as? [Data], !certificates.isEmpty else {
            throw PackageError.invalidInput("描述文件缺少有效的 UUID、Team、App ID 或签名证书。")
        }
        guard expiration > Date() else { throw PackageError.invalidInput("描述文件已过期。") }
        let isDevelopment = entitlements["get-task-allow"] as? Bool == true
        let method: String
        if isDevelopment {
            method = "debugging"
        } else if info["ProvisionsAllDevices"] as? Bool == true {
            method = "enterprise"
        } else if info["ProvisionedDevices"] as? [String] != nil {
            method = "release-testing"
        } else {
            method = "app-store-connect"
        }
        let hashes = certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
        guard let hash = hashes.first(where: { hasIdentity(sha1: $0) }) else {
            throw PackageError.invalidInput("钥匙串中找不到描述文件允许的签名证书及其私钥，请先安装匹配的证书。")
        }
        return Self(uuid: uuid, name: name, teamID: teamID, appIdentifier: appID,
                    expiration: expiration, exportMethod: method, certificateHash: hash)
    }

    static func load(uuid: String) throws -> Self {
        guard UUID(uuidString: uuid) != nil else { throw PackageError.invalidInput("保存的描述文件 UUID 无效。") }
        let url = installedURL(for: uuid)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PackageError.invalidInput("所选描述文件已不存在，请在高级选项重新选择。")
        }
        let profile = try read(Data(contentsOf: url))
        guard profile.uuid.caseInsensitiveCompare(uuid) == .orderedSame else {
            throw PackageError.invalidInput("已安装描述文件与保存的 UUID 不一致。")
        }
        return profile
    }

    func validate(bundleID: String) throws {
        guard matches(bundleID: bundleID) else {
            throw PackageError.invalidInput("描述文件的 App ID \(appIdentifier) 与工程 Bundle ID \(bundleID) 不匹配。")
        }
        guard Self.hasIdentity(sha1: certificateHash) else {
            throw PackageError.invalidInput("钥匙串中找不到所选描述文件匹配的证书及私钥。")
        }
    }

    func matches(bundleID: String) -> Bool {
        let suffix = String(appIdentifier.dropFirst(teamID.count + 1))
        return suffix == bundleID || (suffix.hasSuffix("*") && bundleID.hasPrefix(suffix.dropLast()))
    }

    private static func hasIdentity(sha1: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return false }
        return identities.contains { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { return false }
            let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02X", $0) }.joined()
            return hash == sha1
        }
    }
}
