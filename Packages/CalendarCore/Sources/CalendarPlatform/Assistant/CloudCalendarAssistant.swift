import Foundation
import CalendarCore

public struct AssistantAvailabilityStatus: Equatable, Sendable {
    public var available: Bool
    public var message: String

    public init(available: Bool, message: String) {
        self.available = available
        self.message = message
    }
}

public struct CalendarAssistantReply: Sendable {
    public var text: String
    public var proposal: AssistantEventProposal?

    public init(text: String, proposal: AssistantEventProposal? = nil) {
        self.text = text
        self.proposal = proposal
    }
}

/// Sends only explicit requests and the bounded, read-only tool context supplied
/// by the caller. This service has no calendar mutation capability.
@MainActor public final class CloudCalendarAssistant {
    private let transport: any AssistantHTTPTransport
    private let gate: AssistantRequestGate
    private var responding = false

    public convenience init() { self.init(transport: OpenAIResponsesTransport(), gate: .shared) }

    init(transport: any AssistantHTTPTransport, gate: AssistantRequestGate = .shared) {
        self.transport = transport
        self.gate = gate
    }

    public func respond(
        to request: String,
        previousExchange: String? = nil,
        currentDate: Date,
        selectedDate: Date? = nil,
        timeZone: TimeZone,
        workStart: Int,
        workEnd: Int,
        apiKey: AssistantAPIKey,
        model: String = "gpt-5.4-mini",
        calendarDay: @escaping @Sendable (String) async throws -> String,
        freeTime: @escaping @Sendable (String, Int) async throws -> String
    ) async throws -> CalendarAssistantReply {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, request.count <= 1_800, request.utf8.count <= 5_400 else {
            throw CalendarError.invalid("Describe what you’d like help with in 1,800 characters or fewer.")
        }
        if let previousExchange, previousExchange.count > 1_200 || previousExchange.utf8.count > 3_600 {
            throw CalendarError.invalid("Start a new request and include the details you want the assistant to use.")
        }
        guard model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$"#, options: .regularExpression) != nil else {
            throw CalendarError.invalid("Enter a valid OpenAI model name in Assistant settings.")
        }
        guard (0...23).contains(workStart), (1...24).contains(workEnd), workStart < workEnd else {
            throw CalendarError.invalid("Set a valid workday start and end in Calendar settings before asking for open time.")
        }
        guard !responding else { throw CalendarError.unavailable("Wait for the current answer, or stop it before asking again.") }
        responding = true
        defer { responding = false }
        let transport = transport
        return try await gate.withPermit {
            try await OpenAIResponsesConversation.run(
                request: request, previousExchange: previousExchange, currentDate: currentDate, selectedDate: selectedDate,
                timeZone: timeZone, workStart: workStart, workEnd: workEnd,
                apiKey: apiKey, model: model, transport: transport,
                calendarDay: calendarDay, freeTime: freeTime
            )
        }
    }
}

/// A cancelled request owns its permit until its operation actually unwinds.
/// New service instances cannot overlap it or bypass the queue by resetting UI.
actor AssistantRequestGate {
    static let shared = AssistantRequestGate()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var active: UUID?
    private var waiting: [Waiter] = []

    func withPermit<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if active == nil { active = id; continuation.resume() }
                else { waiting.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        defer { release(id) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            active = next.id
            next.continuation.resume()
        }
    }
}
