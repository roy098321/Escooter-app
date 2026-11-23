import CorckieCore
import SwiftUI

/// F-32 (P-5): the bundled `WhatsNew.json` and the build last seen; the card shows once per build, never during a ride.
@MainActor
enum WhatsNewStore {
    private static let seenKey = "corckie.whatsNew.seen"

    static let entries: [WhatsNewEntry] = {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? WhatsNew.decode(data)) ?? []
    }()

    static var current: WhatsNewEntry? { WhatsNew.entry(for: AppInfo.releaseName, in: entries) }

    static func shouldShow(riding: Bool) -> Bool {
        WhatsNew.shouldShow(current: AppInfo.releaseName, lastSeen: UserDefaults.standard.string(forKey: seenKey), riding: riding, entries: entries)
    }

    static func markSeen() { UserDefaults.standard.set(AppInfo.releaseName, forKey: seenKey) }

    /// A-02: nil on a fresh install
    static var lastSeen: String? { UserDefaults.standard.string(forKey: seenKey) }

    /// N11-4: the confetti flag, stored per version (once only)
    static func confettiShown(_ version: String) -> Bool { UserDefaults.standard.bool(forKey: WhatsNew.confettiKey(version)) }
    static func markConfettiShown(_ version: String) { UserDefaults.standard.set(true, forKey: WhatsNew.confettiKey(version)) }
}

/// N11-4: a one-off thank-you burst (not a reward system, P-3): ~2 s, falls behind the card, no sound, a tap anywhere ends it.
/// Drawn in a Canvas from a fixed seed, so it costs nothing once it is over. Batch 12 (N12-1) removes it.
struct ConfettiBurst: View {
    var seconds: Double = WhatsNew.confettiSeconds
    @State private var start = Date()

    private struct Bit { let x: Double; let drift: Double; let delay: Double; let speed: Double; let spin: Double; let size: Double; let hue: Int }
    private static let colors: [Color] = [Theme.accent, .orange, .yellow, .white, Color(red: 1, green: 0.45, blue: 0.2)]
    private static let bits: [Bit] = {
        var seed: UInt64 = 100
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(UInt32.max >> 1) }
        return (0..<70).map { _ in
            Bit(x: next(), drift: next() * 2 - 1, delay: next() * 0.35, speed: 0.75 + next() * 0.6, spin: next() * 8, size: 5 + next() * 5,
                hue: Int(next() * 5) % 5)
        }
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { ctx, size in
                guard t < seconds else { return }
                for b in Self.bits {
                    let p = max(0, (t - b.delay) / (seconds - b.delay))
                    guard p > 0, p < 1 else { continue }
                    let y = -20 + p * b.speed * (size.height + 40)
                    let x = b.x * size.width + sin(p * .pi * 2 + b.spin) * 18 + b.drift * 30 * p
                    var c = ctx
                    c.opacity = p > 0.75 ? (1 - p) / 0.25 : 1
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(b.spin + p * 10))
                    c.fill(Path(CGRect(x: -b.size / 2, y: -b.size / 4, width: b.size, height: b.size / 2)), with: .color(Self.colors[b.hue]))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }
}

/// F-32: the card over the dimmed Home: "What's new · 251026", 3–4 items, the smaller-changes line, ✕ (a tap outside also closes it)
struct WhatsNewCard: View {
    let entry: WhatsNewEntry
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confetti = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onClose)
                .accessibilityLabel("Close")
            if confetti { ConfettiBurst() }   // N11-4: behind the card
            VStack(alignment: .leading, spacing: 14) {
                if let hero = entry.hero {
                    Text(hero).font(.title2.weight(.bold)).foregroundStyle(Theme.accentInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.caption.weight(.bold)).foregroundStyle(Theme.accentInk).textCase(.uppercase)
                        Text(entry.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: DS.hit, height: DS.hit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol).font(.title3).foregroundStyle(Theme.accentInk).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(item.line).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let more = entry.smallerFixesLine {
                    Text(more + " \u{00B7} Settings \u{2192} What's new").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 420)
            .glassCard(radius: DS.Radius.hero, padding: 0)
            .padding(.horizontal, DS.Space.gutter)
        }
        .simultaneousGesture(TapGesture().onEnded { confetti = false })   // N11-4: a tap anywhere ends the burst
        .onAppear {
            guard WhatsNew.showConfetti(entry, reduceMotion: reduceMotion, alreadyShown: WhatsNewStore.confettiShown(entry.version)) else { return }
            WhatsNewStore.markConfettiShown(entry.version)
            confetti = true
            DispatchQueue.main.asyncAfter(deadline: .now() + WhatsNew.confettiSeconds + 0.1) { confetti = false }
        }
        .transition(.opacity)
    }
}

/// F-32: Settings → What's new keeps every build's full list
struct WhatsNewListView: View {
    var body: some View {
        List {
            ForEach(WhatsNewStore.entries, id: \.version) { e in
                Section(e.title) {
                    ForEach(e.full, id: \.self) { Text($0).font(.subheadline) }
                }
            }
        }
        .navigationTitle("What's new")
        .screen("What's new")
    }
}
