import XCTest
@testable import litenote

final class AppIdentityTests: XCTestCase {
    func testAppUsesLowercaseNameAndExecutable() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "litenote")
        XCTAssertEqual(Bundle.main.executableURL?.lastPathComponent, "litenote")
    }

    func testRenamePreservesPreferencesDomainAndAttachmentPaths() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.papertray.app")
        let legacyRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papertray", isDirectory: true)
        XCTAssertEqual(DataLocation.application.root, legacyRoot)
    }
}
