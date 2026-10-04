import XCTest
@testable import CorckieCore

/// M1-07 / M1-10: "Going for a ride?" rules and the notifier that acts on them.
final class GoingForARideTests: XCTestCase {
    private final class FakeCenter: NotificationSending, MessageLogging {
        var sent: [(id: String, title: String, body: String, sound: String)] = []
        var removed: [String] = []
        var entries: [MessageLogEntry] = []
        func send(id: String, title: String, body: String, soundName: String) {
            sent.append((id, title, body, soundName))
        }
        func remove(id: String) { removed.append(id) }
        func log(_ entry: MessageLogEntry) { entries.append(entry) }
    }

    private func make() -> (GoingForARideNotifier, FakeCenter) {
        let c = FakeCenter()
        return (GoingForARideNotifier(sender: c, logger: c), c)
    }

    func testSendsOnceWithBatteryAndChime() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        XCTAssertTrue(c.sent.isEmpty)                                     // waits for the first battery reading
        n.batteryReading(pct: 91.2, at: 1, appActive: false, rideActive: false)
        XCTAssertEqual(c.sent.count, 1)
        XCTAssertEqual(c.sent.first?.title, "Scooter on · 91%")
        XCTAssertEqual(c.sent.first?.body, "Going for a ride? Tap here")
        XCTAssertEqual(c.sent.first?.sound, "chime2_kickoff.wav")
        XCTAssertEqual(c.entries, [MessageLogEntry(type: "going_for_a_ride", channel: "notification", at: 1, droppedReason: nil)])
        n.batteryReading(pct: 91, at: 2, appActive: false, rideActive: false)
        XCTAssertEqual(c.sent.count, 1)
    }

    func testThreeReconnectBlipsStillOneNotification() {                  // B04 pattern
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.batteryReading(pct: 91, at: 1, appActive: false, rideActive: false)
        for (i, t) in [30.0, 80.0, 150.0].enumerated() {
            n.scooterDisconnected(at: t)
            n.scooterConnected(at: t + 20, appActive: false, rideActive: false)    // back within 2 min each time
            n.batteryReading(pct: 90, at: t + 21, appActive: false, rideActive: false)
            n.tick(at: t + 22, appActive: false, rideActive: false)
            XCTAssertEqual(c.sent.count, 1, "blip \(i + 1)")
        }
        XCTAssertTrue(c.removed.isEmpty)
    }

    func testNeverWhileTheAppIsActive() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: true, rideActive: false)
        n.batteryReading(pct: 80, at: 1, appActive: true, rideActive: false)
        XCTAssertTrue(c.sent.isEmpty)
        XCTAssertEqual(c.entries.last?.droppedReason, "app on screen")
        // the app goes to the background later in the same power-on: still nothing (the rider has seen the app)
        n.batteryReading(pct: 80, at: 30, appActive: false, rideActive: false)
        XCTAssertTrue(c.sent.isEmpty)
    }

    func testAppOpensBetweenConnectAndBatteryReading() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.batteryReading(pct: 80, at: 1, appActive: true, rideActive: false)
        XCTAssertTrue(c.sent.isEmpty)
        XCTAssertEqual(c.entries.last?.droppedReason, "app on screen")
    }

    func testNeverDuringARide() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: true)
        XCTAssertTrue(c.sent.isEmpty)
        XCTAssertEqual(c.entries.last?.droppedReason, "ride in progress")
    }

    func testRemovedWhenTheRideStarts() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.batteryReading(pct: 91, at: 1, appActive: false, rideActive: false)
        n.rideStarted(at: 20)
        XCTAssertEqual(c.removed, [GoingForARideContent.notificationID])
        n.rideStarted(at: 21)
        XCTAssertEqual(c.removed.count, 1)                                // nothing left to remove
        n.scooterDisconnected(at: 100)
        n.scooterConnected(at: 110, appActive: false, rideActive: true)   // reconnect mid-ride: nothing new
        XCTAssertEqual(c.sent.count, 1)
    }

    func testRemovedAtAutoOffAfterLongDisconnect() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.batteryReading(pct: 91, at: 1, appActive: false, rideActive: false)
        n.scooterDisconnected(at: 300)                                    // scooter switches itself off
        n.tick(at: 300 + 120, appActive: false, rideActive: false)        // exactly 2 min: still the same power-on
        XCTAssertTrue(c.removed.isEmpty)
        n.tick(at: 300 + 121, appActive: false, rideActive: false)
        XCTAssertEqual(c.removed, [GoingForARideContent.notificationID])
        // switching on again is a new power-on: a new notification
        n.scooterConnected(at: 1000, appActive: false, rideActive: false)
        n.batteryReading(pct: 90, at: 1001, appActive: false, rideActive: false)
        XCTAssertEqual(c.sent.count, 2)
    }

    func testRemovedAtPowerOffFlag() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.batteryReading(pct: 91, at: 1, appActive: false, rideActive: false)
        n.powerOff(at: 5)
        XCTAssertEqual(c.removed.count, 1)
        n.scooterConnected(at: 20, appActive: false, rideActive: false)   // 0x80 ended the power-on
        n.batteryReading(pct: 91, at: 21, appActive: false, rideActive: false)
        XCTAssertEqual(c.sent.count, 2)
    }

    func testSentWithoutBatteryAfterTenSeconds() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.tick(at: 9.9, appActive: false, rideActive: false)
        XCTAssertTrue(c.sent.isEmpty)
        n.tick(at: 10, appActive: false, rideActive: false)
        XCTAssertEqual(c.sent.first?.title, "Scooter on")
    }

    func testNotSentWhileTheLinkIsDown() {
        let (n, c) = make()
        n.scooterConnected(at: 0, appActive: false, rideActive: false)
        n.scooterDisconnected(at: 3)
        n.tick(at: 20, appActive: false, rideActive: false)
        XCTAssertTrue(c.sent.isEmpty)
    }

    func testOutsideBudgetAndQuietHours() {
        // 5 power-ons in one night (23:30 = 84600 s of the day and later): every one is sent. No daily count, no quiet hours.
        let (n, c) = make()
        var t = 23.5 * 3600
        for _ in 0..<5 {
            n.scooterConnected(at: t, appActive: false, rideActive: false)
            n.batteryReading(pct: 80, at: t + 1, appActive: false, rideActive: false)
            n.powerOff(at: t + 60)
            t += 600
        }
        XCTAssertEqual(c.sent.count, 5)
        XCTAssertTrue(c.entries.allSatisfy { $0.type == "going_for_a_ride" && $0.channel == "notification" })
        XCTAssertGreaterThan(5, T.t98NotificationsPerDay)                 // more than the daily limit of the budget
    }
}
