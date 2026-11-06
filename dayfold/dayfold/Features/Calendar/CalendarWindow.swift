import SwiftUI
import AppKit
import CalendarCore
import CalendarPlatform

struct CalendarWindow: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var searchFocused: Bool
    @State private var showStatus = false
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 215, ideal: 235, max: 300)
        } detail: {
            Group {
                if let failure = model.fatalMessage {
                    StoreRecoveryView(model: model, failure: failure)
                } else if model.isLoading { ProgressView("Opening your calendars…") }
                else if model.accounts.isEmpty { WelcomeView(model: model) }
                else {
                    VStack(spacing: 0) {
                        if model.isDemo { demoBanner }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rangeTitle).font(.system(size: 25, weight: .semibold, design: .rounded))
                                Text(model.preferences.timeZone.identifier.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.page == .calendar {
                                Picker("Calendar view", selection: $model.mode) { ForEach(CalendarViewMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 286)
                                    .onChange(of: model.mode) { model.dateChanged() }
                            }
                        }.padding(.horizontal, 24).padding(.vertical, 18)
                        Divider()
                        if !model.searchText.isEmpty { searchFilters }
                        if model.page == .pending { PendingChangesView(model: model) }
                        else if model.page == .invitations { AgendaView(model: model, events: model.menuEvents.filter { $0.response == "needsAction" }, emptyTitle: "No pending invitations in the downloaded range") }
                        else if !model.searchText.isEmpty || model.mode == .agenda { AgendaView(model: model, events: model.visibleEvents, emptyTitle: emptyTitle) }
                        else if model.mode == .month { MonthView(model: model) }
                        else { TimelineView(model: model) }
                        Divider()
                        HStack {
                            Circle().fill(model.demoOffline || model.accounts.contains { $0.status != .healthy } ? .orange : .green).frame(width: 6, height: 6)
                            Text(model.statusMessage)
                            if !model.cachedVisibleRange { Text("· Some dates have not been downloaded").foregroundStyle(.secondary) }
                            else if model.staleVisibleRange { Text("· Showing cached events").foregroundStyle(.secondary) }
                            Spacer()
                            Text("\(model.visibleEvents.count) events").monospacedDigit()
                            if !model.pending.isEmpty { Button("\(model.pending.count) pending") { model.page = .pending }.buttonStyle(.link) }
                        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
                    }
                }
            }
            .inspector(isPresented: Binding(get: { model.selectedEvent != nil }, set: { if !$0 { model.selectedEvent = nil } })) {
                if let event = model.selectedEvent { EventInspector(model: model, event: event).inspectorColumnWidth(min: 280, ideal: 310, max: 370) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.navigate(-1) } label: { Image(systemName: "chevron.left") }.help("Previous range")
                Button("Today") { model.today() }
                Button { model.navigate(1) } label: { Image(systemName: "chevron.right") }.help("Next range")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search downloaded events", text: $model.searchText).textFieldStyle(.plain).focused($searchFocused).frame(width: 180) }.padding(6)
                Button { showStatus.toggle() } label: { Image(systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.icloud") }.help("Synchronization status").popover(isPresented: $showStatus) { SyncStatusView(model: model).padding(20).frame(width: 360) }
                Button { model.newDraft() } label: { Label("New Event", systemImage: "plus") }.help("New event (⌘N)")
            }
        }
        .sheet(item: $model.editingDraft) { draft in EventEditor(model: model, draft: draft) }
        .sheet(isPresented: $model.showAccountSetup) { AccountSetupView(model: model) }
        .confirmationDialog("Reverse this confirmed change?", isPresented: Binding(get: { model.reversalRequest != nil }, set: { if !$0 { model.reversalRequest = nil } }), titleVisibility: .visible) {
            Button("Queue reversal") { model.confirmReversal() }
            Button("Cancel", role: .cancel) { model.reversalRequest = nil }
        } message: {
            if let mutation = model.reversalRequest {
                Text("\(mutation.confirmedEvent?.title ?? mutation.base?.title ?? "Calendar change") · \(model.sourceLabel(mutation.key.calendar)). " + (mutation.base?.hasGuests == true || mutation.confirmedEvent?.hasGuests == true ? "This sends a new change and may notify guests again. Google changes are checked for conflicts. Previous messages cannot be unsent." : "Dayfold sends a new change after checking for conflicts with Google."))
            }
        }
        .alert("Dayfold", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.searchText) { model.searchChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .init("DayfoldFocusSearch"))) { _ in searchFocused = true }
        .onAppear {
            model.openCalendar = {
                DayfoldDelegate.launchedAtLogin = false
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("calendar") == true }) { window.makeKeyAndOrderFront(nil) }
                else { openWindow(id: "calendar") }
                NSApp.activate(ignoringOtherApps: true)
            }
            model.openQuickEntry = { DayfoldDelegate.launchedAtLogin = false; openWindow(id: "quick-entry"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
    private var rangeTitle: String {
        if model.page == .pending { return "Pending changes" }; if model.page == .invitations { return "Invitations" }
        let formatter = DateFormatter(); formatter.timeZone = model.preferences.timeZone; formatter.dateFormat = model.mode == .day ? "EEEE, d MMMM" : "MMMM yyyy"; return formatter.string(from: model.selectedDate)
    }
    private var emptyTitle: String { !model.searchText.isEmpty ? "No matching downloaded events" : !model.cachedVisibleRange ? "Events for these dates have not been downloaded" : "A little breathing room" }
    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle"); Text("DEMO").font(.caption.bold()); Text("Fictional calendars. Changes stay on this Mac.").font(.caption)
            Spacer()
            Toggle("Offline", isOn: Binding(get: { model.demoOffline }, set: model.simulateOffline)).toggleStyle(.switch).controlSize(.mini)
            Button("Use Google accounts") { Task { await model.loadStore(demo: false) } }.buttonStyle(.link)
        }.padding(.horizontal, 18).padding(.vertical, 8).background(.orange.opacity(0.08))
    }
    private var searchFilters: some View {
        HStack {
            Text("Search within this downloaded date range").font(.caption).foregroundStyle(.secondary)
            Picker("Account", selection: $model.searchAccount) { Text("All accounts").tag("all"); ForEach(model.accounts) { Text($0.label).tag($0.id.rawValue) } }.frame(maxWidth: 180)
            Picker("Calendar", selection: $model.searchCalendar) { Text("All calendars").tag("all"); ForEach(model.calendars) { Text($0.title).tag($0.id) } }.frame(maxWidth: 180)
            Toggle("Invitations", isOn: $model.invitationsOnly)
            Spacer()
        }.padding(12)
    }
}

