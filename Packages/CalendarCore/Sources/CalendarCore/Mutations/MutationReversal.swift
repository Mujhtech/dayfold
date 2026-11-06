import Foundation

public enum MutationReversal {
    /// Reversal is another conditional write. It never promises to unsend guest updates.
    public static func make(_ original: Mutation) throws -> Mutation {
        guard original.state == .confirmed, let receipt = original.confirmedEvent else {
            throw CalendarError.invalid("This change has no reversible confirmed event. A deleted event can be restored as a new personal draft.")
        }
        let kind: MutationKind
        var fields: JSONObject = [:]
        switch original.kind {
        case .create: kind = .delete
        case .delete: throw CalendarError.invalid("Restore a deleted event as a new personal draft with a new identity.")
        case .patch:
            guard let base = original.base else { throw CalendarError.missing }
            kind = .patch
            for field in original.fields.keys { fields[field] = base.raw[field] ?? .null }
        case .rsvp:
            guard let attendee = receipt.selfAttendee, let response = original.base?.response else { throw CalendarError.missing }
            kind = .rsvp
            fields = ["attendeesOmitted": .bool(true), "attendees": .array([.object(["email": .string(attendee.text("email")), "responseStatus": .string(response)])])]
        }
        var result = Mutation(key: original.key, kind: kind, fields: fields, base: receipt, sendUpdates: original.sendUpdates)
        result.reverses = original.id
        result.reversalDepth = (original.reversalDepth ?? 0) + 1
        return result
    }
}
