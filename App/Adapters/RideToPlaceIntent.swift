import AppIntents
import CorckieCore
import Foundation

/// N7-9 (batch 7): "Ride to Work" through Siri and Spotlight (iOS 17). One saved place per entity, read in the app (removed places
/// are out, N6-1). The place you are at is not offered as a destination (tapping it would do nothing, owner). Starting opens Live.
struct PlaceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Place"
    static var defaultQuery = PlaceQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PlaceEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PlaceEntity] {
        guard let db = AppModel.shared.displayDatabase else { return [] }
        let here = await MainActor.run { RecorderService.shared.livePosition.map { GeoPoint(lat: $0.lat, lon: $0.lon) } }
        let items = QuickDialLoader.load(database: db, routeChips: [], slots: 12, from: here).items
        return items.filter { !$0.here }.map { PlaceEntity(id: $0.key, name: $0.name) }
    }
}

struct RideToPlaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Ride to a place"
    static var description = IntentDescription("Starts a ride to one of your places while your scooter is connected.")
    static var openAppWhenRun = true

    @Parameter(title: "Place")
    var place: PlaceEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        RideIntentBridge.start?(place.id)
        return .result()
    }
}
