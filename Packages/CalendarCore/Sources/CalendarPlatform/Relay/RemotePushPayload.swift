import Foundation

/// APNs carries an opaque hint, not the durable inbox's sequence or event data.
/// Parse this before crossing actors; the original userInfo isn't Sendable.
public struct RemotePushPayload: Sendable, Equatable {
    public enum Kind: String, Sendable, Decodable {
        case calendarChanged = "calendar_changed"
        case reminderDue = "reminder_due"
    }

    public let notificationID: UUID
    public let kind: Kind
    public let subjectID: UUID
    public let revision: Int64?

    public init?(userInfo: [AnyHashable: Any]) {
        guard let notificationID = userInfo["notification_id"] as? String,
              let subjectID = userInfo["subject_id"] as? String,
              let kind = userInfo["kind"] as? String else { return nil }
        let fields: [String: Any] = [
            "notification_id": notificationID,
            "subject_id": subjectID,
            "kind": kind,
            "revision": userInfo["revision"] ?? NSNull()
        ]
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields),
              let decoded = try? JSONDecoder().decode(Fields.self, from: data) else { return nil }
        switch decoded.kind {
        case .calendarChanged:
            guard decoded.revision == nil else { return nil }
        case .reminderDue:
            guard let revision = decoded.revision, revision > 0 else { return nil }
        }
        self.notificationID = decoded.notificationID
        self.subjectID = decoded.subjectID
        self.kind = decoded.kind
        self.revision = decoded.revision
    }

    private struct Fields: Decodable {
        let notificationID: UUID
        let kind: Kind
        let subjectID: UUID
        let revision: Int64?
        enum CodingKeys: String, CodingKey {
            case notificationID = "notification_id"
            case kind
            case subjectID = "subject_id"
            case revision
        }
    }
}
