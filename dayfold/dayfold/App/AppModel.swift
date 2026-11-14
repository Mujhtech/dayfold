import AppKit
import SwiftUI
import Observation
import CalendarCore
import CalendarPlatform
import UserNotifications
import OSLog
import Combine

enum CalendarViewMode: String, CaseIterable, Identifiable { case day = "Day", week = "Week", month = "Month", agenda = "Agenda"; var id: String { rawValue } }
enum SidebarPage: String { case calendar, assistant, invitations, pending }

@MainActor @Observable final class AppModel {
    struct CompanionLoadFailure {
        var range: DateInterval
        var zone: TimeZone
        var message: String
    }

    var accounts: [CalendarAccount] = []
    var calendars: [CalendarSource] = []
    var events: [CalendarEvent] = []
    var menuEvents: [CalendarEvent] = []
    var companionEvents: [CalendarEvent] = []
    var menuDate = Date()
    var companionCovered = false
    var companionLoadedRange: DateInterval?
    var companionLoadedZone: TimeZone?
    var companionLoadFailure: CompanionLoadFailure?
    var pending: [Mutation] = []
    var recentChanges: [Mutation] = []
    var reversalRequest: Mutation?
    var queuedRedo: Mutation?
    var drafts: [EventDraft] = []
    var conflicts: [EventConflict] = []
    var coverage: [CacheCoverage] = []
    var preferences = Preferences() {
        didSet {
            if oldValue.appearance != preferences.appearance { applyAppearance() }
            if oldValue.assistantModel != preferences.assistantModel {
                let composedRequest = assistantInput
                resetAssistant()
                assistantInput = composedRequest
            }
            if oldValue.experienceMode != preferences.experienceMode, !isLoading {
                if preferences.experienceMode == .calendar { resetAssistant() }
                if !isShowingOnboarding { page = preferredPage }
            }
        }
    }
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
    var onboardingStep: OnboardingStep?
    var isSavingCalendarSelection = false
    var assistantInput = ""
    var assistantQuestion = ""
    var assistantAnswer = ""
    var assistantProposal: AssistantEventProposal?
    var assistantProposalZone: TimeZone?
    var assistantDraftID: String?
    var assistantDraftStatus: String?
    var assistantPreviewDate = Date()
    var assistantError: String?
    var assistantIsWorking = false
    var assistantIsStopping = false
    var assistantIsOpeningDraft = false
    var assistantActivity: [String] = []
    var assistantAvailability: AssistantAvailabilityStatus?
    var assistantKeyPresent = false
    var assistantConfigurationBusy = false
    var assistantConfigurationMessage: String?
    @ObservationIgnored var assistantTask: Task<Void, Never>?
    @ObservationIgnored var assistantService: CloudCalendarAssistant?
    @ObservationIgnored var assistantCredentialStore: AssistantCredentialStore?
    @ObservationIgnored var assistantRequestID = UUID()
    var errorMessage: String?
    var fatalMessage: String?
    var preservedDirectory: URL?
    var statusMessage = "Opening your calendar…"
    var now = Date()
    var notificationPermission = "Not requested"
    var loginStatus = PlatformServices.loginStatus
    var relayConfiguration: RelayConfiguration?
    var relayStatus = "Not connected"
    var relayConnected = false
    var relayAPNSStatus = "Push notifications are not configured"
    var relayConnecting = false
    var relayAccountIdentity: RelayAccountIdentity?
    var relayIdentityProvider = ""
    var relayAccountDevices: [RelayAccountDevice] = []
    var relayAuthConfiguration: RelayOIDCConfiguration?
    var openCalendar: (() -> Void)?
    var openQuickEntry: (() -> Void)?
    @ObservationIgnored var repository: CalendarRepository?
    @ObservationIgnored var provider: (any CalendarProvider)?
    @ObservationIgnored var demoProvider: DemoProvider?
    @ObservationIgnored var sync: SyncCoordinator?
    @ObservationIgnored var dispatcher: MutationDispatcher?
    @ObservationIgnored var notifications: NotificationScheduler?
    @ObservationIgnored var relay: RelayCoordinator?
    @ObservationIgnored var relayCredentialStore: RelayCredentialStore?
    @ObservationIgnored var relayAccountSession: RelayAccountSession?
    @ObservationIgnored var relayAccountSignIn: DayfoldAccountAuthorization?
    @ObservationIgnored var relayOwnedReminderIDs: Set<String> = []
    @ObservationIgnored var lastRelayInput: RelayReconciliation?
    @ObservationIgnored var relayRestoreTask: Task<Void, Never>?
    @ObservationIgnored var relayRestoring = false
    @ObservationIgnored var relayConnectionID = UUID()
    @ObservationIgnored var apnsToken: Data?
    @ObservationIgnored var relayPushHints: Set<UUID> = []
    @ObservationIgnored var relayPendingTaps: [(RemotePushPayload, String)] = []
    @ObservationIgnored var ownership: ProcessOwnership?
    @ObservationIgnored var observer: Task<Void, Never>?
    @ObservationIgnored var poller: Task<Void, Never>?
    @ObservationIgnored var prefetcher: Task<Void, Never>?
    @ObservationIgnored var minuteTimer: Task<Void, Never>?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored var sessionGeneration = 0
    @ObservationIgnored var loadRevision = 0
    @ObservationIgnored var companionLoadRevision = 0
    @ObservationIgnored var refreshRequested = false
    @ObservationIgnored var unsavedDrafts: [String: EventDraft] = [:]
    @ObservationIgnored var lifecycleSubscriptions: Set<AnyCancellable> = []
    @ObservationIgnored var dataDirectory: URL?
    @ObservationIgnored var auth: GoogleAuthorization
    @ObservationIgnored let oauthConfiguration: OAuthConfiguration
    @ObservationIgnored let logger = Logger(subsystem: "mujhtech.dayfold", category: "lifecycle")

