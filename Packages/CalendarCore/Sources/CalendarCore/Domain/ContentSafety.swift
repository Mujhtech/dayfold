import Foundation

public enum RichTextSafety {
    public static func plainText(_ html: String) -> String {
        var result = String(html.prefix(100_000))
        for pattern in ["(?is)<script\\b[^>]*>.*?</script>", "(?is)<style\\b[^>]*>.*?</style>", "<[^>]+>"] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
    public static func webURL(_ string: String) -> URL? {
        guard string.count < 8192, let url = URL(string: string), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    public static func meetingLinks(_ event: CalendarEvent) -> [URL] {
        let entries = event.raw["conferenceData"]?["entryPoints"].array ?? []
        let structured = entries.filter { $0["entryPointType"].string == "video" }.compactMap { $0["uri"].string }.compactMap(webURL)
        if !structured.isEmpty { return Array(Set(structured)).sorted { $0.absoluteString < $1.absoluteString } }
        if let hangout = webURL(event.raw.text("hangoutLink")) { return [hangout] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let text = event.location + " " + event.plainDescription
        let known = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"]
        return Array(Set(detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).filter {
            guard let url = webURL($0.absoluteString), let host = url.host?.lowercased() else { return false }
            return known.contains { host == $0 || host.hasSuffix("." + $0) }
        })).sorted { $0.absoluteString < $1.absoluteString }
    }
}
