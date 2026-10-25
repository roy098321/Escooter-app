import CorckieCore
import SwiftUI

/// Settings (P6-2, SE1-SE9): five groups, Scooter & battery, Rider & load, Costs, Places, Data & backup, then Help, Developer and
/// About. No grey footers (G1) and no developer notes (G8). The values live in the `setting` table (`SettingsStore.swift`); the
/// defaults come from `SettingsCatalog` (Core, tested against the real constants).
struct SettingsView: View {
    /// ui-shot only: scroll to a group
    var startAt: String?

    @State private var weight = ""
    @State private var light = ""
    @State private var heavy = ""
    @State private var loaded = false

    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                scooterSection
                riderSection
                costsSection
                placesSection
                dataSection
                helpSection
                developerSection
                aboutSection
            }
            .glassList()
            .onAppear {
                loadValues()
                if let startAt { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo(startAt, anchor: .top) } }
            }
        }
        .navigationTitle("Settings")
        .hidesTabBar()                  // B28: the weight fields open the keyboard
        .screen("Settings")
    }

    /// A group with the small brown label (the same look as `SectionHeader`); the title is also the scroll id
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.sectionLabel)
                .id(title)
        }
        .glassRows()
    }

    // MARK: Groups

    private var scooterSection: some View {
        group("Scooter & battery") {
            NavigationLink {
                MaintenanceView()
            } label: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver").squircle(Theme.accent)
            }
            NavigationLink {
                BatterySettingsView()
            } label: {
                Label("Battery", systemImage: "battery.75percent").squircle(Theme.ok)
            }
            NavigationLink {
                NotifySettingsView()
            } label: {
                Label("Notifications", systemImage: "bell").squircle(Theme.danger)
            }
            NavigationLink {
                SoundsSettingsView()
            } label: {
                Label("Sounds", systemImage: "speaker.wave.2").squircle(Theme.canyon)
            }
        }
    }

    private var riderSection: some View {
        group("Rider & load") {
            HStack {
                Text("Rider weight")
                Spacer()
                TextField("Not set", text: $weight)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .onChange(of: weight) { _, v in saveWeight(v) }
                Text("kg").foregroundStyle(.secondary)
            }
            HStack {
                Text("Light load")
                Spacer()
                TextField("5", text: $light)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onChange(of: light) { _, v in saveLoad(RiderSettings.lightKey, v) }
                Text("kg").foregroundStyle(.secondary)
            }
            HStack {
                Text("Heavy load")
                Spacer()
                TextField("15", text: $heavy)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .onChange(of: heavy) { _, v in saveLoad(RiderSettings.heavyKey, v) }
                Text("kg").foregroundStyle(.secondary)
            }
            NavigationLink {
                DisplaySettingsView()
            } label: {
                Label("Display", systemImage: "sun.max").squircle(Theme.canyon)
            }
        }
    }

    private var costsSection: some View {
        group("Costs") {
            NavigationLink {
                FuelPriceView()
            } label: {
                LabeledContent("Fuel price", value: FuelPriceSetting.load(db).map(FuelPriceSetting.text) ?? "\u{2014}")
            }
            NavigationLink {
                CostSettingsView()
            } label: {
                Text("Electricity and fuel use")
            }
            NavigationLink {
                PriceHistoryView()
            } label: {
                Text("Price history")
            }
            NavigationLink {
                PurchaseSettingsView()
            } label: {
                Text("Purchase date and odometer")
            }
        }
    }

    private var placesSection: some View {
        group("Places") {
            NavigationLink {
                PlacesView()
            } label: {
                Label("Places", systemImage: "mappin.and.ellipse").squircle(Theme.danger)
            }
        }
    }

    private var dataSection: some View {
        group("Data & backup") {
            DataSettingsRows()
            let writer = BackupWriter.shared
            NavigationLink {
                BackupView()
            } label: {
                LabeledContent("Backup", value: BackupPlan.lastBackupText(
                    lastMs: writer.lastBackupMs, nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                    utcOffsetMin: TimeZone.current.secondsFromGMT() / 60))
            }
            if let error = writer.lastError {
                Text("Last backup failed: \(error)").font(.footnote).foregroundStyle(Theme.danger)
            }
        }
    }

    private var helpSection: some View {
        group("Help") {
            NavigationLink {
                ReportProblemView()
            } label: {
                Label("Report a problem", systemImage: "exclamationmark.bubble").squircle(.pink)
            }
        }
    }

    private var developerSection: some View {
        Section {
            NavigationLink {
                DeveloperView()
            } label: {
                Label("Developer", systemImage: "hammer").squircle(.gray)
            }
        }
        .glassRows()
    }

    private var aboutSection: some View {
        group("About") {
            LabeledContent("Version") { VersionLabel() }   // G4: the only place the version tag shows
            NavigationLink("What's new") { WhatsNewListView() }   // F-32: every build's list
        }
    }

    // MARK: Values

    private func loadValues() {
        loaded = false
        weight = RiderSettings.weightKg(db).map { Self.short($0) } ?? ""
        light = SettingsValue.number(db, RiderSettings.lightKey).map { Self.short($0) } ?? ""
        heavy = SettingsValue.number(db, RiderSettings.heavyKey).map { Self.short($0) } ?? ""
        DispatchQueue.main.async { loaded = true }
    }

    private static func short(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    private func parse(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }

    private func saveWeight(_ text: String) {
        guard loaded else { return }
        if text.isEmpty {
            SettingsValue.clear(db, RiderSettings.weightKey)
        } else if let v = parse(text), (30...250).contains(v) {
            SettingsValue.set(db, RiderSettings.weightKey, String(v))
        }
    }

    private func saveLoad(_ key: String, _ text: String) {
        guard loaded else { return }
        if text.isEmpty {
            SettingsValue.clear(db, key)
        } else if let v = parse(text), (0...100).contains(v) {
            SettingsValue.set(db, key, String(v))
        }
    }
}

