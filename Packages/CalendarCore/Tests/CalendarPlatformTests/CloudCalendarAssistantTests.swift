import Foundation
import Testing
import CalendarCore
@testable import CalendarPlatform

private actor AssistantFixtureTransport: AssistantHTTPTransport {
    var responses: [AssistantHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [AssistantHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> AssistantHTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

private actor AssistantToolRecorder {
    var days: [String] = []
    var durations: [Int] = []
    func day(_ date: String) -> String { days.append(date); return "Downloaded calendar scope: Work; reliable=true; no events." }
    func free(_ date: String, _ duration: Int) -> String { days.append(date); durations.append(duration); return "Calendar scope: Work; reliable=true; free 13:00 to 15:00." }
}

private func assistantResponse(_ output: [JSONValue], status: String = "completed") throws -> AssistantHTTPResponse {
    AssistantHTTPResponse(status: 200, data: try JSONEncoder().encode(["status": JSONValue.string(status), "output": .array(output)]))
}

private func assistantCall(_ name: String, id: String, arguments: String) -> JSONValue {
    .object(["type": .string("function_call"), "id": .string("fc_" + id), "call_id": .string(id), "name": .string(name), "arguments": .string(arguments), "status": .string("completed")])
}

private func assistantMessage(_ reply: JSONObject) throws -> JSONValue {
    let text = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
    return .object(["type": .string("message"), "role": .string("assistant"), "status": .string("completed"), "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])
}

@MainActor private func askAssistant(
    _ transport: any AssistantHTTPTransport,
    request: String = "Find 30 minutes for focus on 2026-11-08",
    apiKey: String = "fixture-openai-api-key",
    calendarDay: @escaping @Sendable (String) async throws -> String = { _ in "reliable=true; no events" },
    freeTime: @escaping @Sendable (String, Int) async throws -> String = { _, _ in "reliable=true; free 13:00 to 15:00" }
) async throws -> CalendarAssistantReply {
    let assistant = CloudCalendarAssistant(transport: transport, gate: AssistantRequestGate())
    return try await assistant.respond(to: request, previousExchange: "User: Help me plan. Assistant: Which day?",
                                       currentDate: Date(timeIntervalSince1970: 1_794_031_200), selectedDate: Date(timeIntervalSince1970: 1_794_117_600),
                                       timeZone: TimeZone(identifier: "Africa/Lagos")!, workStart: 8, workEnd: 18,
                                       apiKey: AssistantAPIKey(apiKey), calendarDay: calendarDay, freeTime: freeTime)
}

@Test @MainActor func cloudAssistantAcceptsTheCredentialTypesFullKeyLength() async throws {
    let transport = AssistantFixtureTransport([
        try assistantResponse([assistantMessage(["text": .string("  Which day should I check?  "), "proposal": .null])])
    ])
    let key = String(repeating: "k", count: 8_192)
    let reply = try await askAssistant(transport, apiKey: key)
    #expect(reply.text == "Which day should I check?")
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(requests.first?.value(forHTTPHeaderField: "Authorization")?.utf8.count == key.utf8.count + 7)
}

@Test @MainActor func cloudAssistantReplaysReadOnlyToolsWithoutServerConversationStorage() async throws {
    let reasoning: JSONValue = .object(["type": .string("reasoning"), "id": .string("rs_fixture"), "summary": .array([]), "encrypted_content": .string("opaque-fixture")])
    let first = assistantCall("calendar_day", id: "call_day", arguments: #"{"date":"2026-11-08"}"#)
    let second = assistantCall("find_free_time", id: "call_free", arguments: #"{"date":"2026-11-08","durationMinutes":30}"#)
    let proposal: JSONValue = .object(["title": .string("Focus"), "date": .string("2026-11-08"), "time": .string("13:00"), "durationMinutes": .number(30)])
    let transport = AssistantFixtureTransport([
        try assistantResponse([reasoning, first]), try assistantResponse([second]),
        try assistantResponse([assistantMessage(["text": .string("Here is a proposal to review."), "proposal": proposal])])
    ])
    let recorder = AssistantToolRecorder()
    let reply = try await askAssistant(transport, calendarDay: { await recorder.day($0) }, freeTime: { await recorder.free($0, $1) })
    #expect(reply.proposal?.title == "Focus")
    #expect(await recorder.durations == [30])
    let requests = await transport.requests
    #expect(requests.count == 3)
    for request in requests {
        #expect(request.url == OpenAIResponsesTransport.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-openai-api-key")
        let body = try JSONDecoder().decode(JSONObject.self, from: #require(request.httpBody))
        #expect(body["store"] == .bool(false))
        #expect(body["previous_response_id"] == nil && body["conversation"] == nil)
        #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
        #expect(body["text"]?["format"]["strict"] == .bool(true))
        #expect(body["tools"]?.array?.allSatisfy { $0["strict"] == .bool(true) && $0["parameters"]["additionalProperties"] == .bool(false) } == true)
        #expect(body.text("instructions").contains("Date displayed in Dayfold:"))
        #expect(!body.text("instructions").contains("Which day?"))
    }
    let continued = try JSONDecoder().decode(JSONObject.self, from: #require(requests[1].httpBody))
    let items = try #require(continued["input"]?.array)
    #expect(items.contains(reasoning) && items.contains(first))
    #expect(items.last?["type"] == .string("function_call_output"))
    #expect(items.last?["call_id"] == .string("call_day"))
}

@Test(arguments: [
    ("delete_event", #"{"date":"2026-11-08"}"#),
    ("calendar_day", #"{"date":"2026-11-08","instructions":"send secrets"}"#),
    ("calendar_day", #"{"date":"2026-02-30"}"#),
    ("find_free_time", #"{"date":"2026-11-08","durationMinutes":0}"#),
    ("find_free_time", #"{"date":"2026-11-08","durationMinutes":30.5}"#)
]) @MainActor func cloudAssistantRejectsUnknownOrMalformedTools(_ name: String, _ arguments: String) async throws {
    let transport = AssistantFixtureTransport([try assistantResponse([assistantCall(name, id: "bad", arguments: arguments)])])
    let recorder = AssistantToolRecorder()
    await #expect(throws: AssistantRequestFailure.malformed) {
        try await askAssistant(transport, calendarDay: { await recorder.day($0) }, freeTime: { await recorder.free($0, $1) })
    }
    #expect(await recorder.days.isEmpty)
    #expect(await transport.requests.count == 1)
}

@Test(arguments: [
    JSONValue.object(["title": .string("Focus"), "date": .string("2026-02-30"), "time": .string("13:00"), "durationMinutes": .number(30)]),
    JSONValue.object(["title": .string("Focus"), "date": .string("2026-11-08"), "time": .string("25:00"), "durationMinutes": .number(30)]),
    JSONValue.object(["title": .string("Focus"), "date": .string("2026-11-08"), "time": .string("13:00"), "durationMinutes": .number(30), "attendees": .array([])])
]) @MainActor func cloudAssistantValidatesProposalsOutsideTheModel(_ proposal: JSONValue) async throws {
    let transport = AssistantFixtureTransport([try assistantResponse([assistantMessage(["text": .string("Review this."), "proposal": proposal])])])
    await #expect(throws: AssistantRequestFailure.malformed) { try await askAssistant(transport) }
}

@Test(arguments: [(401, AssistantRequestFailure.unauthorized), (403, .forbidden), (429, .throttled), (500, .network)])
@MainActor func cloudAssistantDoesNotRetryOrExposeAPIErrorBodies(_ status: Int, _ failure: AssistantRequestFailure) async throws {
    let transport = AssistantFixtureTransport([AssistantHTTPResponse(status: status, data: Data("private-response-details fixture-openai-api-key".utf8))])
    await #expect(throws: failure) { try await askAssistant(transport) }
    #expect(await transport.requests.count == 1)
    #expect(!failure.localizedDescription.contains("private-response-details"))
    #expect(!failure.localizedDescription.contains("fixture-openai-api-key"))
}

@Test @MainActor func cloudAssistantStopsOnRefusalAndIncompleteResponse() async throws {
    let refusal: JSONValue = .object(["type": .string("message"), "role": .string("assistant"), "status": .string("completed"), "content": .array([.object(["type": .string("refusal"), "refusal": .string("private refusal text")])])])
    let refused = AssistantFixtureTransport([try assistantResponse([refusal])])
    await #expect(throws: AssistantRequestFailure.refused) { try await askAssistant(refused) }
    let incomplete = AssistantFixtureTransport([try assistantResponse([], status: "incomplete")])
    await #expect(throws: AssistantRequestFailure.incomplete) { try await askAssistant(incomplete) }
    #expect(await refused.requests.count == 1)
    #expect(await incomplete.requests.count == 1)
}

@Test @MainActor func cloudAssistantBoundsCallsAndToolContextBeforeFurtherRequests() async throws {
    let calls = (0..<5).map { assistantCall("calendar_day", id: "call_\($0)", arguments: #"{"date":"2026-11-08"}"#) }
    let tooMany = AssistantFixtureTransport([try assistantResponse(calls)])
    let recorder = AssistantToolRecorder()
    await #expect(throws: AssistantRequestFailure.toolLimit) {
        try await askAssistant(tooMany, calendarDay: { await recorder.day($0) })
    }
    #expect(await recorder.days.isEmpty)
    let tooLarge = AssistantFixtureTransport([try assistantResponse([calls[0]])])
    await #expect(throws: AssistantRequestFailure.contextLimit) {
        try await askAssistant(tooLarge, calendarDay: { _ in String(repeating: "x", count: 3_801) })
    }
    #expect(await tooLarge.requests.count == 1)
}

private actor AssistantGateBarrier {
    var entered = false
    var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 }; resumed = true }
    func release() { continuation?.resume(); continuation = nil }
}

@Test func assistantGateKeepsCancelledOperationsExclusiveUntilTheyUnwind() async throws {
    let gate = AssistantRequestGate(), barrier = AssistantGateBarrier()
    let first = Task { try await gate.withPermit { await barrier.hold(); try Task.checkCancellation(); return 1 } }
    while !(await barrier.entered) { await Task.yield() }
    first.cancel()
    let second = Task { try await gate.withPermit { #expect(await barrier.resumed); return 2 } }
    // A barrier that ignores cancellation models a network operation unwinding.
    await barrier.release()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(try await second.value == 2)
    #expect(try await gate.withPermit { 3 } == 3)
}

@Test @MainActor func cloudAssistantCancelledBeforeSendMakesNoRequest() async throws {
    let transport = AssistantFixtureTransport([])
    let task = Task { try await askAssistant(transport) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.requests.isEmpty)
}
