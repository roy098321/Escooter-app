import SwiftUI

/// Developer → Readability (f2, f3; P2 D11 carried into P6): live speed and battery tiles on
/// the mount, in the normal and the sunlight style.
struct ReadabilityView: View {
    private let model = AppModel.shared
    @State private var sunlight = false

    var body: some View {
        let frame = model.simulator.running ? model.simulator.pipeline.frame : model.live.frame
        VStack(spacing: 0) {
            Picker("Style", selection: $sunlight) {
                Text("Normal").tag(false)
                Text("Sunlight").tag(true)
            }
            .pickerStyle(.segmented)
            .padding()

            HStack(spacing: 12) {
                tile(frame?.speedKmh.map { String(format: "%.0f", $0) } ?? "—", "km/h")
                tile(frame?.batteryPct.map { "\($0)%" } ?? "—", "Battery")
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 8) {
                Text("f2 · Normal style readable on the mount").font(.footnote)
                ManualResult(id: "f2")
                Text("f3 · Sunlight style readable in direct sun").font(.footnote)
                ManualResult(id: "f3")
            }
            .padding()
            .background(.regularMaterial)
        }
        .background(sunlight ? Color.white : Color(.systemBackground))
        .navigationTitle("Readability")
        .screen("Readability")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.subheadline.weight(.semibold))
            Text(value)
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(sunlight ? Color.black : Color.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 170)
        .background(sunlight ? Color.white : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .stroke(sunlight ? Color.black : Color.clear, lineWidth: 3))
    }
}
