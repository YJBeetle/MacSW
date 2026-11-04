import Foundation
import XCTest
@testable import MacSWCore

final class AIConnectionInfoTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Volumes/External Apps/My MacSW.app")
    private let paths = AppPaths(appSupportDirectory: URL(fileURLWithPath: "/tmp/MacSW AI support"))

    func testPathsFollowCurrentAppAndActiveContainer() {
        let information = AIConnectionInfo(bundleURL: app, paths: paths)
        XCTAssertEqual(information.app, app)
        XCTAssertEqual(information.cli.path, app.path + "/Contents/MacOS/sw-cli")
        XCTAssertEqual(
            information.skillDirectory.path,
            app.path + "/Contents/Resources/SWCLI/skills/macsw"
        )
        XCTAssertEqual(information.skillEntry.path, information.skillDirectory.path + "/SKILL.md")
        XCTAssertEqual(information.usageGuide.path, information.skillDirectory.path + "/references/usage.md")
        XCTAssertEqual(information.pathHelper.path, app.path + "/Contents/Resources/SWCLI/bin/swcli-path")
        XCTAssertEqual(information.apiGuide.path, information.skillDirectory.path + "/references/solidworks-api.md")
        for url in [information.cli, information.skillDirectory, paths.bottle] {
            XCTAssertTrue(information.text.contains(url.path), url.path)
        }
        XCTAssertFalse(information.text.contains("/Applications/MacSW.app"))
    }

    func testPromptInstallsUserSkillWithoutOperatingDocuments() {
        let text = AIConnectionInfo(bundleURL: app, paths: paths).text
        XCTAssertTrue(text.contains("用户级技能目录"))
        XCTAssertTrue(text.contains("references/local-connection.md"))
        XCTAssertFalse(text.contains("daemon start"))
        XCTAssertFalse(text.contains("document open"))
    }

    func testSingleQuotesAndShellMetacharactersRemainData() {
        let information = AIConnectionInfo(
            bundleURL: URL(fileURLWithPath: "/tmp/Agent's $(echo unsafe) `app`.app"),
            paths: AppPaths(appSupportDirectory: URL(fileURLWithPath: "/tmp/User's support")),
            environment: ["SWCLI_ENDPOINT": "agent's;$(echo unsafe)"]
        )
        let command = information.text
        XCTAssertTrue(command.contains("MACSW_WINEPREFIX='/tmp/User'\\''s support/bottle'"))
        XCTAssertTrue(command.contains("SWCLI_ENDPOINT='agent'\\''s;$(echo unsafe)'"))
        XCTAssertTrue(command.contains("'/tmp/Agent'\\''s $(echo unsafe) `app`.app/Contents/MacOS/sw-cli'"))
    }

    func testEndpointMatchesConfiguredEnvironmentAndEmptyUsesDefault() {
        let environment = ["SWCLI_ENDPOINT": "127.0.0.1:19000"]
        let information = AIConnectionInfo(bundleURL: app, paths: paths, environment: environment)
        XCTAssertEqual(information.endpoint, "127.0.0.1:19000")
        XCTAssertTrue(information.text.contains("SWCLI_ENDPOINT='127.0.0.1:19000'"))
        XCTAssertEqual(
            AIConnectionInfo(bundleURL: app, paths: paths, environment: ["SWCLI_ENDPOINT": ""]).endpoint,
            AIConnectionInfo.defaultEndpoint
        )
    }

    func testUnrelatedEnvironmentAndSensitiveValuesAreNotCopied() {
        let information = AIConnectionInfo(bundleURL: app, paths: paths, environment: [
            "SW_SERIAL_SOLIDWORKS": "private-serial-value",
            "RCLONE_CONFIG_B64": "private-rclone-value",
            "MACSW_WINEPREFIX": "/tmp/unrelated-bottle"
        ])
        for excluded in ["SW_SERIAL_SOLIDWORKS", "private-serial-value", "RCLONE_CONFIG_B64",
                         "private-rclone-value", "/tmp/unrelated-bottle"] {
            XCTAssertFalse(information.text.contains(excluded))
        }
        XCTAssertTrue(information.text.contains(paths.bottle.path))
    }

    func testGeneratingInformationDoesNotCreateMissingPaths() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-AI-\(UUID().uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let information = AIConnectionInfo(
            bundleURL: root.appendingPathComponent("MacSW.app"),
            paths: AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        )
        XCTAssertFalse(information.text.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
