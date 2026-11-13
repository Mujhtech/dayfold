import Foundation
import GRDB

extension CalendarRepository {
    public func relayState() throws -> RelayState {
        try database.read { db in
            try Self.decode(RelayState.self, row: Row.fetchOne(db, sql: "SELECT payload FROM relay_state WHERE id='main'")) ?? RelayState()
        }
    }
    /// Does not emit a calendar change: stream cursors must not recursively reload the UI.
    public func saveRelayState(_ state: RelayState) throws {
        try database.write { try Self.put(state, id: "main", table: "relay_state", db: $0) }
    }
    public func clearRelayState() throws { try database.write { try $0.execute(sql: "DELETE FROM relay_state") } }
}
