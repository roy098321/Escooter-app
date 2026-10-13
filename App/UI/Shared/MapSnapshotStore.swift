import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// B14: the real Apple map behind Home and the map screens, as a still picture (MKMapSnapshotter), light and dark.
/// Taken at the last known location on app open and again after ~1 km; kept in the Caches folder so it shows at once.
/// No location request of its own, no live map view (battery, and no per-frame map work behind the glass).
/// The drawn map stays for ui-shots and previews (public repo: no real places).
@MainActor
@Observable
final class MapSnapshotStore {
    static let shared = MapSnapshotStore()

    private(set) var light: UIImage?
    private(set) var dark: UIImage?
    @ObservationIgnored private var centre: CLLocation?
    @ObservationIgnored private var busy = false

    private static let latKey = "mapbg.lat"
    private static let lonKey = "mapbg.lon"
    private static var dir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    private init() {
        guard !Self.disabled else { return }
        light = UIImage(contentsOfFile: Self.dir.appendingPathComponent("mapbg-light.png").path)
        dark = UIImage(contentsOfFile: Self.dir.appendingPathComponent("mapbg-dark.png").path)
        let d = UserDefaults.standard
        if d.object(forKey: Self.latKey) != nil, light != nil, dark != nil {
            centre = CLLocation(latitude: d.double(forKey: Self.latKey), longitude: d.double(forKey: Self.lonKey))
        }
    }

    /// ui-shots (`-uiShot ...`) keep the drawn map
    static var disabled: Bool { UIShot.raw != nil }

    func image(dark isDark: Bool) -> UIImage? { isDark ? dark : light }

    /// On app open (force) and whenever the phone has moved: a new snapshot when none exists or the last one is over ~1 km away.
    func refresh(force: Bool = false) {
        guard !Self.disabled, !busy, let loc = PhoneSensors.shared.lastKnown, loc.horizontalAccuracy >= 0 else { return }
        if let c = centre, light != nil, dark != nil, c.distance(from: loc) < 1000 { return }
        _ = force
        busy = true
        Task {
            await take(at: loc)
            busy = false
        }
    }

    private func take(at loc: CLLocation) async {
        let size = CGSize(width: 430, height: 932)
        func shot(_ style: UIUserInterfaceStyle) async -> UIImage? {
            let o = MKMapSnapshotter.Options()
            o.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 2500, longitudinalMeters: 2500 * size.width / size.height)
            o.size = size
            o.scale = 2
            o.traitCollection = UITraitCollection(userInterfaceStyle: style)
            o.pointOfInterestFilter = .excludingAll
            return try? await MKMapSnapshotter(options: o).start().image
        }
        guard let l = await shot(.light), let d = await shot(.dark) else { return }
        light = l
        dark = d
        centre = loc
        let defaults = UserDefaults.standard
        defaults.set(loc.coordinate.latitude, forKey: Self.latKey)
        defaults.set(loc.coordinate.longitude, forKey: Self.lonKey)
        try? l.pngData()?.write(to: Self.dir.appendingPathComponent("mapbg-light.png"))
        try? d.pngData()?.write(to: Self.dir.appendingPathComponent("mapbg-dark.png"))
    }
}
