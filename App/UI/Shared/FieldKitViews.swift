import SwiftUI

/// T-00 part 1: "Note for Claude" box and one-tap thumbs (stored in ride_note / feedback, exported for Claude).
struct RideNoteCard: View {
    let rideId: String
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Note for Claude", systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
            TextField("What happened on this ride? (the keyboard mic works)", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Note for Claude")
            Text("Saved with this ride and included in every export.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(padding: 0)
        .onAppear {
            guard !loaded, let db = AppModel.shared.displayDatabase else { return }
            text = (try? FieldKitQueries(db).note(rideId: rideId)) ?? ""
            loaded = true
        }
        .onChange(of: text) { _, new in
            guard loaded, let db = AppModel.shared.database else { return }
            do { try FieldKitQueries(db).setNote(rideId: rideId, text: new) } catch { Log.error(source: "notes", error.localizedDescription) }
        }
    }
}

/// "Right?" row: thumbs up / down. A thumbs down asks one "what was wrong" question.
struct ThumbsRow: View {
    let kind: String
    let subjectId: String
    var subjectText: String?
    var label: String?
    @State private var verdict: Int?
    @State private var asking = false

    var body: some View {
        HStack(spacing: 4) {
            if let label { Text(label).font(.subheadline) }
            Spacer(minLength: 0)
            Button { answer(1) } label: { Text(verdict == 1 ? "\u{1F44D}" : "\u{1F44D}\u{FE0E}").opacity(verdict == 1 ? 1 : 0.5).frame(minWidth: 44, minHeight: 44).background(verdict == 1 ? Color.green.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule()) }
                .accessibilityLabel("\(label ?? kind): right")
            Button { asking = true } label: { Text(verdict == -1 ? "\u{1F44E}" : "\u{1F44E}\u{FE0E}").opacity(verdict == -1 ? 1 : 0.5).frame(minWidth: 44, minHeight: 44).background(verdict == -1 ? Color.red.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule()) }
                .accessibilityLabel("\(label ?? kind): wrong")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .onAppear {
            guard let db = AppModel.shared.displayDatabase else { return }
            verdict = try? FieldKitQueries(db).verdict(kind: kind, subjectId: subjectId)
        }
        .sheet(isPresented: $asking) {
            WhatWasWrongSheet(kind: kind) { reason, note in
                save(-1, reason: reason, note: note)
            }
            .glassPresentation()
        }
    }

    private func answer(_ v: Int) { save(v, reason: nil, note: nil) }

    private func save(_ v: Int, reason: String?, note: String?) {
        guard let db = AppModel.shared.database else { return }
        do {
            try FieldKitQueries(db).setFeedback(kind: kind, subjectId: subjectId, subjectText: subjectText, verdict: v, reason: reason, note: note)
            verdict = v
        } catch {
            Log.error(source: "feedback", error.localizedDescription)
        }
    }
}

struct WhatWasWrongSheet: View {
    let kind: String
    let onSave: (String?, String?) -> Void
    @State private var reason: String?
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                GlassSection("What was wrong?") {
                    ForEach(FieldKitQueries.reasons(for: kind), id: \.self) { r in
                        Button { reason = r } label: {
                            HStack { Text(r); Spacer(); if reason == r { Image(systemName: "checkmark") } }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                    .glassRows()
                GlassSection("Optional note") {
                    TextField("Anything else (the keyboard mic works)", text: $note, axis: .vertical).lineLimit(2...5)
                }
                    .glassRows()
            }
                .glassList()
            .navigationTitle("Not right")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(reason, note); dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}
