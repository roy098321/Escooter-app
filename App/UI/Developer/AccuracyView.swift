import CorckieCore
import SwiftUI

/// Developer → Accuracy (T-00 part 2, check u47 / mk2): how far off each estimate was, per P6 question (Q-C … Q-G): median and p90 error,
/// the target and "based on N rides". Reads the prediction log of this phone; the same numbers go into accuracy.txt in the export.
struct AccuracyView: View {
    @State private var lines: [AccuracyLine] = []
    @State private var waiting = 0
    @State private var settled = 0

    var body: some View {
        List {
            Section {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(line.question) \(line.title)").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(verdict(line)).font(.caption)
                        }
                        Text(line.n == 0 ? "No rides yet" : "Based on \(line.n) \(line.n == 1 ? "ride" : "rides") \u{00B7} \(line.errorText)")
                            .font(.footnote)
                        Text("Target: \(line.targetText)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("\(settled) estimates compared with their ride, \(waiting) waiting for a ride. Numbers are the ones the app showed (no safety margin). Included in every export as accuracy.txt.")
            }
                .glassRows()
        }
            .glassList()
        .navigationTitle("Accuracy")
        .screen("Accuracy")
        .onAppear(perform: load)
    }

    private func verdict(_ line: AccuracyLine) -> String {
        switch line.verdict {
        case .met: return "\u{2705} " + line.verdictText
        case .notYet: return "\u{26A0}\u{FE0F} " + line.verdictText
        default: return line.verdictText
        }
    }

    private func load() {
        guard let db = AppModel.shared.database else { return }
        lines = FieldKitService.accuracyLines(db)
        let all = (try? PredictionQueries(db).all()) ?? []
        settled = all.filter { $0.actual != nil }.count
        waiting = all.count - settled
    }
}
