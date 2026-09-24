import Foundation
import Testing
@testable import ZXAutoPackager

struct ZXAutoPackagerTests {
    @Test func maximumPgyerBuildNumberFiltersVersionAndComparesNumerically() {
        let records = [
            PgyerBuildRecord(buildKey: "a", buildVersion: "1.0", buildVersionNo: "9"),
            PgyerBuildRecord(buildKey: "b", buildVersion: "1.0", buildVersionNo: "10"),
            PgyerBuildRecord(buildKey: "c", buildVersion: "2.0", buildVersionNo: "100"),
            PgyerBuildRecord(buildKey: "d", buildVersion: "1.0", buildVersionNo: "invalid")
        ]

        #expect(PgyerUploader.maximumBuildNumber(in: records, matching: "1.0") == 10)
    }

    @Test func parsesXcodeBuildVersionFromApplicationTarget() throws {
        let output = """
        xcodebuild note
        [
          {
            "target": "MyAppTests",
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test",
              "MARKETING_VERSION": "9.9",
              "CURRENT_PROJECT_VERSION": "999"
            }
          },
          {
            "target": "MyApp",
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "MARKETING_VERSION": "1.2.3",
              "CURRENT_PROJECT_VERSION": "42"
            }
          }
        ]
        """

        let version = try XcodePackager.parseBuildVersion(from: output, scheme: "MyApp")

        #expect(version.marketingVersion == "1.2.3")
        #expect(version.currentProjectVersion == "42")
    }

    @Test func parsesProjectAndWorkspaceSchemes() throws {
        let project = #"{ "project": { "name": "Demo", "schemes": ["App", "App-Debug"] } }"#
        let workspace = #"{ "workspace": { "name": "Demo", "schemes": ["WorkspaceApp"] } }"#
        #expect(try XcodePackager.parseSchemes(from: project) == ["App", "App-Debug"])
        #expect(try XcodePackager.parseSchemes(from: workspace) == ["WorkspaceApp"])
    }

    @Test func platformDestinationsAndArtifacts() {
        #expect(PackagePlatform.iOS.destination == "generic/platform=iOS")
        #expect(PackagePlatform.macOS.destination == "generic/platform=macOS")
        #expect(PackagePlatform.iOS.artifactType == "IPA")
        #expect(PackagePlatform.macOS.artifactType == "ZIP")
    }

    @Test func findsAppInMacOSArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Products/Applications/Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(XcodePackager.findArchivedApp(in: root)?.standardizedFileURL == app.standardizedFileURL)
    }

    @Test func feishuWebhookRejectsUntrustedHosts() {
        #expect(FeishuNotifier.validWebhook("https://open.feishu.cn/open-apis/bot/v2/hook/example") != nil)
        #expect(FeishuNotifier.validWebhook("https://open.feishu.cn.evil.example/open-apis/bot/v2/hook/example") == nil)
        #expect(FeishuNotifier.validWebhook("http://open.feishu.cn/open-apis/bot/v2/hook/example") == nil)
    }

    @Test func feishuMessageContainsBuildAndDownloadInformation() {
        let result = PackageResult(
            artifactPath: "/tmp/Demo.ipa",
            fileSize: 1024,
            versionNumber: "1.2.3",
            buildNumber: 42,
            configuration: "Release",
            log: ""
        )
        let notification = FeishuNotification(
            scheme: "Demo",
            platform: .iOS,
            result: result,
            downloadURL: "https://www.pgyer.com/demo",
            updateDescription: "修复问题"
        )
        let card = FeishuNotifier.messageContent(notification, imageKey: "img_test")
        let elements = card["elements"] as? [[String: Any]]
        let text = (elements?.first?["text"] as? [String: String])?["content"] ?? ""
        #expect(text.contains("Demo.ipa"))
        #expect(text.contains("1.2.3"))
        #expect(text.contains("42"))
        #expect(text.contains("https://www.pgyer.com/demo"))
        #expect(elements?.contains { $0["tag"] as? String == "img" && $0["img_key"] as? String == "img_test" } == true)
        let cardWithoutImage = FeishuNotifier.messageContent(notification, imageKey: "")
        #expect((cardWithoutImage["elements"] as? [[String: Any]])?.count == 1)
    }

    @Test func maximumPgyerBuildNumberReturnsNilWithoutMatchingBuild() {
        let records = [
            PgyerBuildRecord(buildKey: "a", buildVersion: "2.0", buildVersionNo: "3")
        ]

        #expect(PgyerUploader.maximumBuildNumber(in: records, matching: "1.0") == nil)
    }
}
