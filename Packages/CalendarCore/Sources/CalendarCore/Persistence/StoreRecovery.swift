import Foundation

public enum StoreRecovery {
    /// Call only after releasing every database connection and process lock.
    /// Rename the whole store so SQLite sidecars and pending work remain together.
    public static func preserveAndCreateEmptyStore(at directory: URL) throws -> URL {
        let files = FileManager.default
        guard files.fileExists(atPath: directory.path) else { throw CalendarError.missing }
        let stamp = InternetDate.string(Date()).replacingOccurrences(of: ":", with: "-")
        let preserved = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-preserved-" + stamp + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        try files.moveItem(at: directory, to: preserved)
        do { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { try? files.moveItem(at: preserved, to: directory); throw error }
        return preserved
    }
}
