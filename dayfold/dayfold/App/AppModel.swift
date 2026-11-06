import AppKit
import SwiftUI
import Observation
import CalendarCore
import CalendarPlatform
import OSLog
import Combine

enum CalendarViewMode: String, CaseIterable, Identifiable { case day = "Day", week = "Week", month = "Month", agenda = "Agenda"; var id: String { rawValue } }
enum SidebarPage: String { case calendar, invitations, pending }

@MainActor @Observable final class AppModel {
    var accounts: [CalendarAccount] = []
    var calendars: [CalendarSource] = []
    var events: [CalendarEvent] = []
    var menuEvents: [CalendarEvent] = []
    var companionEvents: [CalendarEvent] = []
    var menuDate = Date()
    var companionCovered = false
    var pending: [Mutation] = []
    var recentChanges: [Mutation] = []
    var reversalRequest: Mutation?
    var queuedRedo: Mutation?
    var drafts: [EventDraft] = []
    var conflicts: [EventConflict] = []
    var coverage: [CacheCoverage] = []
    var preferences = Preferences()
    var selectedDate = Date()
    var mode: CalendarViewMode = .week
    var page: SidebarPage = .calendar
    var selectedEvent: CalendarEvent?
    var editingDraft: EventDraft?
    var quickText = ""
    var searchText = ""
    var searchIDs: Set<String> = []
    var searchAccount: String = "all"
    var searchCalendar: String = "all"
    var invitationsOnly = false
    var isDemo = false
    var demoOffline = false
    var isLoading = true
    var isRefreshing = false
    var isConnecting = false
    var isSleeping = false
    var showAccountSetup = false
    var errorMessage: String?
    var fatalMessage: String?
    var preservedDirectory: URL?
    var statusMessage = "Opening your calendar…"
    var now = Date()
    var notificationPermission = "Not requested"
    var loginStatus = PlatformServices.loginStatus
    var openCalendar: (() -> Void)?
    var openQuickEntry: (() -> Void)?
    @ObservationIgnored var repository: CalendarRepository?
    @ObservationIgnored var provider: (any CalendarProvider)?
    @ObservationIgnored var demoProvider: DemoProvider?
    @ObservationIgnored var sync: SyncCoordinator?
    @ObservationIgnored var dispatcher: MutationDispatcher?
    @ObservationIgnored var notifications: NotificationScheduler?
    @ObservationIgnored var ownership: ProcessOwnership?
    @ObservationIgnored var observer: Task<Void, Never>?
    @ObservationIgnored var poller: Task<Void, Never>?
    @ObservationIgnored var prefetcher: Task<Void, Never>?
    @ObservationIgnored var minuteTimer: Task<Void, Never>?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var sessionGeneration = 0
    @ObservationIgnored var loadRevision = 0
    @ObservationIgnored var refreshRequested = false
    @ObservationIgnored var unsavedDrafts: [String: EventDraft] = [:]
    @ObservationIgnored var lifecycleSubscriptions: Set<AnyCancellable> = []
    @ObservationIgnored var dataDirectory: URL?
    @ObservationIgnored let auth: GoogleAuthorization
    @ObservationIgnored let logger = Logger(subsystem: "mujhtech.dayfold", category: "lifecycle")

