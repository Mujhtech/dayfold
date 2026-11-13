import Foundation

public struct RelayClient: RelayClientProtocol, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let baseURL: URL
    private let token: String?
    private let authorizer: (any RelayRequestAuthorizing)?
    private let transport: any RelayTransport
    private static let maximumResponseBytes = 1024 * 1024

    public init(baseURL: URL, token: String, allowLoopbackHTTP: Bool = false,
                transport: (any RelayTransport)? = nil) throws {
        self.baseURL = try RelayEndpoint.validatedOrigin(baseURL, allowLoopbackHTTP: allowLoopbackHTTP)
        try RelayEndpoint.validateToken(token)
        self.token = token
        self.authorizer = nil
        self.transport = transport ?? RelayURLSessionTransport()
    }

    public init(baseURL: URL, authorizer: any RelayRequestAuthorizing, allowLoopbackHTTP: Bool = false,
                transport: (any RelayTransport)? = nil) throws {
        self.baseURL = try RelayEndpoint.validatedOrigin(baseURL, allowLoopbackHTTP: allowLoopbackHTTP)
        self.token = nil; self.authorizer = authorizer
        self.transport = transport ?? RelayURLSessionTransport()
    }

    public var description: String { "RelayClient(credential: [REDACTED])" }
    public var debugDescription: String { description }

    public func capabilities() async throws -> RelayCapabilities {
        try await decoded("GET", path: "v1/capabilities")
    }

    public func cursor() async throws -> RelayCursor {
        let value: RelayCursor = try await decoded("GET", path: "v1/notifications/cursor")
        guard value.floor >= 0, value.current >= value.floor else { throw RelayClientError.invalidResponse }
        return value
    }

    public func notifications(after: Int64) async throws -> RelayNotificationPage {
        guard after >= 0 else { throw RelayClientError.invalidRequest }
        let page: RelayNotificationPage = try await decoded("GET", path: "v1/notifications", query: [.init(name: "after", value: String(after))])
        guard page.cursorFloor >= 0, page.latestSequence >= page.cursorFloor,
              page.latestSequence >= after, page.notifications.count <= 100 else { throw RelayClientError.invalidResponse }
        guard after >= page.cursorFloor else { throw RelayClientError.resyncRequired }
        var previous = after
        for notification in page.notifications {
            try notification.validate()
            guard notification.sequence > previous, notification.sequence <= page.latestSequence else { throw RelayClientError.invalidResponse }
            previous = notification.sequence
        }
        return page
    }

    public func acknowledge(sequence: Int64) async throws {
        guard sequence >= 0 else { throw RelayClientError.invalidRequest }
        try await discard("POST", path: "v1/notifications/ack", body: encode(Acknowledgement(sequence: sequence)))
    }

    public func claimReminder(notificationID: UUID) async throws -> Bool {
        let result: ClaimResult = try await decoded("POST", path: "v1/notifications/\(notificationID.uuidString)/claim")
        return result.claimed
    }

    public func reserveChannel(scopeID: UUID, expiresAt: Date) async throws -> RelayChannelReservation {
        let reservation: RelayChannelReservation = try await decoded("POST", path: "v1/channels", body: encode(Reservation(scopeID: scopeID, expiresAt: expiresAt)))
        do { try RelayEndpoint.validateToken(reservation.token) }
        catch { throw RelayClientError.invalidResponse }
        guard let address = URLComponents(url: reservation.address, resolvingAgainstBaseURL: false),
              address.scheme == "https", address.host != nil, address.user == nil, address.password == nil,
              address.fragment == nil, address.query == nil else { throw RelayClientError.invalidResponse }
        return reservation
    }

    public func activateChannel(id: UUID, resourceID: String, expiresAt: Date) async throws {
        guard !resourceID.isEmpty, resourceID.utf8.count <= 512, resourceID.utf8.allSatisfy({ (32...126).contains($0) }) else { throw RelayClientError.invalidRequest }
        try await discard("PUT", path: "v1/channels/\(id.uuidString)", body: encode(Activation(resourceID: resourceID, expiresAt: expiresAt)))
    }

    public func revokeChannel(id: UUID) async throws {
        try await discard("DELETE", path: "v1/channels/\(id.uuidString)")
    }

    public func putReminder(id: UUID, revision: Int64, dueAt: Date, expiresAt: Date) async throws {
        guard revision > 0, expiresAt > dueAt else { throw RelayClientError.invalidRequest }
        try await discard("PUT", path: "v1/reminders/\(id.uuidString)", body: encode(Reminder(revision: revision, dueAt: dueAt, expiresAt: expiresAt)))
    }

    public func deleteReminder(id: UUID, revision: Int64) async throws {
        guard revision > 0 else { throw RelayClientError.invalidRequest }
        try await discard("DELETE", path: "v1/reminders/\(id.uuidString)", query: [.init(name: "revision", value: String(revision))])
    }

    public func registerPush(token: String, environment: RelayPushEnvironment) async throws {
        guard (32...256).contains(token.utf8.count), token.utf8.count.isMultiple(of: 2), token.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw RelayClientError.invalidRequest }
        try await discard("PUT", path: "v1/device/push", body: encode(PushRegistration(token: token.lowercased(), environment: environment)))
    }

    public func revokeDevice() async throws { try await discard("DELETE", path: "v1/device") }

    public func accountDevices() async throws -> [RelayAccountDevice] {
        let response: AccountDevices = try await decoded("GET", path: "v1/account/devices")
        guard response.devices.count <= 100 else { throw RelayClientError.invalidResponse }
        return response.devices
    }
    public func revokeAccountDevice(_ id: UUID) async throws {
        try await discard("DELETE", path: "v1/account/devices/\(id.uuidString.lowercased())")
    }
    public func revokeAllAccountDevices() async throws { try await discard("POST", path: "v1/account/revoke-all") }
    public func deleteAccount() async throws { try await discard("DELETE", path: "v1/account") }

    public func events(after: Int64) -> AsyncThrowingStream<RelayStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let producer = Task {
                do {
                    guard after >= 0 else { throw RelayClientError.invalidRequest }
                    var rejectedID: UUID?
                    for attempt in 0...1 {
                    let authorized = try await request("GET", path: "v1/events", rejecting: rejectedID)
                    var request = authorized.request
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(String(after), forHTTPHeaderField: "Last-Event-ID")
                    var receivedHead = false
                    var parser = RelaySSEParser()
                    var lastSequence = after
                    let connection = transport.stream(request)
                    defer { connection.cancel() }
                    let expiryTask = authorized.authorization?.expiresAt.map { expiry in
                        Task {
                            do { try await Task.sleep(for: .seconds(max(1, expiry.timeIntervalSinceNow))) }
                            catch { return }
                            connection.cancel()
                        }
                    }
                    defer { expiryTask?.cancel() }
                    do {
                    for try await part in connection.events {
                        try Task.checkCancellation()
                        switch part {
                        case .response(let head):
                            guard !receivedHead else { throw RelayClientError.invalidResponse }
                            try validate(head, request: request)
                            guard head.header("Content-Type")?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "text/event-stream" else { throw RelayClientError.invalidResponse }
                            receivedHead = true
                        case .data(let bytes):
                            guard receivedHead else { throw RelayClientError.invalidResponse }
                            for event in try parser.append(bytes) {
                                if case .notification(let notification) = event {
                                    guard notification.sequence > lastSequence else { throw RelayClientError.invalidResponse }
                                    lastSequence = notification.sequence
                                }
                                switch continuation.yield(event) {
                                case .enqueued: break
                                case .dropped: throw RelayClientError.streamOverflow
                                case .terminated: throw RelayClientError.cancelled
                                @unknown default: throw RelayClientError.streamOverflow
                                }
                                if event == .resyncRequired { continuation.finish(); return }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard receivedHead else { throw RelayClientError.invalidResponse }
                    try parser.finish()
                    continuation.finish()
                    return
                    } catch RelayClientError.unauthorized where attempt == 0 && authorizer != nil {
                        rejectedID = authorized.authorization?.id
                        continue
                    }
                    }
                } catch { continuation.finish(throwing: Self.sanitized(error)) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func request(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil,
                         rejecting id: UUID? = nil) async throws -> (request: URLRequest, authorization: RelayRequestAuthorization?) {
        guard var url = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw RelayClientError.invalidRequest }
        if !query.isEmpty { url.queryItems = query }
        guard let endpoint = url.url else { throw RelayClientError.invalidRequest }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = body
        let authorization = try await authorizer?.authorization(method: method, url: endpoint, rejecting: id)
        if let authorization {
            for (key, value) in authorization.headers { request.setValue(value, forHTTPHeaderField: key) }
        } else if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return (request, authorization)
    }

    private func encodedRequest(_ method: String, path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        do {
            try Task.checkCancellation()
            var rejectedID: UUID?
            for attempt in 0...1 {
            let authorized = try await request(method, path: path, query: query, body: body, rejecting: rejectedID)
            let response = try await transport.send(authorized.request)
            if response.head.status == 401, response.head.url == authorized.request.url, attempt == 0, authorizer != nil {
                rejectedID = authorized.authorization?.id
                continue
            }
            try validate(response.head, request: authorized.request)
            guard response.body.count <= Self.maximumResponseBytes else { throw RelayClientError.invalidResponse }
            return response.body
            }
            throw RelayClientError.unauthorized
        } catch { throw Self.sanitized(error) }
    }

    private func decoded<T: Decodable & Sendable>(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        let data = try await encodedRequest(method, path: path, query: query, body: body)
        do { return try RelayJSON.decoder().decode(T.self, from: data) }
        catch { throw RelayClientError.invalidResponse }
    }

    private func discard(_ method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws {
        _ = try await encodedRequest(method, path: path, query: query, body: body)
    }

    private func encode<T: Encodable>(_ body: T) throws -> Data {
        do { return try RelayJSON.encoder().encode(body) }
        catch { throw RelayClientError.invalidRequest }
    }

    private func validate(_ head: RelayHTTPHead, request: URLRequest) throws {
        guard head.url == request.url else { throw RelayClientError.invalidResponse }
        let retry = Self.retryAfter(head.header("Retry-After"))
        switch head.status {
        case 200..<300: return
        case 401: throw RelayClientError.unauthorized
        case 410: throw RelayClientError.resyncRequired
        case 429: throw RelayClientError.rateLimited(retryAfter: retry)
        case 500...599: throw RelayClientError.unavailable(retryAfter: retry)
        default: throw RelayClientError.rejected(status: head.status)
        }
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value, value.utf8.count <= 128 else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(seconds, 86_400) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), 86_400)
    }

    static func sanitized(_ error: Error) -> RelayClientError {
        if let error = error as? RelayClientError { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        return .transport
    }
}

private struct Acknowledgement: Encodable { let sequence: Int64 }
private struct ClaimResult: Decodable, Sendable { let claimed: Bool }
private struct Reservation: Encodable {
    let scopeID: UUID; let expiresAt: Date
    enum CodingKeys: String, CodingKey { case scopeID = "scope_id", expiresAt = "expires_at" }
}
private struct Activation: Encodable {
    let resourceID: String; let expiresAt: Date
    enum CodingKeys: String, CodingKey { case resourceID = "resource_id", expiresAt = "expires_at" }
}
private struct Reminder: Encodable {
    let revision: Int64; let dueAt: Date; let expiresAt: Date
    enum CodingKeys: String, CodingKey { case revision; case dueAt = "due_at", expiresAt = "expires_at" }
}
private struct PushRegistration: Encodable { let token: String; let environment: RelayPushEnvironment }
private struct AccountDevices: Decodable, Sendable { let devices: [RelayAccountDevice] }

/// Each request owns a session delegate so cancellation and redirects are scoped
/// to that request. Ephemeral sessions hold no cookies, credentials or URL cache.
public struct RelayURLSessionTransport: RelayTransport, Sendable {
    private let configurationFactory: @Sendable () -> URLSessionConfiguration
    private var includeErrorBody = false
    public init(includeErrorBody: Bool = false) { configurationFactory = { .ephemeral }; self.includeErrorBody = includeErrorBody }
    init(configurationFactory: @escaping @Sendable () -> URLSessionConfiguration) {
        self.configurationFactory = configurationFactory
    }

    public func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        var head: RelayHTTPHead?
        var body = Data()
        let connection = RelaySessionOperation().start(request, configuration: configurationFactory(), resourceTimeout: 90)
        defer { connection.cancel() }
        for try await part in connection.events {
            try Task.checkCancellation()
            switch part {
            case .response(let value):
                guard head == nil else { throw RelayClientError.invalidResponse }
                head = value
                if !(200..<300).contains(value.status), !includeErrorBody { return RelayHTTPResponse(head: value) }
            case .data(let bytes):
                guard head != nil, body.count + bytes.count <= 1024 * 1024 else { throw RelayClientError.invalidResponse }
                body.append(bytes)
            }
        }
        try Task.checkCancellation()
        guard let head else { throw RelayClientError.invalidResponse }
        return RelayHTTPResponse(head: head, body: body)
    }

    public func stream(_ request: URLRequest) -> RelayTransportStream {
        RelaySessionOperation().start(request, configuration: configurationFactory())
    }
}

private final class RelaySessionOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<RelayTransportEvent, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false

    func start(_ request: URLRequest, configuration: URLSessionConfiguration, resourceTimeout: TimeInterval = 3600) -> RelayTransportStream {
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        let events = AsyncThrowingStream<RelayTransportEvent, Error>(bufferingPolicy: .bufferingOldest(16)) { continuation in
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            lock.withLock { self.continuation = continuation; self.session = session; self.task = task }
            continuation.onTermination = { @Sendable [weak self] _ in self?.finish(RelayClientError.cancelled) }
            task.resume()
        }
        return RelayTransportStream(events: events, cancel: { self.finish(RelayClientError.cancelled) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(RelayClientError.rejected(status: response.statusCode))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let url = response.url else {
            completionHandler(.cancel); finish(RelayClientError.invalidResponse); return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        completionHandler(emit(.response(RelayHTTPHead(url: url, status: response.statusCode, headers: headers))) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= 1024 * 1024 else { finish(RelayClientError.invalidResponse); return }
        // Bound both queued chunk count and individual allocation size. Overflow
        // closes the connection; the consumer resumes from its durable cursor.
        for start in stride(from: 0, to: data.count, by: 16 * 1024) {
            guard emit(.data(data.subdata(in: start..<min(start + 16 * 1024, data.count)))) else { return }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error.map(RelayClient.sanitized))
    }

    private func emit(_ event: RelayTransportEvent) -> Bool {
        guard let continuation = lock.withLock({ self.continuation }) else { return false }
        switch continuation.yield(event) {
        case .enqueued: return true
        case .dropped: finish(RelayClientError.streamOverflow); return false
        case .terminated: finish(RelayClientError.cancelled); return false
        @unknown default: finish(RelayClientError.streamOverflow); return false
        }
    }

    private func finish(_ error: Error?) {
        let state = lock.withLock { () -> (AsyncThrowingStream<RelayTransportEvent, Error>.Continuation?, URLSessionDataTask?, URLSession?)? in
            guard !completed else { return nil }
            completed = true
            let value = (continuation, task, session)
            continuation = nil; task = nil; session = nil
            return value
        }
        guard let (continuation, task, session) = state else { return }
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
        task?.cancel(); session?.invalidateAndCancel()
    }
}
