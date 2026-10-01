import SwiftUI
import Charts
import CoreMotion

// D05 / D07: wake-up on scooter connect, recording while locked, elevation over the arch bridge.
final class AltitudeRecorder: ObservableObject {
    static let shared = AltitudeRecorder()

    struct Sample: Identifiable {
        let id = UUID()
        let time: Date
        let meters: Double
        let background: Bool
    }

    private let altimeter = CMAltimeter()
    @Published var samples: [Sample] = []
    @Published var running = false

    func start() {
        guard !running, CMAltimeter.isRelativeAltitudeAvailable() else { return }
        running = true
        samples = []
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.samples.append(Sample(time: .now, meters: data.relativeAltitude.doubleValue,
                                       background: UIApplication.shared.applicationState == .background))
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        running = false
    }

    var rise: Double {
        let values = samples.map(\.meters)
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    var summary: String {
        "\(samples.count) samples, \(samples.filter(\.background).count) while locked, highest − lowest = \(String(format: "%.1f", rise)) m"
    }
}

struct RideTestView: View {
    @ObservedObject private var scooter = Scooter.shared
    @ObservedObject private var location = LocationModel.shared
    @ObservedObject private var altitude = AltitudeRecorder.shared
    @ObservedObject private var store = ResultStore.shared

    var body: some View {
        List {
            Section("Before the ride") {
                Text("1. Open D03 Bluetooth once with the scooter on, so the app knows your scooter. Allow location \"Always\".")
                Text("2. Switch the scooter off. Go to the home screen (don't swipe P2 Lab away) and lock the phone.")
                Text("3. Switch the scooter on with the phone locked in your pocket. Wait 30 s.")
                check("d05wake")
            }
            .font(.footnote)

            Section("Ride (about 30 min, phone locked, over the arch bridge)") {
                check("d05ble")
                check("d05locwake")
                LabeledContent("Scooter packets while locked", value: "\(scooter.packetsWhileLocked)")
                LabeledContent("Location points while locked", value: "\(location.backgroundPoints)")
                LabeledContent("Elevation samples while locked", value: "\(altitude.samples.filter(\.background).count)")
                if !altitude.running {
                    Button("Start recording now (if the wake-up didn't)") {
                        location.start()
                        altitude.start()
                    }
                }
            }

            Section("After the ride") {
                Text("D05 Was the whole ride recorded?").font(.footnote)
                ManualResult(id: "d05ride")
                if altitude.samples.count > 1 {
                    Chart(altitude.samples) { sample in
                        LineMark(x: .value("Time", sample.time), y: .value("Metres", sample.meters))
                    }
                    .frame(height: 160)
                    Text(altitude.summary).font(.footnote).foregroundStyle(.secondary)
                }
                Text("D07 Does the arch bridge show as a clear bump in the chart?").font(.footnote)
                ManualResult(id: "d07bridge")
                Button("Stop recording", role: .destructive) {
                    location.stop()
                    altitude.stop()
                }
            }

            Section("Bluetooth events") {
                ForEach(scooter.events.suffix(20).reversed(), id: \.self) { line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("D05 Ride test")
    }

    private func check(_ id: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.status(id).icon)
            VStack(alignment: .leading) {
                Text(Tests.all.first { $0.id == id }?.title ?? id).font(.body)
                if !store.note(id).isEmpty { Text(store.note(id)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}

// D11: is the live view readable on the handlebar mount, and in direct sun?
struct ReadabilityView: View {
    @ObservedObject private var scooter = Scooter.shared
    @State private var sunlight = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Style", selection: $sunlight) {
                Text("Normal").tag(false)
                Text("Sunlight").tag(true)
            }
            .pickerStyle(.segmented)
            .padding()

            HStack(spacing: 12) {
                tile(scooter.speed.map { String(format: "%.0f", $0) } ?? "—", "km/h")
                tile(scooter.battery.map { "\($0)%" } ?? "—", "Battery")
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 8) {
                Text("D11 Normal style readable on the mount").font(.footnote)
                ManualResult(id: "d11read")
                Text("D11 Sunlight style readable in direct sun").font(.footnote)
                ManualResult(id: "d11sun")
            }
            .padding()
            .background(.regularMaterial)
        }
        .background(sunlight ? Color.white : Color(.systemBackground))
        .navigationTitle("D11 Readability")
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