    init() {
        let config = Bundle.main.url(forResource: "OAuth", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(OAuthConfiguration.self, from: $0) } ?? OAuthConfiguration()
        auth = GoogleAuthorization(configuration: config)
        selectedDate = UserDefaults.standard.object(forKey: "selectedDate") as? Date ?? Date()
        mode = CalendarViewMode(rawValue: UserDefaults.standard.string(forKey: "calendarMode") ?? "Week") ?? .week
        let arguments = ProcessInfo.processInfo.arguments
        let demo = !arguments.contains("--real") && (arguments.contains("--demo") || UserDefaults.standard.bool(forKey: "demoMode"))
        if arguments.contains("--ui-test-id") { selectedDate = Date(); mode = .week }
        DayfoldDelegate.currentModel = self
        observeLifecycle()
        Task { await loadStore(demo: demo) }
    }
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.locale = .current; c.timeZone = preferences.timeZone
        if preferences.weekStart != 0 { c.firstWeekday = preferences.weekStart }; return c
    }
    var visibleRange: DateInterval {
        switch mode {
        case .day: return calendar.dateInterval(of: .day, for: selectedDate)!
        case .week: return calendar.dateInterval(of: .weekOfYear, for: selectedDate)!
        case .month:
            let first = calendar.dateInterval(of: .month, for: selectedDate)!.start
            let start = calendar.dateInterval(of: .weekOfYear, for: first)!.start
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 42, to: start)!)
        case .agenda: return DateInterval(start: calendar.startOfDay(for: selectedDate), end: calendar.date(byAdding: .day, value: 30, to: calendar.startOfDay(for: selectedDate))!)
        }
    }
    var visibleEvents: [CalendarEvent] {
        events.filter { event in
            guard calendars.contains(where: { $0.key == event.key.calendar && $0.visible && !$0.deleted }) else { return false }
            if !preferences.showDeclined && event.response == "declined" { return false }
            if searchAccount != "all" && event.key.calendar.account.rawValue != searchAccount { return false }
            if searchCalendar != "all" && event.key.calendar.id != searchCalendar { return false }
            if invitationsOnly && event.response != "needsAction" { return false }
            return searchText.isEmpty || searchIDs.contains(event.id) || event.title.localizedStandardContains(searchText)
        }
    }
    var nextEvent: CalendarEvent? { menuEvents.first { e in
        guard e.time?.isAllDay == false, !e.cancelled, e.response != "declined", preferences.includeTentative || !e.tentative, calendars.contains(where: { $0.key == e.key.calendar && $0.visible }) else { return false }
        return (e.time?.interval(in: preferences.timeZone).end ?? .distantPast) > now
    } }
    var menuTitle: String {
        guard preferences.menuStyle != "icon", let event = nextEvent, let start = event.time?.interval(in: preferences.timeZone).start else { return "" }
        if preferences.menuStyle == "countdown" { return start <= now ? "Now" : "\(Int(ceil(start.timeIntervalSince(now) / 60)))m" }
        return start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: preferences.timeZone))
    }
    var cachedVisibleRange: Bool { calendars.filter { $0.visible && $0.syncEnabled && !$0.deleted }.allSatisfy { source in coverage.contains { $0.calendar == source.key && $0.interval.start <= visibleRange.start && $0.interval.end >= visibleRange.end } } }
    var staleVisibleRange: Bool { calendars.filter { $0.visible && $0.syncEnabled && !$0.deleted }.contains { source in !coverage.contains { $0.calendar == source.key && !$0.stale && $0.interval.start <= visibleRange.start && $0.interval.end >= visibleRange.end } } }
    var selectedSource: CalendarSource? { calendars.first { $0.key == selectedEvent?.key.calendar } }
    func sourceLabel(_ key: CalendarKey) -> String { (accounts.first { $0.id == key.account }?.label ?? "Unavailable account") + " · " + (calendars.first { $0.key == key }?.title ?? "Unavailable calendar") }
    func capability(_ action: EventAction, event: CalendarEvent) -> Capability { EventCapabilityResolver.resolve(action, account: accounts.first { $0.id == event.key.calendar.account }, calendar: calendars.first { $0.key == event.key.calendar }, event: event) }

    func loadStore(demo: Bool) async {
        let started = Date()
        if repository != nil {
            do { try await flushLocalDrafts() }
            catch { errorMessage = "Could not switch stores until your draft is saved. " + error.localizedDescription; return }
        }
        observer?.cancel(); poller?.cancel(); prefetcher?.cancel(); minuteTimer?.cancel(); sessionGeneration += 1; let generation = sessionGeneration
        isRefreshing = false; refreshRequested = false
        queuedRedo = nil; reversalRequest = nil
        repository = nil; sync = nil; dispatcher = nil; provider = nil; notifications = nil; ownership = nil; dataDirectory = nil
        isLoading = true; fatalMessage = nil; isDemo = demo; demoOffline = false; accounts = []; calendars = []; events = []; menuEvents = []; companionEvents = []; pending = []; recentChanges = []; drafts = []; conflicts = []; coverage = []; selectedEvent = nil; editingDraft = nil
        do {
            let args = ProcessInfo.processInfo.arguments
            let base: URL
            if let i = args.firstIndex(of: "--ui-test-id"), args.indices.contains(i + 1) { base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DayfoldUITests/" + args[i + 1], isDirectory: true) }
            else if let i = args.firstIndex(of: "--test-store"), args.indices.contains(i + 1) { base = URL(fileURLWithPath: args[i + 1], isDirectory: true) }
            else { base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dayfold", isDirectory: true) }
            let directory = base.appendingPathComponent(demo ? "Demo" : "Google", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ownership = try ProcessOwnership(path: directory.appendingPathComponent("dispatcher.lock").path); dataDirectory = directory
            let repo = try CalendarRepository(path: directory.appendingPathComponent("calendar.sqlite").path)
            repository = repo
            let chosen: any CalendarProvider
            if demo {
                let dataset = FixtureFactory.demo(now: Date())
                if try await repo.accounts().isEmpty { for account in dataset.accounts { try await repo.connect(account) } }
                let fake = try DemoProvider(dataset: dataset, file: directory.appendingPathComponent("provider.json")); demoProvider = fake; chosen = fake
            } else { demoProvider = nil; chosen = GoogleCalendarProvider(tokens: auth) }
            provider = chosen
            let gate = CalendarWorkGate(); sync = SyncCoordinator(repository: repo, provider: chosen, gate: gate); dispatcher = MutationDispatcher(repository: repo, provider: chosen, gate: gate)
            preferences = try await repo.preferences()
            if !args.contains("--ui-test-id"), let startup = CalendarViewMode(rawValue: preferences.startupView) { mode = startup }
            notifications = NotificationScheduler(repository: repo)
            notifications?.openEvent = { [weak self] key, join in self?.route(to: key, join: join) }
            PlatformServices.registerQuickEntry { [weak self] in self?.openQuickEntry?() }
            if !args.contains("--ui-test-id") { UserDefaults.standard.set(demo, forKey: "demoMode") }
            await reload()
            quickText = drafts.first { $0.id == "quick-entry-text" }?.fields.text("quickInput") ?? ""
            observer = Task { [weak self] in
                for await _ in await repo.changes() {
                    guard !Task.isCancelled, let self, generation == self.sessionGeneration else { break }; await self.reload()
                }
            }
            isLoading = false
            logger.info("store_ready demo=\(demo, privacy: .public) accounts=\(self.accounts.count, privacy: .public) duration_ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
            await refresh()
            prefetcher = Task(priority: .background) { [weak self] in
                guard let self else { return }
                var c = Calendar(identifier: .gregorian); c.timeZone = preferences.timeZone
                let first = c.dateInterval(of: .month, for: c.date(byAdding: .day, value: -90, to: Date())!)!.start
                for offset in 0..<16 {
                    guard !Task.isCancelled, generation == sessionGeneration, !isSleeping, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
                    let start = c.date(byAdding: .month, value: offset, to: first)!, end = c.date(byAdding: .month, value: offset + 1, to: first)!
                    await sync?.prefetch(window: DateInterval(start: start, end: end))
                    await Task.yield()
                }
                try? await repo.evictOccurrenceWindows(keepPerCalendar: 24, protecting: visibleRange)
            }
            minuteTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60)); guard !Task.isCancelled, let self else { return }
                    let old = now; now = Date(); if !calendar.isDate(old, inSameDayAs: now) { if calendar.isDate(menuDate, inSameDayAs: old) { menuDate = now }; await reload(); await refresh() }
                }
            }
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    let delay = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue != "com.apple.SwiftUI.Settings" } ? 60 : 300
                    try? await Task.sleep(for: .seconds(delay + Int.random(in: 0...8)))
                    guard !Task.isCancelled, let self else { return }; self.now = Date(); await self.refresh()
                }
            }
        } catch { fatalMessage = error.localizedDescription; isLoading = false; logger.error("store_open_failed recovery_required=true") }
    }
    func reload() async {
        guard let repository else { return }
        let generation = sessionGeneration
        loadRevision += 1; let requestedRevision = loadRevision
        do {
            let snapshot = try await repository.snapshot(interval: visibleRange, displayZone: preferences.timeZone)
            let today = calendar.startOfDay(for: Date()), end = calendar.date(byAdding: .day, value: 30, to: today)!
            let menu = try await repository.snapshot(interval: DateInterval(start: today, end: end), displayZone: preferences.timeZone)
            guard generation == sessionGeneration, requestedRevision == loadRevision else { return }
            accounts = snapshot.accounts; calendars = snapshot.calendars; events = snapshot.events; menuEvents = menu.events; pending = snapshot.mutations; drafts = snapshot.drafts; conflicts = snapshot.conflicts; coverage = snapshot.coverage
            recentChanges = snapshot.recentChanges
            if let editing = editingDraft, let original = editing.source {
                let source = calendars.first { $0.key == original.key.calendar }
                if source == nil || source?.deleted == true || source?.readable == false || (source?.role == "writerWithoutPrivateAccess" && original.raw.text("visibility") == "private") {
                    try await repository.saveDraft(unsavedDrafts[editing.id] ?? editing)
                    unsavedDrafts[editing.id] = nil; editingDraft = nil
                    errorMessage = "Access to this calendar changed. Your changed fields remain saved as a recovery draft."
                }
            }
            await loadCompanionDay(fetch: false)
            if let current = selectedEvent {
                if let updated = snapshot.events.first(where: { $0.id == current.id }) { selectedEvent = updated }
                else { selectedEvent = try await repository.event(current.key) }
            }
            statusMessage = demoOffline ? "Demo · Offline" : isDemo ? "Demo · Stored on this Mac" : accounts.isEmpty ? "Connect a Google account to get started" : accounts.contains { $0.status != .healthy } ? "Some calendars need attention" : "Up to date"
            if preferences.defaultCalendar == nil, let first = calendars.first(where: { $0.primary && $0.writable && $0.syncEnabled }) { preferences.defaultCalendar = first.key; try await repository.setPreferences(preferences) }
            notifications?.snoozeMinutes = preferences.snoozeMinutes
            if !isDemo {
                let notificationStart = calendar.date(byAdding: .day, value: -1, to: today)!
                let notificationSnapshot = try await repository.snapshot(interval: DateInterval(start: notificationStart, end: end), displayZone: preferences.timeZone)
                guard generation == sessionGeneration, requestedRevision == loadRevision else { return }
                let desired = ReminderPlanner.plan(events: notificationSnapshot.events, calendars: calendars, preferences: preferences, now: Date())
                let valid = ReminderPlanner.plan(events: notificationSnapshot.events, calendars: calendars, preferences: preferences, now: Date(), capacity: 2000, includeRecentPast: true)
                try await notifications?.reconcile(desired, validReminders: valid)
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func refresh() async {
        refreshRequested = true
        guard !isRefreshing, !isSleeping, let sync, let dispatcher else { return }
        let generation = sessionGeneration
        isRefreshing = true; defer { if generation == sessionGeneration { isRefreshing = false } }
        repeat {
            refreshRequested = false
            let currentRange = visibleRange
            await dispatcher.drain()
            guard generation == sessionGeneration, !isSleeping else { return }
            await sync.refresh(window: currentRange)
            let today = calendar.startOfDay(for: Date()), end = calendar.date(byAdding: .day, value: 30, to: today)!
            let upcoming = DateInterval(start: today, end: end)
            if upcoming != currentRange { await sync.refresh(window: upcoming) }
            guard generation == sessionGeneration else { return }
            await reload()
        } while refreshRequested && !isSleeping
    }
    func loadCompanionDay(fetch: Bool) async {
        let range = calendar.dateInterval(of: .day, for: menuDate)!
        if fetch { await sync?.refresh(window: range) }
        do {
            guard let snapshot = try await repository?.snapshot(interval: range, displayZone: preferences.timeZone) else { return }
            companionEvents = snapshot.events
            companionCovered = snapshot.calendars.filter { $0.visible && $0.syncEnabled && !$0.deleted }.allSatisfy { source in snapshot.coverage.contains { $0.calendar == source.key && $0.interval.start <= range.start && $0.interval.end >= range.end } }
        } catch { errorMessage = error.localizedDescription }
    }
    func navigate(_ direction: Int) {
        let component: Calendar.Component = mode == .day ? .day : mode == .week ? .weekOfYear : .month
        selectedDate = calendar.date(byAdding: component, value: direction, to: selectedDate) ?? selectedDate
        dateChanged()
    }
    func today() { selectedDate = Date(); dateChanged() }
    func dateChanged() {
        UserDefaults.standard.set(selectedDate, forKey: "selectedDate"); UserDefaults.standard.set(mode.rawValue, forKey: "calendarMode")
        Task { await reload(); await refresh() }
    }
    func savePreferences() { Task { do { try await repository?.setPreferences(preferences); await reload() } catch { errorMessage = error.localizedDescription } } }
    func setVisibility(_ source: CalendarSource, _ visible: Bool) { Task { do { try await repository?.setCalendarChoices(source.key, visible: visible) } catch { errorMessage = error.localizedDescription } } }
    func setVisibilitySet(_ name: String) {
        let ids = preferences.savedSets[name]
        Task { for source in calendars { do { try await repository?.setCalendarChoices(source.key, visible: ids == nil || ids!.contains(source.id)) } catch { errorMessage = error.localizedDescription } } }
    }
    func searchChanged() {
        searchTask?.cancel(); let query = searchText
        searchTask = Task { try? await Task.sleep(for: .milliseconds(180)); guard !Task.isCancelled else { return }; do { let ids = try await repository?.search(query) ?? []; guard query == searchText else { return }; searchIDs = ids } catch { errorMessage = "Search could not complete." } }
    }
}
