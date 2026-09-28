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

    @Test func manualSigningRejectsExtensionAndUsesAppBundleID() throws {
        let app = #"{"target":"App","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","PRODUCT_BUNDLE_IDENTIFIER":"com.example.app"}}"#
        let extensionTarget = #"{"target":"Share","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.app-extension","PRODUCT_BUNDLE_IDENTIFIER":"com.example.app.share"}}"#
        #expect(try XcodePackager.manualSigningBundleID(from: "[\(app)]") == "com.example.app")
        #expect(throws: PackageError.self) {
            try XcodePackager.manualSigningBundleID(from: "[\(app),\(extensionTarget)]")
        }
    }

    @Test func manualSigningChangesOnlyAppTargetConfiguration() throws {
        let source = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ZXAutoPackager.xcodeproj/project.pbxproj"))
        let profile = ManualSigningProfile(uuid: UUID().uuidString, name: "Demo", teamID: "TEAM",
            appIdentifier: "TEAM.com.example.app", expiration: .distantFuture,
            exportMethod: "debugging", certificateHash: "ABC123")
        let changed = try XcodePackager.manuallySignedProject(
            source, targetName: "ZXAutoPackager", configuration: "Debug", profile: profile
        )
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let projectURL = temporaryRoot.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try changed.write(to: projectURL.appendingPathComponent("project.pbxproj"))
        let schemes = try XcodePackager.listSchemes(containerPath: temporaryRoot.path)
        #expect(schemes.contains("ZXAutoPackager"))
        let original = try PropertyListSerialization.propertyList(from: source, format: nil) as! [String: Any]
        let edited = try PropertyListSerialization.propertyList(from: changed, format: nil) as! [String: Any]
        let originalObjects = original["objects"] as! [String: [String: Any]]
        let editedObjects = edited["objects"] as! [String: [String: Any]]
        let changedIDs = editedObjects.keys.filter { id in
            let old = originalObjects[id] as NSDictionary?
            return old?.isEqual(to: editedObjects[id] ?? [:]) == false
        }
        #expect(changedIDs.count == 1)
        let buildSettings = editedObjects[changedIDs[0]]?["buildSettings"] as? [String: Any]
        #expect(buildSettings?["PROVISIONING_PROFILE_SPECIFIER"] as? String == profile.uuid)
        #expect(buildSettings?["CODE_SIGN_STYLE"] as? String == "Manual")
        #expect(buildSettings?["DEVELOPMENT_TEAM"] as? String == "TEAM")
    }

    @Test func reportsActualArchivedSigningMismatch() throws {
        let profile = ManualSigningProfile(uuid: UUID().uuidString, name: "Selected", teamID: "TEAM1",
            appIdentifier: "TEAM1.com.example.app", expiration: .distantFuture,
            exportMethod: "debugging", certificateHash: "")
        try XcodePackager.validateArchivedSigning(
            selected: profile, archivedTeamID: "TEAM1", archivedProfileName: "Selected",
            archivedProfileUUID: profile.uuid.lowercased()
        )
        do {
            try XcodePackager.validateArchivedSigning(
                selected: profile, archivedTeamID: "TEAM2", archivedProfileName: "Archived",
                archivedProfileUUID: UUID().uuidString
            )
            Issue.record("应报告 Team 不一致")
        } catch {
            #expect(error.localizedDescription.contains("归档 Team"))
            #expect(error.localizedDescription.contains("Selected"))
            #expect(error.localizedDescription.contains("Archived"))
            #expect(error.localizedDescription.contains("TEAM1"))
            #expect(error.localizedDescription.contains("TEAM2"))
        }
        do {
            try XcodePackager.validateArchivedSigning(
                selected: profile, archivedTeamID: "TEAM1", archivedProfileName: "Archived",
                archivedProfileUUID: "OTHER-UUID"
            )
            Issue.record("应报告描述文件不一致")
        } catch {
            #expect(error.localizedDescription.contains("归档描述文件"))
            #expect(error.localizedDescription.contains(profile.uuid))
            #expect(error.localizedDescription.contains("OTHER-UUID"))
        }
    }

    @Test func manualSigningMatchesExactAndWildcardAppIDs() {
        let exact = ManualSigningProfile(uuid: UUID().uuidString, name: "Demo", teamID: "TEAM",
            appIdentifier: "TEAM.com.example.app", expiration: .distantFuture,
            exportMethod: "debugging", certificateHash: "")
        let wildcard = ManualSigningProfile(uuid: UUID().uuidString, name: "Demo", teamID: "TEAM",
            appIdentifier: "TEAM.com.example.*", expiration: .distantFuture,
            exportMethod: "debugging", certificateHash: "")
        #expect(exact.matches(bundleID: "com.example.app"))
        #expect(!exact.matches(bundleID: "com.example.other"))
        #expect(wildcard.matches(bundleID: "com.example.app"))
        #expect(!wildcard.matches(bundleID: "com.other.app"))
        #expect(ManualSigningProfile.eligibleProfiles(from: [wildcard, exact], bundleID: "com.example.app").count == 2)
        #expect(ManualSigningProfile.eligibleProfiles(from: [wildcard, exact], bundleID: "com.other.app").isEmpty)
        #expect(ManualSigningProfile.eligibleProfiles(from: [wildcard, exact], bundleID: nil).isEmpty)
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

    @Test func copiesAllArchivedDSYMsBesideIPA() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("App.xcarchive", isDirectory: true)
        let artifacts = root.appendingPathComponent("Artifacts", isDirectory: true)
        for name in ["Sample.app.dSYM", "Extension.appex.dSYM"] {
            let symbol = archive.appendingPathComponent("dSYMs/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: symbol, withIntermediateDirectories: true)
            try Data("symbols".utf8).write(to: symbol.appendingPathComponent("marker"))
        }
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        try XcodePackager.copyArchivedDSYMs(from: archive, to: artifacts)

        for name in ["Sample.app.dSYM", "Extension.appex.dSYM"] {
            let copied = artifacts.appendingPathComponent("dSYMs/\(name)/marker")
            #expect(try String(contentsOf: copied, encoding: .utf8) == "symbols")
        }
    }

    @Test func reportsMissingArchivedDSYMs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: PackageError.self) {
            try XcodePackager.copyArchivedDSYMs(from: root, to: root)
        }
    }

    @Test func savesArchiveInXcodeDateFolderWithoutOverwritingExistingArchives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("App.xcarchive", isDirectory: true)
        let archives = root.appendingPathComponent("Archives", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("Info.plist"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = try XcodePackager.xcodeArchiveURL(for: "Sample", in: archives, at: date)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existing.appendingPathComponent("Info.plist"))

        let saved = try XcodePackager.saveXcodeArchive(from: source, for: "Sample", in: archives, at: date)

        #expect(saved.deletingLastPathComponent().lastPathComponent.count == 10)
        #expect(saved.pathExtension == "xcarchive")
        #expect(saved.lastPathComponent.hasPrefix("Sample "))
        #expect(saved.lastPathComponent.hasSuffix(" 2.xcarchive"))
        #expect(try String(contentsOf: existing.appendingPathComponent("Info.plist"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: saved.appendingPathComponent("Info.plist"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: source.path))
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
        let columns = elements?.first?["columns"] as? [[String: Any]]
        let image = (columns?.first?["elements"] as? [[String: Any]])?.first
        let textElement = (columns?.last?["elements"] as? [[String: Any]])?.first
        let text = (textElement?["text"] as? [String: String])?["content"] ?? ""
        #expect(text.contains("Demo.ipa"))
        #expect(text.contains("1.2.3"))
        #expect(text.contains("42"))
        #expect(text.contains("https://www.pgyer.com/demo"))
        #expect(elements?.first?["tag"] as? String == "column_set")
        #expect(columns?.first?["weight"] as? Int == 1)
        #expect(columns?.last?["weight"] as? Int == 4)
        #expect(image?["tag"] as? String == "img")
        #expect(image?["img_key"] as? String == "img_test")
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
