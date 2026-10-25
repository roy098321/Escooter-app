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
}

/// F-32: the card over the dimmed Home: "What's new · 251026", 3–4 items, the smaller-changes line, ✕ (a tap outside also closes it)
struct WhatsNewCard: View {
    let entry: WhatsNewEntry
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onClose)
                .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 14) {
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