// MARK: Pushed settings screens

/// SE3: battery size, charger and Recalibrate, one tap down from Scooter & battery
struct BatterySettingsView: View {
    @State private var packAh = T.t42DefaultPackAh
    @State private var chargerA = T.t46ChargerA
    @State private var confirmRecalibrate = false
    @State private var recalibrated = false
    @State private var loaded = false

    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        List {
            Section {
                SegmentedRow(title: "Battery size", options: SettingsCatalog.packChoices.map { ($0, SettingsCatalog.ah($0)) }, selection: $packAh)
                    .onChange(of: packAh) { _, v in
                        guard loaded, let db else { return }
                        BatterySettings.setPackAh(db, v)
                    }
                Picker("Charger", selection: $chargerA) {
                    ForEach(SettingsCatalog.chargerChoices, id: \.self) { Text(String(format: "%.1f A", $0)).tag($0) }
                }
                .onChange(of: chargerA) { _, v in
                    guard loaded, let db else { return }
                    BatterySettings.setChargerA(db, v)
                }
                Button("Recalibrate battery") { confirmRecalibrate = true }
                    .confirmationDialog("Recalibrate the battery?", isPresented: $confirmRecalibrate, titleVisibility: .visible) {
                        Button("Start over") {
                            if let db { BatterySettings.recalibrate(db) }
                            recalibrated = true
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The app learns the battery again from your next 5 qualifying rides. Old rides stay.")
                    }
                if recalibrated { Label("Started", systemImage: "checkmark").font(.footnote).foregroundStyle(.secondary) }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loaded = false
            packAh = BatterySettings.packAh(db)
            chargerA = BatterySettings.chargerA(db)
            DispatchQueue.main.async { loaded = true }
        }
        .screen("Battery settings")
    }
}

/// Sunlight mode and the colour-blind speed colours (SE2: the fixed unit row is gone)
struct DisplaySettingsView: View {
    @State private var sunlight = DisplaySettings.Sunlight.auto
    @State private var colourBlind = false
    @State private var loaded = false

    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        List {
            Section {
                SegmentedRow(title: "Sunlight mode", options: DisplaySettings.Sunlight.allCases.map { ($0, $0.rawValue) }, selection: $sunlight)
                    .onChange(of: sunlight) { _, v in
                        if loaded {
                            DisplaySettings.setSunlight(db, v)
                            SunlightMonitor.shared.refresh()
                        }
                    }
                Toggle("Colour-blind friendly speed colours", isOn: $colourBlind)
                    .onChange(of: colourBlind) { _, on in
                        if loaded { DisplaySettings.setColourBlind(db, on) }
                    }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loaded = false
            sunlight = DisplaySettings.sunlight(db)
            colourBlind = DisplaySettings.colourBlind
            DispatchQueue.main.async { loaded = true }
        }
        .screen("Display settings")
    }
}

/// F-19: one switch per sound. The battery, destination and motor warnings are not here: they always play during a ride (P-4).
struct SoundsSettingsView: View {
    @State private var on: [SoundToggle: Bool] = [:]

    var body: some View {
        List {
            Section {
                ForEach(SoundToggle.allCases, id: \.self) { t in
                    Toggle(t.title, isOn: Binding(get: { on[t] ?? true }, set: { v in on[t] = v; t.set(v) }))
                }
            } footer: {
                Text("Battery, destination and motor warnings always sound during a ride, even with the silent switch on.")
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Sounds")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { for t in SoundToggle.allCases { on[t] = t.isOn } }
        .screen("Sounds settings")
    }
}

/// The notification switches
struct NotifySettingsView: View {
    @State private var notify: [NotifyKind: Bool] = [:]

    private var db: AppDatabase? { AppModel.shared.database }

    var body: some View {
        List {
            Section {
                ForEach(NotifyKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { notify[kind] ?? true },
                        set: { on in
                            notify[kind] = on
                            NotifyPrefs.set(db, kind, on)
                            if kind == .weekly { BudgetedNotifier.refreshWeekly(db) }
                        }))
                }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { for kind in NotifyKind.allCases { notify[kind] = NotifyPrefs.isOn(db, kind) } }
        .screen("Notification settings")
    }
}

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "?"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "?"
    static var versionLine: String { "\(version) (\(build))" }
    /// F-30b: the release name ("101.251026.00") and its middle code ("251026", What's new)
    static var releaseName: String { version }
    static var releaseCode: String { ReleaseName.code(version) }
    /// Owner, P4 D3: "v1" is the product version (the Home Screen name is just "CorckieApp"); G4: shown in Settings → About only.
    static let productVersion = "v1"
    static var v1Line: String { "\(productVersion) · \(versionLine)" }
}
