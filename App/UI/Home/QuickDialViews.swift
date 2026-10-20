import CorckieCore
import SwiftUI
import UIKit

/// F-29: the round icon of a place. A native SF Symbol or one or two typed letters in the same round style; no emoji. The chosen one is filled.
/// F-29b (owner, 20 Oct): with the place's colour the chosen icon is filled in that colour (a dark glyph on light colours like yellow, white on
/// blue) and an icon that is not chosen is that colour's outline and tint. Without a colour it is the accent orange as before. The name is read
/// by VoiceOver from the button around it, never the symbol name.
struct PlaceIconView: View {
    let icon: PlaceIcon
    var size: CGFloat = 52
    var selected = false
    /// an id of `PlaceColours`; nil = the accent orange
    var colourId: String?
    /// B46: the phone is inside this place: dimmed, with a small "you are here" mark
    var here = false

    private var colour: Color? { colourId.map { Color(hex: PlaceColours.hex($0)) } }
    private var darkGlyph: Bool { colourId.map { PlaceColours.glyphIsDark(hex: PlaceColours.hex($0)) } ?? true }

    var body: some View {
        ZStack {
            if selected {
                Circle().fill(colour ?? Theme.accent)
                Circle().strokeBorder(colour == nil ? Theme.accentInk.opacity(0.5) : Color.black.opacity(0.12), lineWidth: 1)
            } else {
                Circle().fill(colour.map { $0.opacity(0.18) } ?? Theme.chip)
                Circle().strokeBorder(colour ?? Theme.line, lineWidth: colour == nil ? 1 : 2)
            }
            switch icon {
            case .symbol(let name):
                Image(systemName: UIImage(systemName: name) != nil ? name : PlaceIcon.fallbackSymbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
            case .letters(let text):
                Text(text)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(glyphStyle)
        .frame(width: size, height: size)
        .opacity(here ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if here {
                Image(systemName: "location.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }

    private var glyphStyle: Color {
        if selected { return colour == nil || darkGlyph ? Theme.onAccent : .white }
        return colour == nil ? Theme.accentInk : .primary
    }
}

/// P6-5 (owner, 20 Oct): the permanent first slot of the quick dial, "No destination" (free ride). Not a place, so it looks different: a dashed
/// neutral grey ring with the infinity symbol (no place colour); chosen (= no destination) it fills light neutral with a dark glyph.
struct FreeRideIcon: View {
    var size: CGFloat = 52
    var selected = false

    var body: some View {
        ZStack {
            if selected {
                Circle().fill(Color(white: 0.88))
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            Image(systemName: QuickDialSlot.freeRideSymbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(selected ? Color(white: 0.1) : Color.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// F-29: Home's quick dial. Round buttons: "No destination" first (P6-5, always there), then the places (3, or 2 at the largest text sizes),
/// and "..." for the full list. Tap = choose; the first slot clears. The line under the buttons always says what is chosen ("Maya's house,
/// 12 min, needs ~9 %" or "No destination"); when the battery may not fit (F-22) that line is the orange warning instead.
struct QuickDialRow: View {
    let items: [QuickDialItem]
    let selectedKey: String?
    let summary: String
    let warning: String?
    let onTap: (QuickDialItem) -> Void
    let onClear: () -> Void
    let onMore: () -> Void
    @ScaledMetric(relativeTo: .body) private var dial: CGFloat = 52
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let size = min(dial, typeSize.isAccessibilitySize ? 72 : 56)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onClear) {
                    FreeRideIcon(size: size, selected: selectedKey == nil)
                        .frame(minWidth: DS.hit, minHeight: DS.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(QuickDialSlot.freeRideName)
                .accessibilityHint("No destination, a free ride")
                .accessibilityAddTraits(selectedKey == nil ? .isSelected : [])
                ForEach(items) { item in
                    let on = item.key == selectedKey
                    Button { onTap(item) } label: {
                        PlaceIconView(icon: item.icon, size: size, selected: on, colourId: item.colourId, here: item.here)
                            .frame(minWidth: DS.hit, minHeight: DS.hit)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.here ? "\(item.name), \(PlaceHere.hereWord.lowercased())" : item.name)
                    .accessibilityHint(item.here ? "You are already here" : (on ? "Chosen. Tap again for no destination" : "Choose as the destination"))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Button(action: onMore) {
                    ZStack {
                        Circle().strokeBorder(Theme.line, lineWidth: 1.5)
                        Image(systemName: "ellipsis").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Theme.accentInk)
                    }
                    .frame(width: size, height: size)
                    .frame(minWidth: DS.hit, minHeight: DS.hit)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More destinations")
                .accessibilityHint("Opens the list of destinations")
            }
            HStack(spacing: 6) {
                if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accentInk).accessibilityHidden(true)
                }
                Text(warning ?? summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(warning == nil ? Color.primary : Theme.accentInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }
}

/// F-29: on the place screen, "Show on Home" with its slot (1 to 3) and the icon: the 4 x 4 grid of symbols or 1-2 typed letters.
struct PlaceHomeCard: View {
    let placeId: String
    let name: String
    /// F-29b: the place colour, which colours the icon preview and the chosen cell
    var colourId: String?
    var preview = false

    @State private var icon: PlaceIcon?
    @State private var slot: Int?
    @State private var letters = ""
    @State private var errorText: String?

    private var shownIcon: PlaceIcon { icon ?? PlaceIcon.automatic(name: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show on Home", isOn: Binding(get: { slot != nil }, set: { on in setSlot(on ? (slot ?? 1) : nil) }))
            if slot != nil {
                Picker("Position on Home", selection: Binding(get: { slot ?? 1 }, set: { setSlot($0) })) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Position on Home")
            }
            HStack(spacing: 12) {
                PlaceIconView(icon: shownIcon, size: 52, selected: true, colourId: colourId)
                Text("Icon").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(PlaceIcon.symbols, id: \.self) { symbol in
                    Button { setIcon(.symbol(symbol)) } label: {
                        PlaceIconView(icon: .symbol(symbol), size: 48, selected: icon == .symbol(symbol), colourId: colourId)
                            .frame(maxWidth: .infinity, minHeight: DS.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
                    .accessibilityAddTraits(icon == .symbol(symbol) ? .isSelected : [])
                }
            }
            HStack {
                TextField("Or 1-2 letters", text: $letters)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: letters) { _, v in
                        let cleaned = PlaceIcon.clean(v)
                        if cleaned != v { letters = cleaned }
                    }
                    .submitLabel(.done)
                    .onSubmit { if !letters.isEmpty { setIcon(.letters(letters)) } }
                Button("Use letters") { setIcon(.letters(letters)) }
                    .disabled(letters.isEmpty)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if icon != nil {
                Button("Back to automatic") { setIcon(nil) }.font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.cardPad)
        .glassCard(padding: 0)
        .onAppear(perform: load)
        .alert("Could not save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func load() {
        guard !preview, let db = AppModel.shared.displayDatabase else { return }
        icon = QuickDialLoader.icons(db)[placeId]
        slot = QuickDialLoader.pins(db)[placeId]
        if case .letters(let t)? = icon { letters = t }
    }

    private func setIcon(_ new: PlaceIcon?) {
        icon = new
        guard !preview, let db = AppModel.shared.displayDatabase else { return }
        do { try QuickDialLoader.setIcon(new, placeId: placeId, database: db) } catch { errorText = error.localizedDescription }
    }

    private func setSlot(_ new: Int?) {
        slot = new
        guard !preview, let db = AppModel.shared.displayDatabase else { return }
        do { try QuickDialLoader.setPin(new, placeId: placeId, database: db) } catch { errorText = error.localizedDescription }
    }
}
