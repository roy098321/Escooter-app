import SwiftUI

/// Settings → Developer → Checks: the build's whole check list (TESTING §6).
struct ChecksView: View {
    private let results = CheckResults.shared

    var body: some View {
        List {
            Section {
                CountsRow()
            } footer: {
                Text("✅ passed · ❌ failed · ⏳ not done yet · ℹ️ recorded for Claude. Do them in the order of P4_RUN_ORDER, whenever there's time; most mark themselves.")
            }
            ForEach(CheckList.groups, id: \.self) { group in
                Section(group) {
                    ForEach(CheckList.all.filter { $0.group == group }) { item in
                        CheckRow(item: item)
                    }
                }
            }
        }
        .navigationTitle("Checks")
        .screen("Checks")
    }
}

struct CountsRow: View {
    private let results = CheckResults.shared

    var body: some View {
        let c = results.counts()
        HStack {
            count("✅", c.pass)
            count("❌", c.fail)
            count("ℹ️", c.info)
            count("⏳", c.pending)
        }
    }

    private func count(_ icon: String, _ n: Int) -> some View {
        VStack {
            Text(icon)
            Text("\(n)").font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

struct CheckRow: View {
    let item: CheckItem
    private let results = CheckResults.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(results.status(item.id).icon)
                Text("\(item.id.uppercased()) · \(item.title)").font(.body.weight(.medium))
                Spacer()
                if item.needsScooter {
                    Image(systemName: "scooter").foregroundStyle(.secondary).accessibilityLabel("Needs the scooter")
                }
            }
            let note = results.note(item.id)
            Text(note.isEmpty ? item.how : note)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if note.isEmpty {
                Text("Expected: \(item.expected)").font(.caption).foregroundStyle(.tertiary)
            }
            if item.manual {
                ManualResult(id: item.id)
            }
            if let link = ToolLink(tool: item.tool) {
                link
            }
        }
        .padding(.vertical, 2)
    }
}

/// Pass / Fail for checks only a person can judge.
struct ManualResult: View {
    let id: String
    private let results = CheckResults.shared

    var body: some View {
        HStack {
            Text(results.status(id).icon)
            Spacer()
            Button("Pass") { results.set(id, .pass, "Marked by the owner") }
                .buttonStyle(.bordered).tint(.green)
            Button("Fail") { results.set(id, .fail, "Marked by the owner") }
                .buttonStyle(.bordered).tint(.red)
        }
    }
}

/// A link to the developer screen that runs a check.
struct ToolLink: View {
    let tool: CheckTool

    init?(tool: CheckTool) {
        guard tool != .none else { return nil }
        self.tool = tool
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            Label("Open \(title)", systemImage: "arrow.right.circle").font(.footnote)
        }
    }

    private var title: String {
        switch tool {
        case .scooter: return "Scooter"
        case .sensors: return "Sensors"
        case .simulator: return "Simulated scooter"
        case .backup: return "Backup folder"
        case .crash: return "Crash catcher"
        case .outside: return "Outside data"
        case .readability: return "Readability"
        case .results: return "Results"
        case .permissions: return "Permissions"
        case .none: return ""
        }
    }

    @ViewBuilder private var destination: some View {
        switch tool {
        case .scooter: ScooterCheckView()
        case .sensors: SensorsView()
        case .simulator: SimulatorView()
        case .backup: BackupView()
        case .crash: CrashView()
        case .outside: OutsideDataView()
        case .readability: ReadabilityView()
        case .results: ResultsView()
        case .permissions: PermissionsView()
        case .none: EmptyView()
        }
    }
}
