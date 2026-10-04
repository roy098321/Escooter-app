import CorckieCore
import SwiftUI

/// Settings → Developer → Checks: the build's whole check list (TESTING §6), a To do list,
/// "Run all automatic", and per check an ⓘ guide and the owner's note (M1-00).
struct ChecksView: View {
    private let results = CheckResults.shared
    private let auto = AutoRunner.shared
    @State private var showTodo = true

    var body: some View {
        List {
            Section {
                CountsRow()
                Picker("Show", selection: $showTodo) {
                    Text("To do").tag(true)
                    Text("All checks").tag(false)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("✅ passed · ❌ failed · ⏳ not done yet · ℹ️ recorded for Claude. Tap ⓘ for the steps of a check.")
            }
            autoSection
            if showTodo {
                let todo = results.todo()
                if todo.isEmpty {
                    Section { Text("Nothing left to do. Send the export (Results).") }
                }
                ForEach(todo) { group in
                    Section(group.place.rawValue) {
                        ForEach(group.items) { item in
                            CheckRow(item: item)
                        }
                    }
                }
            } else {
                ForEach(CheckList.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(CheckList.all.filter { $0.group == group }) { item in
                            CheckRow(item: item)
                        }
                    }
                }
            }
        }
        .navigationTitle("Checks")
        .screen("Checks")
    }

    private var autoSection: some View {
        Section {
            Button {
                Task { await auto.run() }
            } label: {
                if auto.running {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProgressView()
                            Text(auto.step.isEmpty ? "Running…" : auto.step)
                        }
                        if let bar = CheckLive.autoBar() {
                            ProgressView(value: bar.fraction)
                            Text(bar.label).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("Run all automatic", systemImage: "play.circle.fill").font(.headline)
                }
            }
            .disabled(auto.running)
            ForEach(Array(auto.summary.enumerated()), id: \.offset) { _, line in
                Text(line).font(.footnote)
            }
        } footer: {
            Text("Runs every check the phone can do by itself: permissions, settings, error log, backup + restore, the simulator ones (scooter off) and outside data. About a minute.")
        }
    }
}

/// M1-00b: a progress bar on a running check, or a checklist that ticks itself on a multi-step
/// one. Re-read every second, so it follows the live state even when the check runs elsewhere.
struct LiveCheckBlock: View {
    let id: String

    var body: some View {
        if CheckLive.steps(id) != nil || CheckLive.bar(id) != nil || Self.mayRun(id) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    if let bar = CheckLive.bar(id, now: context.date) {
                        ProgressView(value: bar.fraction)
                        Text(bar.label).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let steps = CheckLive.steps(id) {
                        Text("Steps · (CheckProgress.tally(steps))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(steps.enumerated()), id: .offset) { _, step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(step.done ? Color.green : Color.secondary)
                                Text(step.title).font(.footnote).foregroundStyle(step.done ? .primary : .secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("(step.title), (step.done ? "done" : "not yet")")
                        }
                    }
                }
            }
        }
    }

    /// Checks that can show a bar later even though nothing runs this second
    private static func mayRun(_ id: String) -> Bool {
        ["b8", "c8", "c2", "c3", "c4", "d1", "d7", "d8", "e2", "e3", "e3b", "e4", "e5", "e6", "e6b", "e7", "e8"].contains(id)
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
    @State private var showGuide = false
    @State private var editingNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(results.status(item.id).icon)
                Text("\(item.id.uppercased()) · \(item.title)").font(.body.weight(.medium))
                Spacer()
                if item.needsScooter {
                    Image(systemName: "scooter").foregroundStyle(.secondary).accessibilityLabel("Needs the scooter")
                }
                Button {
                    showGuide = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("How to do this check")
            }
            let note = results.note(item.id)
            Text(note.isEmpty ? item.how : note)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if note.isEmpty {
                Text("Expected: \(item.expected)").font(.caption).foregroundStyle(.tertiary)
            }
            LiveCheckBlock(id: item.id)
            let ownerNote = results.ownerNote(item.id)
            if !ownerNote.isEmpty {
                Label(ownerNote, systemImage: "note.text").font(.caption).foregroundStyle(.blue)
            }
            if item.id == "c6b" && !PermissionsCheck.shared.soundsOn {
                // B09: the chime can't play without notification sounds — don't let the test start
                Label("Turn on Sounds first: Developer → Permissions → step 6 (h2 must be ✅)", systemImage: "speaker.slash.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            } else if item.manual {
                ManualResult(id: item.id)
            }
            HStack {
                Button {
                    editingNote = true
                } label: {
                    Label(ownerNote.isEmpty ? "Note" : "Edit note", systemImage: "square.and.pencil").font(.footnote)
                }
                .buttonStyle(.borderless)
                Spacer()
                if let link = ToolLink(tool: item.tool) {
                    link
                }
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showGuide) {
            CheckGuideSheet(item: item)
                .v1Label()
        }
        .sheet(isPresented: $editingNote) {
            CheckNoteSheet(item: item)
                .v1Label()
        }
    }
}

/// ⓘ: what the check proves, the steps, and what to expect.
struct CheckGuideSheet: View {
    let item: CheckItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let guide = CheckGuide.of(item.id)
        NavigationStack {
            List {
                Section("What it proves") {
                    Text(guide.proves)
                }
                Section("Steps") {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step)
                        }
                    }
                }
                Section("Expected") {
                    Text(item.expected)
                }
                Section {
                    LabeledContent("Where", value: guide.place.rawValue)
                    LabeledContent("Result", value: CheckResults.shared.status(item.id).icon)
                }
            }
            .navigationTitle("\(item.id.uppercased()) · \(item.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The owner's note on a check: saved with the result, kept across updates, in the export.
struct CheckNoteSheet: View {
    let item: CheckItem
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                } footer: {
                    Text("Why it passed or failed, or anything for next time. Goes into the export (results.txt and notes.txt).")
                }
            }
            .navigationTitle("Note · \(item.id.uppercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        CheckResults.shared.setOwnerNote(item.id, text)
                        dismiss()
                    }
                }
            }
            .onAppear { text = CheckResults.shared.ownerNote(item.id) }
        }
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
