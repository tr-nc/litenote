import XCTest
@testable import Litenote

final class AppIdentityTests: XCTestCase {
    func testAppUsesLitenoteNameAndExecutable() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Litenote")
        XCTAssertEqual(Bundle.main.executableURL?.lastPathComponent, "Litenote")
    }

    func testRenamePreservesPreferencesDomainAndAttachmentPaths() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.papertray.app")
        let legacyRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Papertray", isDirectory: true)
        XCTAssertEqual(DataLocation.application.root, legacyRoot)
    }
}
