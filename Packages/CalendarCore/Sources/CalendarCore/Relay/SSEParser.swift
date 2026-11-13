import Foundation

/// Incremental SSE decoding, with a bound on both complete and unterminated
/// events. It does not acknowledge a cursor: only the consumer can do that after
/// durable handling. An incomplete final event is rejected for safe replay.
public struct RelaySSEParser: Sendable {
    public static let maximumEventBytes = 64 * 1024
    private var line = Data()
    private var eventBytes = 0
    private var skipNextLF = false
    private var firstLine = true
    private var eventName = ""
    private var eventID: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [RelayStreamEvent] {
        guard bytes.count <= Self.maximumEventBytes else { throw RelayClientError.invalidResponse }
        var events: [RelayStreamEvent] = []
        for byte in bytes {
            if skipNextLF {
                skipNextLF = false
                if byte == 10 { continue }
            }
            eventBytes += 1
            guard eventBytes <= Self.maximumEventBytes else { throw RelayClientError.invalidResponse }
            if byte == 10 || byte == 13 {
                if let event = try consumeLine() { events.append(event) }
                skipNextLF = byte == 13
            } else {
                line.append(byte)
            }
        }
        return events
    }

    public mutating func finish() throws {
        guard line.isEmpty, dataLines.isEmpty, eventID == nil, eventName.isEmpty else {
            throw RelayClientError.invalidResponse
        }
    }

    private mutating func consumeLine() throws -> RelayStreamEvent? {
        guard var value = String(data: line, encoding: .utf8) else { throw RelayClientError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if value.hasPrefix("\u{FEFF}") { value.removeFirst() } }
        if value.isEmpty {
            defer { eventBytes = 0; eventName = ""; eventID = nil; dataLines.removeAll(keepingCapacity: true) }
            guard !dataLines.isEmpty else { return nil }
            if eventName == "resync_required" { return .resyncRequired }
            guard eventName == "notification" else { return nil }
            guard let eventID, !eventID.isEmpty, eventID.utf8.allSatisfy({ (48...57).contains($0) }),
                  let sequence = Int64(eventID), sequence > 0 else { throw RelayClientError.invalidResponse }
            let body = Data(dataLines.joined(separator: "\n").utf8)
            let notification: RelayNotification
            do { notification = try RelayJSON.decoder().decode(RelayNotification.self, from: body) }
            catch { throw RelayClientError.invalidResponse }
            try notification.validate()
            guard notification.sequence == sequence else { throw RelayClientError.invalidResponse }
            return .notification(notification)
        }
        if value.hasPrefix(":") { return nil }
        let split = value.firstIndex(of: ":")
        let field = split.map { String(value[..<$0]) } ?? value
        var content = split.map { String(value[value.index(after: $0)...]) } ?? ""
        if content.hasPrefix(" ") { content.removeFirst() }
        switch field {
        case "event": eventName = content
        case "id":
            guard !content.contains("\0") else { throw RelayClientError.invalidResponse }
            eventID = content
        case "data": dataLines.append(content)
        default: break // SSE retry and future fields are advisory, never an automatic retry policy.
        }
        return nil
    }
}
