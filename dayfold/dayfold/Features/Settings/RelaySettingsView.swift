import SwiftUI
import CalendarCore
import CalendarPlatform

struct RelaySettingsView: View {
    @Bindable var model: AppModel
    @State private var origin = ""
    @State private var deviceID = ""
    @State private var token = ""
    @State private var reminders = false
    @State private var disconnecting = false
    @State private var changingReminders = false
    @State private var pendingReminderChoice: Bool?
    @State private var managingDevices = false
    @State private var confirmAll = false
    @State private var confirmDelete = false
    @State private var revokeTarget: RelayAccountDevice?

    private var busy: Bool { model.isLoading || model.relayConnecting || disconnecting || changingReminders || managingDevices }
    private var canConnect: Bool {
        !model.isDemo && !busy && !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            if model.isDemo {
                Section {
                    Label("Demo store", systemImage: "sparkle")
                    Text("Switch to Google accounts in Accounts to connect real-time updates. The demo store uses sample data.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let configuration = model.relayConfiguration {
                Section("Dayfold account") {
                    LabeledContent("Service") {
                        Text(configuration.origin.absoluteString).textSelection(.enabled)
                    }
                    if model.relayAccountIdentity != nil {
                        Label("This Mac is signed in", systemImage: "person.crop.circle.badge.checkmark")
                    } else { LabeledContent("Development installation") {
                        Text(configuration.deviceID.uuidString.lowercased())
                            .font(.caption.monospaced()).textSelection(.enabled)
                    } }
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: model.relayConnected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(model.relayConnected ? Color.green : Color.secondary)
                        Text(model.relayStatus).fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.relayConnected, model.relayAccountIdentity != nil {
                        if !model.relayIdentityProvider.isEmpty { LabeledContent("Sign-in provider", value: model.relayIdentityProvider) }
                        Button("Sign in again") { signIn(reconnecting: true) }.disabled(busy)
                    }
                    Button(disconnecting ? "Signing out…" : "Sign out of this Mac", role: .destructive) {
                        disconnect()
                    }
                    .disabled(busy || model.isDemo)
                    .accessibilityIdentifier("relay-disconnect")
                }
                if model.relayAccountIdentity != nil { devicesSection }
                Section("Reminders") {
                    Toggle("Use push for reminders", isOn: Binding(
                        get: { pendingReminderChoice ?? model.relayConfiguration?.reminders ?? false },
                        set: setReminders
                    ))
                    .disabled(busy || model.isDemo)
                    .accessibilityIdentifier("relay-reminders")
                    if !model.relayAPNSStatus.isEmpty {
                        Text(model.relayAPNSStatus).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Local reminders stay active until push reminders are ready. Delivery depends on macOS notification settings, Focus, and connectivity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Sign in to Dayfold") {
                    TextField("Service address", text: $origin, prompt: Text("https://relay.example.com"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("relay-origin")
                    Text("Enter the service address provided by your Dayfold operator. Sign-in opens in your browser and is separate from Google Calendar access.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.relayIdentityProvider.isEmpty {
                        LabeledContent("Sign-in provider", value: model.relayIdentityProvider)
                    }
                    if model.relayAccountIdentity != nil {
                        Button("Sign out of saved Dayfold account", role: .destructive) { disconnect() }.disabled(busy)
                    }
                    Toggle("Use push for reminders", isOn: $reminders)
                        .accessibilityIdentifier("relay-reminders")
                    HStack(spacing: 8) {
                        Button(model.relayConnecting ? "Connecting…" : (model.relayAuthConfiguration == nil ? "Continue" : "Sign in to Dayfold")) { signIn() }
                            .disabled(busy || origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("relay-connect")
                        if model.relayConnecting { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(busy || model.isDemo)
                if model.allowsLocalRelay {
                    Section("Development connection") {
                        Text("Manual tokens are available only for an explicitly enabled local development relay.").font(.caption).foregroundStyle(.secondary)
                        TextField("Installation ID", text: $deviceID).accessibilityIdentifier("relay-installation")
                        SecureField("Installation token", text: $token).accessibilityIdentifier("relay-token")
                        Button("Connect local relay") { connect() }.disabled(!canConnect)
                    }
                }
                if !model.relayStatus.isEmpty, model.relayStatus != "Not connected" {
                    Section { Text(model.relayStatus).font(.caption).foregroundStyle(.secondary) }
                }
                if !model.relayAPNSStatus.isEmpty {
                    Section("Push notifications") {
                        Text(model.relayAPNSStatus).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("Privacy") {
                Text("Dayfold stores your account and device registrations, routing IDs, and reminder times. Event details stay in Google and on this Mac. Session credentials and Google sign-in credentials stay in this Mac’s Keychain.")
                    .font(.callout)
                Text("Live updates help Dayfold notice calendar changes while it is open. Calendar access and local reminders remain available when the relay is disconnected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            if let saved = UserDefaults.standard.string(forKey: "dayfoldAccountService"),
               let url = URL(string: saved),
               let normalized = try? RelayEndpoint.validatedOrigin(url, allowLoopbackHTTP: model.allowsLocalRelay) {
                origin = normalized.absoluteString
            } else { UserDefaults.standard.removeObject(forKey: "dayfoldAccountService") }
        }
        .onDisappear { token = "" }
        .onChange(of: model.isDemo) { token = "" }
        .onChange(of: origin) { model.relayAuthConfiguration = nil; model.relayIdentityProvider = "" }
        .confirmationDialog("Sign out of all Dayfold devices?", isPresented: $confirmAll) {
            Button("Sign out of all devices", role: .destructive) { manage { try await model.revokeAllDayfoldDevices() } }
        } message: { Text("Real-time updates stop on every device. Your Google calendars remain connected locally.") }
        .confirmationDialog("Delete your Dayfold account?", isPresented: $confirmDelete) {
            Button("Delete Dayfold account", role: .destructive) { manage { try await model.revokeAllDayfoldDevices(deleteAccount: true) } }
        } message: { Text("This removes your Dayfold account and its device registrations. It does not delete events in Google Calendar.") }
        .confirmationDialog("Sign out this device?", isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } })) {
            if let device = revokeTarget {
                Button("Sign out \(device.deviceName)", role: .destructive) { manage { try await model.revokeDayfoldDevice(device.id) } }
            }
        }
    }

    private var devicesSection: some View {
        Section("Devices") {
            ForEach(model.relayAccountDevices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.deviceName)
                        if device.id == model.relayAccountIdentity?.deviceID { Text("This Mac").font(.caption).foregroundStyle(.secondary) }
                        else if let seen = device.lastSeenAt { Text("Last active \(seen.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Sign out", role: .destructive) { revokeTarget = device }.disabled(busy)
                }
            }
            Button("Refresh devices") { manage { try await model.refreshDayfoldDevices() } }.disabled(busy)
            Button("Sign out of all devices", role: .destructive) { confirmAll = true }.disabled(busy)
            Button("Delete Dayfold account", role: .destructive) { confirmDelete = true }.disabled(busy)
        }
    }

    private func signIn(reconnecting: Bool = false) {
        guard !busy else { return }
        Task {
            do {
                if model.relayAuthConfiguration == nil {
                    try await model.prepareDayfoldSignIn(origin: reconnecting ? model.relayConfiguration?.origin.absoluteString ?? origin : origin)
                } else { try await model.signInDayfold(reminders: reconnecting ? model.relayConfiguration?.reminders ?? reminders : reminders, reconnecting: reconnecting) }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func manage(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        managingDevices = true
        Task {
            defer { managingDevices = false }
            do { try await action() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func connect() {
        guard canConnect else { return }
        let address = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let installation = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await model.connectRelay(origin: address, deviceID: installation, token: secret, reminders: reminders)
                token = ""
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        guard !busy else { return }
        disconnecting = true
        Task {
            defer { disconnecting = false }
            do {
                try await model.disconnectRelay()
                token = ""
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func setReminders(_ enabled: Bool) {
        guard !busy else { return }
        pendingReminderChoice = enabled
        changingReminders = true
        Task {
            defer { changingReminders = false; pendingReminderChoice = nil }
            do {
                try await model.setRelayReminders(enabled)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
