import SwiftUI
import CoreMotion

// D07 (phone part): does the barometer see a ~3 m climb? The arch bridge waits for a ride.
final class BaroModel: ObservableObject {
    private let altimeter = CMAltimeter()
    @Published var meters = 0.0
    @Published var hectopascals = 0.0
    @Published var status = "Not started"

    func start() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            status = "This phone has no barometer"
            return
        }
        status = "Measuring"
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.status = error.localizedDescription
            } else if let data {
                self.meters = data.relativeAltitude.doubleValue
                self.hectopascals = data.pressure.doubleValue * 10
            }
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        status = "Stopped"
    }
}

struct BaroTestView: View {
    @StateObject private var model = BaroModel()

    var body: some View {
        VStack(spacing: 12) {
            Text(String(format: "%+.1f m", model.meters))
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(String(format: "%.1f hPa", model.hectopascals))
                .foregroundStyle(.secondary)
            Text(model.status).font(.footnote)
            Text("Walk up one floor (about 3 m) and back down. The number should rise and come back close to 0.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top)
        }
        .padding()
        .navigationTitle("Barometer")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
