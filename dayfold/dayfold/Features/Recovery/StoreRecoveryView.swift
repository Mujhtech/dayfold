import SwiftUI
import AppKit
import CalendarCore

struct StoreRecoveryView: View {
    @Bindable var model: AppModel
    let failure: String
    @State private var confirmFreshStore = false
    var body: some View {
        ContentUnavailableView {
            Label("Your data is preserved", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(failure)
            Text("You can copy the preserved files before trying a fresh cache. Unsent work is never replayed automatically.")
        } actions: {
            Button("Retry") { Task { await model.loadStore(demo: model.isDemo) } }
            Button("Copy preserved files…") { model.copyPreservedStore() }.disabled(model.dataDirectory == nil)
            Button("Start a fresh cache…") { confirmFreshStore = true }.disabled(model.dataDirectory == nil)
        }
        .confirmationDialog("Preserve this store and start a fresh cache?", isPresented: $confirmFreshStore, titleVisibility: .visible) {
            Button("Preserve files and start fresh") { Task { await model.recoverStore() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The entire existing store, including drafts and pending changes, will be moved to a preserved folder. The new cache requires reconnecting your accounts. Unsent work remains in the preserved files for recovery and is not sent or deleted from Google.")
        }
    }
}

extension AppModel {
    func copyPreservedStore() {
        guard let source = preservedDirectory ?? dataDirectory else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Copy here"; panel.message = "This copy includes private calendar data and unsent work. Choose a trusted folder. Google credentials remain in Keychain."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let name = source.lastPathComponent + "-recovery-" + UUID().uuidString.prefix(8)
            let copy = destination.appendingPathComponent(String(name), isDirectory: true)
            try FileManager.default.copyItem(at: source, to: copy)
            NSWorkspace.shared.activateFileViewerSelecting([copy])
        } catch { errorMessage = error.localizedDescription }
    }
    func recoverStore() async {
        guard fatalMessage != nil, let directory = dataDirectory else { return }
        observer?.cancel(); poller?.cancel(); prefetcher?.cancel(); minuteTimer?.cancel()
        repository = nil; dispatcher = nil; sync = nil; notifications = nil; provider = nil; ownership = nil
        do {
            preservedDirectory = try StoreRecovery.preserveAndCreateEmptyStore(at: directory)
            await loadStore(demo: isDemo)
            if let preservedDirectory { NSWorkspace.shared.activateFileViewerSelecting([preservedDirectory]) }
        } catch { fatalMessage = "The original store is still preserved. " + error.localizedDescription }
    }
}
