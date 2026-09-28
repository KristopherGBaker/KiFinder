import Foundation

/// App-level identity for an enrolled (or to-be-enrolled) subject. The engine's
/// `ProfileStore` keys embeddings by `subjectId`; `Person` is the app-layer record
/// of *who* that subject is — the user-facing `displayName` and a cached
/// face-crop thumbnail. `id` is the `subjectId` used everywhere in the engine, so
/// the roster and the embedding store stay in lockstep.
///
/// New people are created with a UUID `id`; a person migrated from a legacy
/// single-subject store keeps that store's `subjectId` as its `id`, whatever the
/// string, so its existing `ProfileStore` entry remains valid. `displayName`
/// is **user data** and is never used as an accessibility identifier.
// swiftformat:disable:next redundantSendable
struct Person: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var displayName: String
    var thumbnailFileName: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        displayName: String,
        thumbnailFileName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.thumbnailFileName = thumbnailFileName
        self.createdAt = createdAt
    }
}

/// Versioned on-disk shape of the people roster sidecar (`people-roster.json`).
/// Kept tiny and explicit so the schema version travels with the data and future
/// migrations can branch on it.
struct PersonRoster: Codable, Equatable {
    var schemaVersion: Int
    var people: [Person]
}
