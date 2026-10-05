import CorckieCore
import SwiftUI

/// M2-07: "Arrive by" on the route card. Pick a time (hours and minutes: the next time the clock shows it); the card says when to
/// leave (M29: target - today at that departure - margin) and can set a reminder for that moment. All numbers and the quiet-hours
/// rules come from CorckieCore (`ArriveBy`, `LeaveReminder`); this view only draws them.
struct ArriveByCard: View {
    var routeId: String?
    var destination: String
    var rides: [RouteRideStats]
    /// ui-shots: no scheduling, a fixed target and the reminder switched on
    var preview = false

    @State private var time = ArriveByCard.defaultTime()
    @State private var remind = false
    @State private var status: String?
    @State private var loaded = false
    @State private var skipNext = false

    private var offset: Int { TimeZone.current.secondsFromGMT() / 60 }
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private var target: Int64 {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return ArriveBy.nextTargetMs(minuteOfDay: (c.hour ?? 9) * 60 + (c.minute ?? 0), nowMs: nowMs, utcOffsetMin: offset)
    }

    private var result: ArriveByResult { ArriveBy.plan(rides: rides, targetAtMs: target, utcOffsetMin: offset) }

    static func defaultTime() -> Date {
        let c = Calendar.current
        let next = c.date(byAdding: .hour, value: 2, to: Date()) ?? Date()
        return c.date(bySettingHour: c.component(.hour, from: next), minute: 0, second: 0, of: next) ?? next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Arrive by").font(.headline)
                Spacer()
                DatePicker("Arrive by", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .onChange(of: time) { _, _ in
                        if skipNext { skipNext = false } else { apply(force: true) }
                    }
            }
            switch result {
            case .notEnough(let have, let need):
                Text("\(have) of \(need) rides until Arrive by can say when to leave.").font(.subheadline).foregroundStyle(.secondary)
            case .plan(let p):
                Text(p.headline).font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(p.detail).font(.footnote).foregroundStyle(.secondary)
                if p.leaveAtMs <= nowMs {
                    Text("That time has passed: you would be about \(max(1, Int(Double(nowMs - p.leaveAtMs) / 60_000))) min late.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Toggle("Remind me when to leave", isOn: $remind)
                    .onChange(of: remind) { _, on in
                        if on { apply(force: true) } else if !preview { LeaveReminderScheduler.cancel(); status = nil }
                    }
                if remind, let s = status { Text(s).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear(perform: restore)
    }

    /// A reminder set earlier for this route comes back on the card; a new plan (new rides) replaces it only when 2 min or more earlier (T84)
    private func restore() {
        guard !loaded else { return }
        loaded = true
        if preview {
            remind = true
            status = "Reminder set for 8:21"
            return
        }
        guard let id = routeId, let s = LeaveReminderScheduler.stored(), s.routeId == id, s.targetMs > nowMs else { return }
        skipNext = true
        time = Date(timeIntervalSince1970: Double(s.targetMs) / 1000)
        remind = true
        apply(force: false)
    }

    private func apply(force: Bool) {
        guard !preview, remind, let id = routeId, let plan = result.plan else { return }
        LeaveReminderScheduler.apply(routeId: id, destination: destination, plan: plan, force: force) { status = $0 }
    }
}