struct WelcomeView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "calendar").font(.system(size: 58, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 10) { Text("A little more room\nfor your day.").font(.system(size: 38, weight: .semibold, design: .rounded)).multilineTextAlignment(.center); Text("Work, personal, and everything in between.\nBring your Google calendars together in Dayfold.").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            VStack(spacing: 12) {
                Button(model.isConnecting ? "Waiting for Google…" : "Connect Google Account") { model.connect() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isConnecting)
                Button("Explore Demo") { Task { await model.loadStore(demo: true) } }.buttonStyle(.bordered).controlSize(.large)
                if model.isConnecting { Button("Cancel sign-in") { model.auth.cancel() } }
            }
            Text("Direct connection to Google. A private cache on your Mac.\nNo Dayfold account or cloud storage.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(50).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SyncStatusView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calendar status").font(.headline)
            if model.isDemo { Text("Demo uses a local fake provider.").font(.caption).foregroundStyle(.secondary) }
            ForEach(model.accounts) { a in VStack(alignment: .leading, spacing: 3) { Text(a.label).fontWeight(.medium); Text(a.status.label).font(.caption); if let sync = a.lastSync { Text("Last refreshed \(sync.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }; if a.status == .needsReconnection { Button("Reconnect") { model.connect(expected: a) } } } }
            ForEach(model.calendars.filter { $0.syncEnabled && !$0.deleted }) { source in
                HStack { Text(source.title).lineLimit(1); Spacer(); if source.lastError != nil { Text("Cached · retry pending").foregroundStyle(.orange) } else if let date = source.lastSync { Text(date, style: .time).foregroundStyle(.secondary) } else { Text("Not downloaded").foregroundStyle(.secondary) } }.font(.caption)
            }
            Button("Refresh Now") { Task { await model.refresh() } }.disabled(model.isRefreshing)
        }
    }
}
