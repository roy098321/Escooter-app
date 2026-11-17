import CorckieCore
import XCTest

/// N6-7 guard: a lost backup folder falls back to the phone with a quiet note, never a crash.
final class BackupTargetTests: XCTestCase {
    func test_N6_7_bookmarkLost_fallsBackToPhone_withNote() {
        XCTAssertEqual(BackupTarget.choose(hasBookmark: true, folderReachable: true), .pickedFolder)
        XCTAssertEqual(BackupTarget.choose(hasBookmark: true, folderReachable: false), .phone(note: BackupTarget.folderLostNote))
        XCTAssertEqual(BackupTarget.choose(hasBookmark: false, folderReachable: false), .phone(note: nil))
    }

    func test_N6_7_folderLabel() {
        XCTAssertEqual(BackupTarget.label(folderPath: nil), "On this iPhone")
        XCTAssertEqual(BackupTarget.label(folderPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/CorckieApp"),
                       "iCloud Drive \u{203A} CorckieApp")
        XCTAssertEqual(BackupTarget.label(folderPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs"), "iCloud Drive")
        XCTAssertEqual(BackupTarget.label(folderPath: "/var/mobile/Containers/Shared/Backups"), "Backups")
    }
}
