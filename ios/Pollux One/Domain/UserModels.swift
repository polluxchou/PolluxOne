import Foundation

struct User: Identifiable, Codable, Equatable {
    let id: UUID
    var email: String
    var displayName: String?
}

struct Device: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var model: String
    var lastSeenAt: Date
}
