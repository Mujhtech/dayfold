import SwiftUI
import AppKit
import CalendarCore
import CalendarPlatform

struct CalendarWindow: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @Namespace private var modeSelection
    @FocusState private var searchFocused: Bool
    @State private var showStatus = false
    @State private var showSearch = false
    private let calendarSurface = Color(nsColor: .windowBackgroundColor)
    var body: some View {
        Group {
            if let failure = model.fatalMessage {
                StoreRecoveryView(model: model, failure: failure)
            } else if model.isLoading {
                ProgressView("Opening your calendars…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isShowingOnboarding {
                OnboardingView(model: model)
            } else if model.page == .assistant {
                AssistantView(model: model)
                    .navigationTitle("")
            } else {
                calendarLayout
            }
        }

        .sheet(item: $model.editingDraft) { draft in
            EventEditor(model: model, draft: draft)
                .modifier(DayfoldAppearance(preference: model.preferences.appearance))
        }
        .sheet(isPresented: $model.showAccountSetup) {
            AccountSetupView(model: model)
                .modifier(DayfoldAppearance(preference: model.preferences.appearance))
        }
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
        .onChange(of: model.page) { if model.page == .assistant { model.selectedEvent = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .init("DayfoldFocusSearch"))) { _ in showSearch = true; searchFocused = true }
        .onAppear {
            model.openCalendar = {
                DayfoldDelegate.launchedAtLogin = false
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("calendar") == true }) { window.makeKeyAndOrderFront(nil) }
                else { openWindow(id: "calendar") }
                NSApp.activate(ignoringOtherApps: true)
            }
            model.openQuickEntry = {
                guard !model.isLoading, !model.isShowingOnboarding, !model.accounts.isEmpty else { return }
                DayfoldDelegate.launchedAtLogin = false
                openWindow(id: "quick-entry")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    private var calendarLayout: some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 184, ideal: 196, max: 200)
        } detail: {
            Group {
                if let failure = model.fatalMessage {
                    StoreRecoveryView(model: model, failure: failure)
                } else if model.isLoading { ProgressView("Opening your calendars…") }
                else {
                    VStack(spacing: 0) {
                        if model.page != .assistant {
                            if showSearch || !model.searchText.isEmpty { searchBar.transition(DayfoldMotion.reveal(reduceMotion, from: .top)) }
                            if !model.searchText.isEmpty { searchFilters.transition(.opacity) }
                        }
                        ZStack {
                            calendarContent
                                .id(surfaceID)
                                .transition(.opacity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .animation(DayfoldMotion.standard(reduceMotion), value: surfaceID)
                        if model.page != .assistant {
                            Divider()
                            HStack {
                            Text(rangeDetail)
                            if model.demoOffline || model.accounts.contains(where: { $0.status != .healthy }) { Text("· " + model.statusMessage).foregroundStyle(.orange) }
                            if !model.cachedVisibleRange { Text("· Some dates have not been downloaded").foregroundStyle(.secondary) }
                            else if model.staleVisibleRange { Text("· Showing cached events").foregroundStyle(.secondary) }
                            Spacer()
                            Text("\(model.visibleEvents.count) events").monospacedDigit()
                            if !model.pending.isEmpty { Button("\(model.pending.count) pending") { model.page = .pending }.buttonStyle(.link) }
                            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 4)
                        }
                    }.animation(DayfoldMotion.standard(reduceMotion), value: showSearch || !model.searchText.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                calendarSurface.ignoresSafeArea(.container, edges: .top)
            }
            .inspector(isPresented: Binding(get: { model.selectedEvent != nil }, set: { if !$0 { model.selectedEvent = nil } })) {
                ZStack {
                    if let event = model.selectedEvent {
                        EventInspector(model: model, event: event)
                            .id(event.id)
                            .transition(.opacity)
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 310, max: 370)
                .animation(DayfoldMotion.quick(reduceMotion), value: model.selectedEvent?.id)
            }
            .animation(DayfoldMotion.standard(reduceMotion), value: model.selectedEvent != nil)
        }
        .navigationTitle(rangeTitle)
        // Each split column supplies its own backdrop under the native controls.
        // A full-width fill would cover the sidebar's translucent titlebar area.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if model.page == .calendar { dateNavigation }
            }
            ToolbarItem(placement: .principal) {
                if model.page == .calendar { viewSwitcher }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.page != .assistant {
                Button {
                    showSearch.toggle()
                    if showSearch { searchFocused = true }
                } label: { Label("Search calendars", systemImage: "magnifyingglass").font(.system(size: 14)) }
                    .controlSize(.large)
                    .help("Search calendars (⌘F)")
                Button { showStatus.toggle() } label: {
                    Label("Synchronization status", systemImage: model.isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.icloud")
                        .font(.system(size: 14))
                }.controlSize(.large).help(model.statusMessage).popover(isPresented: $showStatus) { SyncStatusView(model: model).padding(20).frame(width: 360) }
                Button { model.newDraft() } label: { Label("New event", systemImage: "square.and.pencil").font(.system(size: 14)) }
                    .controlSize(.large)
                    .help("New event (⌘N)")
                }
            }
        }
    }
    private var rangeTitle: String {
        if model.page == .assistant { return "Assistant" }
        if model.page == .pending { return "Pending changes" }; if model.page == .invitations { return "Invitations" }
        let formatter = DateFormatter(); formatter.timeZone = model.preferences.timeZone; formatter.dateFormat = model.mode == .day ? "EEEE, d MMMM" : "MMMM yyyy"; return formatter.string(from: model.selectedDate)
    }
    private var emptyTitle: String { !model.searchText.isEmpty ? "No matching downloaded events" : !model.cachedVisibleRange ? "Events for these dates have not been downloaded" : "A little breathing room" }
    // Date navigation keeps the timeline's identity and scroll position. Only a
    // different surface is cross-faded; refreshed event geometry never animates.
    private var surfaceID: String {
        model.page != .calendar ? model.page.rawValue : !model.searchText.isEmpty ? "search" : model.mode.rawValue
    }
    @ViewBuilder private var calendarContent: some View {
        if model.page == .pending { PendingChangesView(model: model) }
        else if model.page == .invitations { AgendaView(model: model, events: model.menuEvents.filter { $0.response == "needsAction" }, emptyTitle: "No pending invitations in the downloaded range") }
        else if !model.searchText.isEmpty || model.mode == .agenda { AgendaView(model: model, events: model.visibleEvents, emptyTitle: emptyTitle) }
        else if model.mode == .month { MonthView(model: model) }
        else { TimelineView(model: model) }
    }
    private var dateNavigation: some View {
        HStack(spacing: 1) {
            Button { model.navigate(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }.help("Previous range")
            Button { model.today() } label: {
                Text("Today").font(.system(size: 13)).frame(height: 30).padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            Button { model.navigate(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }.help("Next range")
        }.buttonStyle(DayfoldPressStyle())
    }
    private var viewSwitcher: some View {
        HStack(spacing: 1) {
            ForEach(CalendarViewMode.allCases) { mode in
                Button { model.mode = mode; model.dateChanged() } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: model.mode == mode ? .medium : .regular))
                        .foregroundStyle(model.mode == mode ? Color.primary : Color.secondary)
                        .padding(.horizontal, 13).frame(height: 30)
                        .background {
                            if model.mode == mode {
                                Capsule().fill(Color.primary.opacity(0.075))
                                    .matchedGeometryEffect(id: "selected-mode", in: modeSelection)
                            }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(DayfoldPressStyle()).accessibilityLabel(mode.rawValue).accessibilityIdentifier("calendar-view-" + mode.rawValue.lowercased()).accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
            }
        }.padding(.horizontal, 2).fixedSize().animation(DayfoldMotion.standard(reduceMotion), value: model.mode)
    }
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search downloaded events", text: $model.searchText)
                .textFieldStyle(.plain).focused($searchFocused)
                .onExitCommand { model.searchText = ""; showSearch = false }
            Button { model.searchText = ""; showSearch = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close search")
        }.font(.system(size: 12)).padding(.horizontal, 16).frame(height: 36)
            .background(.primary.opacity(0.025))
    }
    private var rangeDetail: String {
        if model.page == .pending { return "Drafts, unsent changes, and anything that needs a review" }
        if model.page == .invitations { return "Your invitations across all connected calendars" }
        let zone = model.preferences.timeZone.identifier.components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ") ?? "Local time"
        if model.mode == .week {
            let start = model.visibleRange.start
            let end = model.calendar.date(byAdding: .day, value: 6, to: start)!
            let style = Date.FormatStyle(timeZone: model.preferences.timeZone).day().month(.abbreviated)
            return "\(start.formatted(style)) – \(end.formatted(style))  ·  \(zone)"
        }
        return zone + "  ·  " + (model.preferences.timeZone.abbreviation() ?? "")
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
