// DadClonerCore/Tests/DadClonerCoreTests/BackupPolicyTests.swift
import XCTest
@testable import DadClonerCore

final class BackupPolicyTests: XCTestCase {

    let calendar = Calendar(identifier: .gregorian)

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: isOverdue

    func testNeverSyncedIsOverdue() {
        XCTAssertTrue(BackupPolicy.isOverdue(lastSuccess: nil, now: date(2026, 7, 1, 12, 0)))
    }

    func testRecentSuccessIsNotOverdue() {
        let now = date(2026, 7, 1, 12, 0)
        let last = date(2026, 7, 1, 2, 0) // 10h ago
        XCTAssertFalse(BackupPolicy.isOverdue(lastSuccess: last, now: now))
    }

    func testOldSuccessIsOverdue() {
        let now = date(2026, 7, 2, 12, 0)
        let last = date(2026, 7, 1, 2, 0) // 34h ago
        XCTAssertTrue(BackupPolicy.isOverdue(lastSuccess: last, now: now))
    }

    // MARK: shouldAttemptCatchUp

    func testNoCatchUpWhenNotOverdue() {
        let now = date(2026, 7, 1, 12, 0)
        XCTAssertFalse(BackupPolicy.shouldAttemptCatchUp(
            lastSuccess: date(2026, 7, 1, 2, 0), lastAttempt: nil, now: now))
    }

    func testCatchUpWhenOverdueAndNeverAttempted() {
        XCTAssertTrue(BackupPolicy.shouldAttemptCatchUp(
            lastSuccess: nil, lastAttempt: nil, now: date(2026, 7, 1, 12, 0)))
    }

    func testCatchUpSuppressedByRecentFailedAttempt() {
        let now = date(2026, 7, 2, 12, 0)
        XCTAssertFalse(BackupPolicy.shouldAttemptCatchUp(
            lastSuccess: date(2026, 7, 1, 2, 0),          // overdue
            lastAttempt: date(2026, 7, 2, 11, 30),        // failed 30 min ago
            now: now))
    }

    func testCatchUpAllowedAfterAttemptSpacing() {
        let now = date(2026, 7, 2, 12, 0)
        XCTAssertTrue(BackupPolicy.shouldAttemptCatchUp(
            lastSuccess: date(2026, 7, 1, 2, 0),          // overdue
            lastAttempt: date(2026, 7, 2, 10, 30),        // failed 90 min ago
            now: now))
    }

    // MARK: nextOccurrence

    func testNextOccurrenceLaterToday() {
        let now = date(2026, 7, 1, 1, 0)
        XCTAssertEqual(
            BackupPolicy.nextOccurrence(hour: 2, minute: 0, after: now, calendar: calendar),
            date(2026, 7, 1, 2, 0))
    }

    func testNextOccurrenceRollsToTomorrow() {
        let now = date(2026, 7, 1, 14, 0)
        XCTAssertEqual(
            BackupPolicy.nextOccurrence(hour: 2, minute: 0, after: now, calendar: calendar),
            date(2026, 7, 2, 2, 0))
    }

    func testNextOccurrenceExactMomentRollsForward() {
        let now = date(2026, 7, 1, 2, 0)
        XCTAssertEqual(
            BackupPolicy.nextOccurrence(hour: 2, minute: 0, after: now, calendar: calendar),
            date(2026, 7, 2, 2, 0))
    }
}