    init() {
        let config = Bundle.main.url(forResource: "OAuth", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(OAuthConfiguration.self, from: $0) } ?? OAuthConfiguration()
        oauthConfiguration = config
        auth = GoogleAuthorization(configuration: config, namespace: "unopened")
        selectedDate = UserDefaults.standard.object(forKey: "selectedDate") as? Date ?? Date()
        mode = CalendarViewMode(rawValue: UserDefaults.standard.string(forKey: "calendarMode") ?? "Week") ?? .week
        let arguments = ProcessInfo.processInfo.arguments
        let demo = !arguments.contains("--real") && (arguments.contains("--demo") || UserDefaults.standard.bool(forKey: "demoMode"))
        if arguments.contains("--ui-test-id") { selectedDate = Date(); mode = .week }
        DayfoldDelegate.currentModel = self
        applyAppearance()
        observeLifecycle()
        Task { await loadStore(demo: demo) }
    }

    /// Native panels follow this application override; SwiftUI presentations also
    /// receive the same preference through DayfoldAppearance at each scene root.
    private func applyAppearance() {
        PlatformServices.setAppearance(preferences.appearance)
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
        guard preferences.menuStyle != "icon" else { return "" }
        // Keep text styles visible while loading or without an eligible meeting.
        // Missing cached events do not necessarily mean the calendar is empty.
        guard let event = nextEvent, let start = event.time?.interval(in: preferences.timeZone).start else { return "Dayfold" }
        if preferences.menuStyle == "countdown" { return start <= now ? "Now" : "\(Int(ceil(start.timeIntervalSince(now) / 60)))m" }
        return start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: preferences.timeZone))
    }
    var companionDayIsLoaded: Bool {
        companionLoadedRange == calendar.dateInterval(of: .day, for: menuDate)
            && companionLoadedZone == preferences.timeZone
    }
    var companionDayError: String? {
        guard let failure = companionLoadFailure,
              failure.range == calendar.dateInterval(of: .day, for: menuDate),
              failure.zone == preferences.timeZone else { return nil }
        return failure.message
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
        sessionGeneration += 1; let generation = sessionGeneration
        resetAssistant()
        isLoading = true
        let previousAssistantStore = assistantCredentialStore
        assistantCredentialStore = nil; assistantKeyPresent = false; assistantAvailability = nil
        assistantConfigurationBusy = false; assistantConfigurationMessage = nil
        await previousAssistantStore?.invalidate()
        guard generation == sessionGeneration else { return }
        let previousVault = relayCredentialStore
        relayAccountSignIn?.cancel()
        await relayAccountSession?.invalidate()
        auth.cancel()
        await auth.cancelPendingRequests()
        await previousVault?.invalidate()
        guard generation == sessionGeneration else { return }
        relayCredentialStore = nil
        relayAccountSession = nil; relayAccountSignIn = nil
        relayAccountIdentity = nil; relayIdentityProvider = ""; relayAccountDevices = []; relayAuthConfiguration = nil
        relayConnectionID = UUID(); relayRestoring = false
        relayRestoreTask?.cancel(); await relay?.stop()
        guard generation == sessionGeneration else { return }
        relay = nil; relayConnecting = false
        relayConfiguration = nil; relayStatus = "Not connected"; relayConnected = false; relayOwnedReminderIDs = []; lastRelayInput = nil
        observer?.cancel(); poller?.cancel(); prefetcher?.cancel(); minuteTimer?.cancel()
        isRefreshing = false; refreshRequested = false
        onboardingStep = nil; showAccountSetup = false; isSavingCalendarSelection = false
        queuedRedo = nil; reversalRequest = nil
        repository = nil; sync = nil; dispatcher = nil; provider = nil; notifications = nil; ownership = nil; dataDirectory = nil
        isLoading = true; fatalMessage = nil; isDemo = demo; demoOffline = false; accounts = []; calendars = []; events = []; menuEvents = []; companionEvents = []; pending = []; recentChanges = []; drafts = []; conflicts = []; coverage = []; selectedEvent = nil; editingDraft = nil
        companionCovered = false; companionLoadedRange = nil; companionLoadedZone = nil; companionLoadFailure = nil
        do {
            let args = ProcessInfo.processInfo.arguments
            let base: URL
            if let i = args.firstIndex(of: "--ui-test-id"), args.indices.contains(i + 1) { base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DayfoldUITests/" + args[i + 1], isDirectory: true) }
            else if let i = args.firstIndex(of: "--test-store"), args.indices.contains(i + 1) { base = URL(fileURLWithPath: args[i + 1], isDirectory: true) }
            else { base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dayfold", isDirectory: true) }
            let directory = base.appendingPathComponent(demo ? "Demo" : "Google", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let legacyCredentialsAllowed = !demo && !args.contains("--test-store") && !args.contains("--ui-test-id")
            auth = GoogleAuthorization(configuration: oauthConfiguration, namespace: directory.path, allowLegacyMigration: legacyCredentialsAllowed)
            ownership = try ProcessOwnership(path: directory.appendingPathComponent("dispatcher.lock").path); dataDirectory = directory
            assistantCredentialStore = AssistantCredentialStore(namespace: directory.path)
            let repo = try CalendarRepository(path: directory.appendingPathComponent("calendar.sqlite").path)
            repository = repo
            let savedRelay = try await repo.relayState()
            relayConfiguration = savedRelay.configuration
            relayOwnedReminderIDs = savedRelay.remoteOwnedIDs
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
            configureRelayNotificationHandlers()
            PlatformServices.registerQuickEntry { [weak self] in self?.openQuickEntry?() }
            if !args.contains("--ui-test-id") { UserDefaults.standard.set(demo, forKey: "demoMode") }
            await reload()
            onboardingStep = accounts.isEmpty ? .welcome : preferences.onboardingStep.flatMap(OnboardingStep.init(rawValue:))
            page = preferredPage
            relayRestoreTask = Task { [weak self] in await self?.restoreRelay(generation: generation) }
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
        let requestedRange = visibleRange, requestedZone = preferences.timeZone, requestedCalendar = calendar
        loadRevision += 1; let requestedRevision = loadRevision
        func requestIsCurrent() -> Bool {
            !Task.isCancelled && generation == sessionGeneration && requestedRevision == loadRevision
                && requestedRange == visibleRange && requestedZone == preferences.timeZone
        }
        do {
            let snapshot = try await repository.snapshot(interval: requestedRange, displayZone: requestedZone)
            let today = requestedCalendar.startOfDay(for: Date()), end = requestedCalendar.date(byAdding: .day, value: 30, to: today)!
            let menu = try await repository.snapshot(interval: DateInterval(start: today, end: end), displayZone: requestedZone)
            guard requestIsCurrent() else { return }
            if !accounts.isEmpty, Set(accounts.map(\.id)) != Set(snapshot.accounts.map(\.id)) { resetAssistant() }
            accounts = snapshot.accounts; calendars = snapshot.calendars; events = snapshot.events; menuEvents = menu.events; pending = snapshot.mutations; drafts = snapshot.drafts; conflicts = snapshot.conflicts; coverage = snapshot.coverage
            recentChanges = snapshot.recentChanges
            if let editing = editingDraft, let original = editing.source {
                let source = calendars.first { $0.key == original.key.calendar }
                if source == nil || source?.deleted == true || source?.readable == false || (source?.role == "writerWithoutPrivateAccess" && original.raw.text("visibility") == "private") {
                    try await repository.saveDraft(unsavedDrafts[editing.id] ?? editing)
                    guard requestIsCurrent() else { return }
                    unsavedDrafts[editing.id] = nil
                    if editingDraft?.id == editing.id {
                        editingDraft = nil
                        errorMessage = "Access to this calendar changed. Your changed fields remain saved as a recovery draft."
                    }
                }
            }
            await loadCompanionDay(fetch: false)
            guard requestIsCurrent() else { return }
            if let current = selectedEvent {
                if let updated = snapshot.events.first(where: { $0.id == current.id }) { selectedEvent = updated }
                else {
                    let updated = try await repository.event(current.key)
                    guard requestIsCurrent() else { return }
                    if selectedEvent?.key == current.key { selectedEvent = updated }
                }
            }
            statusMessage = demoOffline ? "Demo · Offline" : isDemo ? "Demo · Stored on this Mac" : accounts.isEmpty ? "Connect a Google account to get started" : accounts.contains { $0.status != .healthy } ? "Some calendars need attention" : "Up to date"
            if preferences.defaultCalendar == nil, let first = calendars.first(where: { $0.primary && $0.writable && $0.syncEnabled }) { preferences.defaultCalendar = first.key; try await repository.setPreferences(preferences) }
            guard requestIsCurrent() else { return }
            notifications?.snoozeMinutes = preferences.snoozeMinutes
            if !isDemo {
                let notificationStart = calendar.date(byAdding: .day, value: -1, to: today)!
                let notificationSnapshot = try await repository.snapshot(interval: DateInterval(start: notificationStart, end: end), displayZone: preferences.timeZone)
                guard requestIsCurrent() else { return }
                let desired = ReminderPlanner.plan(events: notificationSnapshot.events, calendars: calendars, preferences: preferences, now: Date())
                let valid = ReminderPlanner.plan(events: notificationSnapshot.events, calendars: calendars, preferences: preferences, now: Date(), capacity: 2000, includeRecentPast: true)
                let scheduler = notifications
                let coordinator = relay
                let connectionID = relayConnectionID
                let authorization = await scheduler?.permission()
                guard requestIsCurrent(), connectionID == relayConnectionID else { return }
                let relayInput = RelayReconciliation(accounts: accounts, calendars: calendars, desired: desired, valid: valid,
                    remindersEnabled: preferences.notifications, notificationAuthorization: authorization == .authorized || authorization == .provisional)
                lastRelayInput = relayInput
                await coordinator?.update(relayInput)
                guard requestIsCurrent(), connectionID == relayConnectionID else { return }
                try await scheduler?.reconcile(desired, validReminders: valid, remoteOwnedIDs: relayOwnedReminderIDs)
            }
        } catch { if requestIsCurrent() { errorMessage = error.localizedDescription } }
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
        guard let repository else { return }
        let generation = sessionGeneration, requestedZone = preferences.timeZone
        let range = calendar.dateInterval(of: .day, for: menuDate)!
        companionLoadRevision += 1; let requestedRevision = companionLoadRevision
        companionLoadFailure = nil
        func requestIsCurrent() -> Bool {
            !Task.isCancelled && generation == sessionGeneration && requestedRevision == companionLoadRevision
                && requestedZone == preferences.timeZone && range == calendar.dateInterval(of: .day, for: menuDate)
        }
        if fetch { await sync?.refresh(window: range) }
        guard requestIsCurrent() else { return }
        do {
            let snapshot = try await repository.snapshot(interval: range, displayZone: requestedZone)
            guard requestIsCurrent() else { return }
            companionEvents = snapshot.events
            companionCovered = snapshot.calendars.filter { $0.visible && $0.syncEnabled && !$0.deleted }.allSatisfy { source in snapshot.coverage.contains { $0.calendar == source.key && $0.interval.start <= range.start && $0.interval.end >= range.end } }
            companionLoadedRange = range; companionLoadedZone = requestedZone
        } catch {
            if requestIsCurrent() {
                companionLoadFailure = CompanionLoadFailure(range: range, zone: requestedZone, message: error.localizedDescription)
            }
        }
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
