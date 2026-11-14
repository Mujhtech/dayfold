import Foundation

struct AssistantHTTPResponse: Sendable {
    let status: Int
    let data: Data
}

protocol AssistantHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AssistantHTTPResponse
}

enum AssistantRequestFailure: Error, LocalizedError, Equatable, Sendable {
    case unauthorized, forbidden, throttled, rejected, network, redirected, oversized, malformed, incomplete, refused, toolLimit, contextLimit

    var errorDescription: String? {
        switch self {
        case .unauthorized: "OpenAI didn’t accept this API key. Update it in Assistant settings."
        case .forbidden: "This OpenAI API key doesn’t have access to the selected model. Check the key’s permissions or choose another model."
        case .throttled: "OpenAI’s usage or rate limit was reached. Check your API account, then try again."
        case .rejected: "OpenAI couldn’t accept this request. Check that the selected model supports tools and structured responses."
        case .network: "The assistant couldn’t reach OpenAI. Check your connection and try again."
        case .redirected: "The assistant connection was redirected and was stopped to protect your API key."
        case .oversized: "OpenAI returned more data than this request can use. Try a narrower question."
        case .malformed: "The assistant returned an answer that couldn’t be verified. Try a more specific request."
        case .incomplete: "The assistant didn’t finish its answer. Try a shorter request about one day."
        case .refused: "The assistant couldn’t help with that request. Try a specific calendar question or use Calendar directly."
        case .toolLimit: "This request needs too many calendar lookups. Try asking about one day."
        case .contextLimit: "There’s too much calendar information for one answer. Try a narrower question."
        }
    }
}

struct OpenAIResponsesTransport: AssistantHTTPTransport {
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let maximumResponseBytes = 1_048_576
    private let configuration: @Sendable () -> URLSessionConfiguration

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configuration = configuration
    }

    static func makeSession(configuration: URLSessionConfiguration, delegate: any URLSessionDelegate) -> URLSession {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> AssistantHTTPResponse {
        guard request.url == Self.endpoint, request.httpMethod == "POST" else { throw AssistantRequestFailure.redirected }
        let policy = AssistantRedirectPolicy()
        let session = Self.makeSession(configuration: configuration(), delegate: policy)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request)
                guard !policy.rejected, response.url == Self.endpoint,
                      let response = response as? HTTPURLResponse else { throw AssistantRequestFailure.redirected }
                guard !(300..<400).contains(response.statusCode) else { throw AssistantRequestFailure.redirected }
                // Error bodies can echo request details. Never decode or surface them.
                guard (200..<300).contains(response.statusCode) else {
                    return AssistantHTTPResponse(status: response.statusCode, data: Data())
                }
                guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw AssistantRequestFailure.oversized }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < Self.maximumResponseBytes else { throw AssistantRequestFailure.oversized }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return AssistantHTTPResponse(status: response.statusCode, data: data)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if policy.rejected { throw AssistantRequestFailure.redirected }
                if let failure = error as? AssistantRequestFailure { throw failure }
                throw AssistantRequestFailure.network
            }
        } onCancel: { session.invalidateAndCancel() }
    }
}

final class AssistantRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var didReject = false
    var rejected: Bool { lock.withLock { didReject } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.withLock { didReject = true }
        completionHandler(nil)
        task.cancel()
    }
}
