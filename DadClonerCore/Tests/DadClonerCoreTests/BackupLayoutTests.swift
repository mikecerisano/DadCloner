import XCTest
@testable import DadClonerCore

final class BackupLayoutTests: XCTestCase {
    func testExcludedNamesContainsOwnMetadata() {
        XCTAssertTrue(BackupLayout.excludedNames.contains(BackupLayout.archiveDirectoryName))
        XCTAssertTrue(BackupLayout.excludedNames.contains(BackupLayout.backupMarkerFilename))
        XCTAssertTrue(BackupLayout.excludedNames.contains(".DocumentRevisions-V100"))
    }
}
