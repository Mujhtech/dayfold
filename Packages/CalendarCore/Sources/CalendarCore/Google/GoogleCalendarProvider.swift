import Foundation

public struct GoogleCalendarProvider: CalendarProvider {
    public let tokens: any AccessTokenSource
    public let transport: any HTTPTransport
    public let budget: RequestBudget
    public init(tokens: any AccessTokenSource, transport: any HTTPTransport = URLSessionTransport(), budget: RequestBudget = RequestBudget()) { self.tokens = tokens; self.transport = transport; self.budget = budget }
    public static func url(path: [String], parameters: [String: String] = [:]) -> URL {
        var c = URLComponents(); c.scheme = "https"; c.host = "www.googleapis.com"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        c.percentEncodedPath = "/calendar/v3/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        c.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
    func request(account: AccountID, path: [String], parameters: [String: String] = [:], method: String = "GET", body: JSONObject? = nil, etag: String? = nil) async throws -> JSONObject {
        for attempt in 0...1 {
            var req = URLRequest(url: Self.url(path: path, parameters: parameters)); req.httpMethod = method
            let token = try await tokens.accessToken(for: account, forceRefresh: attempt == 1)
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { req.httpBody = try JSONEncoder().encode(body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let etag { req.setValue(etag, forHTTPHeaderField: "If-Match") }
            try await budget.acquire(account)
            let response: HTTPResponse
            do { try Task.checkCancellation(); response = try await transport.send(req); await budget.release(account) }
            catch { await budget.release(account); throw error }
            if response.status == 401 && attempt == 0 { continue }
            let json = response.data.isEmpty ? [:] : (try? JSONDecoder().decode(JSONObject.self, from: response.data))
            guard (200..<300).contains(response.status) else {
                let reason = json?["error"]?["errors"].array?.first?["reason"].string ?? ""
                let failure = ProviderError.classify(status: response.status, reason: reason, retryAfter: response.retryAfter)
                if case .throttled(let seconds) = failure { await budget.pause(account, seconds: seconds ?? 60) }
                throw failure
            }
            guard let json else { throw ProviderError.malformed }; return json
        }
        throw ProviderError.unauthorized
    }
    public func calendars(account: AccountID, page: String?) async throws -> ProviderPage<CalendarSource> {
        var p = ["showHidden": "true", "showDeleted": "true", "maxResults": "250"]; p["pageToken"] = page
        let json = try await request(account: account, path: ["users", "me", "calendarList"], parameters: p)
        guard json.text("kind") == "calendar#calendarList" else { throw ProviderError.malformed }
        let sources = try (json["items"]?.array ?? []).map { item -> CalendarSource in
            guard let raw = item.object, let id = raw["id"]?.string, id != "primary" else { throw ProviderError.malformed }
            var source = CalendarSource(key: CalendarKey(account: account, calendarID: id), title: raw.text("summaryOverride", default: raw.text("summary", default: id)), timeZone: raw.text("timeZone", default: "UTC"), role: raw.text("accessRole", default: "unknown"), color: raw.text("backgroundColor", default: "#5379C4"), primary: raw.flag("primary"), hidden: raw.flag("hidden"), syncEnabled: false, visible: false)
            source.deleted = raw.flag("deleted")
            source.defaultReminderMinutes = (raw["defaultReminders"]?.array ?? []).filter { $0["method"].string == "popup" }.compactMap { $0["minutes"].number.map(Int.init) }
            source.allowsMeet = raw["conferenceProperties"]?["allowedConferenceSolutionTypes"].array?.contains(.string("hangoutsMeet")) == true
            return source
        }
        return ProviderPage(items: sources, nextPage: json["nextPageToken"]?.string, syncToken: json["nextSyncToken"]?.string)
    }
    public func events(source: CalendarSource, query: EventQuery, page: String?) async throws -> ProviderPage<CalendarEvent> {
        var p = query.parameters; p["pageToken"] = page
        let json = try await request(account: source.key.account, path: ["calendars", source.key.calendarID, "events"], parameters: p)
        guard json.text("kind") == "calendar#events" else { throw ProviderError.malformed }
        let events = try (json["items"]?.array ?? []).map { value -> CalendarEvent in
            guard let raw = value.object, let id = raw["id"]?.string else { throw ProviderError.malformed }
            let event = CalendarEvent(key: EventKey(calendar: source.key, eventID: id), raw: raw, calendarZone: source.timeZone)
            guard event.cancelled || event.time != nil else { throw ProviderError.malformed }
            return event
        }
        return ProviderPage(items: events, nextPage: json["nextPageToken"]?.string, syncToken: json["nextSyncToken"]?.string)
    }
    public func event(_ key: EventKey, zone: String) async throws -> CalendarEvent {
        let raw = try await request(account: key.calendar.account, path: ["calendars", key.calendar.calendarID, "events", key.eventID])
        guard raw.text("id") == key.eventID else { throw ProviderError.malformed }
        return CalendarEvent(key: key, raw: raw, calendarZone: zone)
    }
    public func write(_ mutation: Mutation, etag: String?, zone: String) async throws -> CalendarEvent? {
        var path = ["calendars", mutation.key.calendar.calendarID, "events"]
        var fields = mutation.fields
        let method: String
        switch mutation.kind {
        case .create: method = "POST"; fields["id"] = .string(mutation.key.eventID)
        case .patch, .rsvp: method = "PATCH"; path.append(mutation.key.eventID)
        case .delete: method = "DELETE"; path.append(mutation.key.eventID)
        }
        var parameters = ["sendUpdates": mutation.sendUpdates]
        if mutation.kind != .delete { parameters["conferenceDataVersion"] = "1"; parameters["supportsAttachments"] = "true" }
        let raw = try await request(account: mutation.key.calendar.account, path: path, parameters: parameters, method: method, body: mutation.kind == .delete ? nil : fields, etag: etag)
        if mutation.kind == .delete { return nil }
        guard raw.text("id") == mutation.key.eventID else { throw ProviderError.malformed }
        return CalendarEvent(key: mutation.key, raw: raw, calendarZone: zone)
    }
    public func busy(source: CalendarSource, window: DateInterval) async throws -> [CalendarEvent] {
        let json = try await request(account: source.key.account, path: ["freeBusy"], method: "POST", body: ["timeMin": .string(InternetDate.string(window.start)), "timeMax": .string(InternetDate.string(window.end)), "items": .array([.object(["id": .string(source.key.calendarID)])])])
        guard let result = json["calendars"]?[source.key.calendarID].object, result["errors"]?.array?.isEmpty != false else { throw ProviderError.forbidden }
        return try (result["busy"]?.array ?? []).enumerated().map { index, value in
            guard let start = value["start"].string, let end = value["end"].string,
                  let startDate = InternetDate.parse(start), let endDate = InternetDate.parse(end), endDate > startDate else { throw ProviderError.malformed }
            let id = "busy-\(window.start.timeIntervalSince1970)-\(index)"
            return CalendarEvent(key: EventKey(calendar: source.key, eventID: id), raw: ["id": .string(id), "summary": .string("Busy"), "dayfoldRedacted": .bool(true), "start": .object(["dateTime": .string(start)]), "end": .object(["dateTime": .string(end)])], calendarZone: source.timeZone)
        }
    }
}
