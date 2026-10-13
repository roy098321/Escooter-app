import CorckieCore
import SwiftUI

/// Settings (FEATURES.md → Settings, the final C23 list): Battery and charging · Units and display · Costs · Rider · Voice and
/// notifications · Places · Data and backup · Help · Developer. The groups, rows and defaults come from `SettingsCatalog`
/// (Core, tested against the real constants); the values live in the `setting` table (`SettingsStore.swift`).
struct SettingsView: View {
    /// ui-shot only: scroll to a group
    var startAt: String?

    @State private var packAh = T.t42DefaultPackAh
    @State private var chargerA = T.t46ChargerA
    @State private var confirmRecalibrate = false
    @State private var recalibrated = false
    @State private var sunlight = DisplaySettings.Sunlight.auto
    @State private var colourBlind = false
    @State private var weight = ""
    @State private var light = ""
    @State private var heavy = ""
    @State private var notify: [NotifyKind: Bool] = [:]
    @State private var loaded = false

    private var db: AppDatabase? { AppModel.shared.database }

    private func footer(_ title: String) -> Text {
        Text(SettingsCatalog.groups.first { $0.title == title }?.footer ?? "")
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                batterySection
                scooterSection
                displaySection
                costsSection
                riderSection
                notifySection
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
        .screen("Settings")
    }

    // MARK: Groups

    private var batterySection: some View {
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
            if recalibrated { Text("Started. It learns from your next rides.").font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Battery and charging").id("Battery and charging").textCase(nil)
        } footer: {
            footer("Battery and charging")
        }
        .glassRows()
    }

    private var scooterSection: some View {
        GlassSection("Scooter") {
            NavigationLink {
                MaintenanceView()
            } label: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver").squircle(.orange)
            }
        }
        .glassRows()
    }

    private var displaySection: some View {
        Section {
            SegmentedRow(title: "Sunlight mode", options: DisplaySettings.Sunlight.allCases.map { ($0, $0.rawValue) }, selection: $sunlight)
            .onChange(of: sunlight) { _, v in
                if loaded {
                    DisplaySettings.setSunlight(db, v)
                    SunlightMonitor.shared.refresh()
                }
            }
            LabeledContent("Units", value: "km \u{00B7} \u{00B0}C")
            Toggle("Colour-blind friendly speed colours", isOn: $colourBlind)
                .onChange(of: colourBlind) { _, on in
                    if loaded { DisplaySettings.setColourBlind(db, on) }
                }
        } header: {
            Text("Units and display").id("Units and display").textCase(nil)
        } footer: {
            footer("Units and display")
        }
        .glassRows()
    }

    private var costsSection: some View {
        GlassSection("Costs") {
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
        .glassRows()
    }

    private var riderSection: some View {
        Section {
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
        } header: {
            Text("Rider").id("Rider").textCase(nil)
        } footer: {
            Text("Optional. Light and Heavy are what the Loaded tag means in kg (defaults 5 and 15).")
        }
        .glassRows()
    }

    private var notifySection: some View {
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
        } header: {
            Text("Voice and notifications").id("Voice and notifications").textCase(nil)
        } footer: {
            footer("Voice and notifications")
        }
        .glassRows()
    }

    private var placesSection: some View {
        GlassSection("Places") {
            NavigationLink {
                PlacesView()
            } label: {
                Label("Places", systemImage: "mappin.and.ellipse").squircle(.red)
            }
        }
        .glassRows()
    }

    private var dataSection: some View {
        Section {
            DataSettingsRows()
            let writer = BackupWriter.shared
            NavigationLink {
                BackupView()
            } label: {
                LabeledContent("Backup folder \u{00B7} Last backup", value: BackupPlan.lastBackupText(
                    lastMs: writer.lastBackupMs, nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                    utcOffsetMin: TimeZone.current.secondsFromGMT() / 60))
            }
            if let error = writer.lastError {
                Text("Last backup failed: \(error)").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Data and backup").id("Data and backup").textCase(nil)
        } footer: {
            footer("Data and backup")
        }
        .glassRows()
    }

    private var helpSection: some View {
        GlassSection("Help") {
            NavigationLink {
                ReportProblemView()
            } label: {
                Label("Report a problem", systemImage: "exclamationmark.bubble").squircle(.pink)
            }
        }
        .glassRows()
    }

    private var developerSection: some View {
        Section {
            NavigationLink {
                DeveloperView()
            } label: {
                Label("Developer", systemImage: "hammer").squircle(.gray)
            }
        } footer: {
            Text("Checks, results and the test tools of this build.")
        }
        .glassRows()
    }

    private var aboutSection: some View {
        GlassSection("About") {
            LabeledContent("Version", value: AppInfo.versionLine)
            LabeledContent("App ID", value: AppInfo.bundleID)
        }
        .glassRows()
    }

    // MARK: Values

    private func loadValues() {
        loaded = false
        packAh = BatterySettings.packAh(db)
        chargerA = BatterySettings.chargerA(db)
        sunlight = DisplaySettings.sunlight(db)
        colourBlind = DisplaySettings.colourBlind
        weight = RiderSettings.weightKg(db).map { Self.short($0) } ?? ""
        light = SettingsValue.number(db, RiderSettings.lightKey).map { Self.short($0) } ?? ""
        heavy = SettingsValue.number(db, RiderSettings.heavyKey).map { Self.short($0) } ?? ""
        for kind in NotifyKind.allCases { notify[kind] = NotifyPrefs.isOn(db, kind) }
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

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "?"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "?"
    static var versionLine: String { "\(version) (\(build))" }
    /// Owner, P4 D3: "v1" is shown inside the app on every screen (the Home Screen name is just "CorckieApp").
    static let productVersion = "v1"
    static var v1Line: String { "\(productVersion) · \(versionLine)" }
}
