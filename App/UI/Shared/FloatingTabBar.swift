import SwiftUI

/// UI_PLAN 1.6 / owner Q1 S: the floating glass tab bar with the raised round Home disc.
/// It is drawn by `RootView` under the five tab screens and never inside the live ride view
/// (the ride cover has no tabs). Tapping the tab you are on goes back to its first screen.
struct FloatingTabBar: View {
    struct Item: Identifiable {
        let id: Int
        let title: String
        let symbol: String
    }

    static let items: [Item] = [
        Item(id: 0, title: "Routes", symbol: "point.topleft.down.to.point.bottomright.curvepath"),
        Item(id: 1, title: "Rides", symbol: "list.bullet"),
        Item(id: 2, title: "Home", symbol: "house.fill"),
        Item(id: 3, title: "Stats", symbol: "chart.bar"),
        Item(id: 4, title: "Scooter", symbol: "scooter")
    ]

    @Binding var selection: Int
    var onReselect: (Int) -> Void = { _ in }
    @Environment(\.sunlight) private var sunlight

    static let barHeight: CGFloat = 64
    /// What the bar covers at the bottom of a tab (bar + room for the raised Home disc + the gap below + a little air): scroll content gets this as a bottom margin (B20 / B23)
    static let clearance: CGFloat = barHeight + 24 + 8 + 12
    private let discSize: CGFloat = 58

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items) { item in cell(item).zIndex(item.id == 2 ? 1 : 0) }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.barHeight)
        .sunPanel(Capsule(), edge: true)
        .padding(.horizontal, DS.Space.gutter)
        .padding(.top, 24)      // room for the raised disc, so it stays inside the tappable area
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
    }

    private func cell(_ item: Item) -> some View {
        let on = selection == item.id
        let home = item.id == 2
        return Button {
            if on { onReselect(item.id) } else { selection = item.id }
        } label: {
            VStack(spacing: 3) {
                if home {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Circle().strokeBorder(Color(.systemBackground).opacity(0.9), lineWidth: 4)
                        Image(systemName: item.symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: discSize, height: discSize)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .offset(y: -22)
                    .frame(height: 22)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 21))
                        .frame(height: 22)
                }
                Text(item.title)
                    .font(.caption2.weight(on ? .semibold : .regular))
                    .padding(.top, home ? 4 : 0)
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: Self.barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
