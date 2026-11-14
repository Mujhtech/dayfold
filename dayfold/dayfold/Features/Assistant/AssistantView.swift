import SwiftUI
import AppKit
import CalendarCore
import CalendarPlatform

struct AssistantView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @State private var showingConnection = false

    private var hasRequest: Bool { !model.assistantQuestion.isEmpty }
    private var busy: Bool { model.assistantIsWorking || model.assistantIsOpeningDraft }
    private var available: Bool { model.assistantKeyPresent && model.assistantAvailability?.available == true }
    private var canSend: Bool {
        available && !busy && !model.assistantConfigurationBusy &&
        !model.assistantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.assistantInput.count <= 1_800
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceBar
            Divider()
            HStack(spacing: 0) {
                workspace
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                AssistantDayPreview(model: model)
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                    .background(Color.primary.opacity(0.018))
            }
        }
        .scrollIndicators(.never)
        .task { await model.refreshAssistantConnection() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.refreshAssistantConnection() } }
        }
        .sheet(isPresented: $showingConnection, onDismiss: { inputFocused = true }) {
            connectionSheet
                .modifier(DayfoldAppearance(preference: model.preferences.appearance))
                .modifier(DayfoldMotionEnvironment())
        }
    }

    private var workspaceBar: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().interpolation(.high).frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Dayfold").font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("Assistant").font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            Spacer()
            if hasRequest {
                Button {
                    model.resetAssistant()
                    inputFocused = true
                } label: {
                    Label("New request", systemImage: "square.and.pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(busy)
                .padding(.trailing, 12)
            }
            Button { showingConnection = true } label: {
                HStack(spacing: 6) {
                    if model.assistantConfigurationBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(model.assistantKeyPresent ? Color.dayfoldAccent : Color.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                    }
                    Text(model.assistantKeyPresent ? "OpenAI" : "Connect OpenAI")
                        .font(.system(size: 11))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("OpenAI connection settings")
            .accessibilityLabel(model.assistantKeyPresent ? "OpenAI API key saved. Connection settings" : "Connect OpenAI")
            Divider().frame(height: 16).padding(.horizontal, 8)
            Button { model.page = .calendar } label: {
                Label("Calendar", systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .help("Open your full calendar")
        }
        .padding(.horizontal, 26).frame(height: 64)
    }

    @ViewBuilder private var workspace: some View {
        if hasRequest {
            VStack(spacing: 0) {
                ScrollView {
                    requestResult
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 30)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                composer(expanded: false)
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 40).padding(.top, 12).padding(.bottom, 26)
            }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 30)
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What’s the plan?")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .accessibilityAddTraits(.isHeader)
                        Text("Ask about your day, or make room for something new.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    composer(expanded: true)
                    examples
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 44)
                Spacer(minLength: 60)
            }
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 13) {
            example("See what’s on today", symbol: "sun.max", prompt: "What’s on my calendar today?")
            example("Find an hour to focus", symbol: "clock", prompt: "Find an hour for focus tomorrow.")
            example("Put a plan on the calendar", symbol: "plus", prompt: "Prepare lunch tomorrow at 1pm for 45 minutes.")
        }
    }

    private func example(_ title: String, symbol: String, prompt: String) -> some View {
        Button {
            model.assistantInput = prompt
            inputFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(Color.dayfoldAccent)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Fill the request field. Review it before sending.")
    }

    private func composer(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: expanded ? 20 : 12) {
                TextField(expanded ? "I’d like to…" : "Ask a follow-up…", text: $model.assistantInput, axis: .vertical)
                    .font(.system(size: expanded ? 17 : 14))
                    .textFieldStyle(.plain)
                    .lineLimit(expanded ? 3...5 : 1...3)
                    .focused($inputFocused)
                    .onSubmit(sendOrConnect)
                    .accessibilityLabel("Your request to Dayfold")
                HStack(spacing: 10) {
                    if model.assistantInput.count > 1_400 {
                        Text("\(model.assistantInput.count)/1,800")
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(model.assistantInput.count > 1_800 ? Color.red : Color.secondary)
                    } else {
                        Text("You review events before saving.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Button(action: sendOrConnect) {
                        HStack(spacing: 8) {
                            Text(model.assistantKeyPresent ? "Send request" : "Connect OpenAI")
                            Image(systemName: model.assistantKeyPresent ? "arrow.up" : "arrow.right")
                                .font(.system(size: 10, weight: .semibold))
                        }.font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.assistantKeyPresent ? !canSend : busy || model.assistantConfigurationBusy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(model.assistantKeyPresent ? "Send request (⌘Return)" : "Connect your OpenAI account with an API key")
                }
            }
            .padding(expanded ? 20 : 16)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(inputFocused ? Color.dayfoldAccent.opacity(0.55) : Color.primary.opacity(0.13), lineWidth: 1))
            Text("OpenAI receives your request and relevant calendar details.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.assistantKeyPresent, !available, let message = model.assistantAvailability?.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var requestResult: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 11) {
                Text("YOUR REQUEST").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                Text(model.assistantQuestion)
                    .font(.system(size: model.assistantQuestion.count > 160 ? 19 : 25, weight: .medium))
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            }
            if !model.assistantActivity.isEmpty || model.assistantIsWorking {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(model.assistantActivity, id: \.self) { activity in
                        Label(activity, systemImage: "checkmark")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if model.assistantIsWorking {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text(model.assistantIsStopping ? "Stopping…" : "Working on your request…")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop") { model.cancelAssistant() }
                                .controlSize(.small).disabled(model.assistantIsStopping)
                        }
                    }
                }
            }
            if !model.assistantAnswer.isEmpty {
                Text(model.assistantAnswer)
                    .font(.system(size: 15)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let proposal = model.assistantProposal { proposalCard(proposal) }
            if let status = model.assistantDraftStatus {
                Label(status, systemImage: "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.assistantError {
                Label(error, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(DayfoldMotion.quick(reduceMotion), value: model.assistantIsWorking)
    }

    private func proposalCard(_ proposal: AssistantEventProposal) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SUGGESTED EVENT")
                .font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Color.dayfoldAccent)
            HStack(alignment: .top, spacing: 17) {
                if let zone = model.assistantProposalZone, let time = try? proposal.validatedTime(in: zone) {
                    let interval = time.interval(in: zone)
                    VStack(spacing: 4) {
                        Text(interval.start.formatted(Date.FormatStyle(timeZone: zone).month(.abbreviated)).uppercased())
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.dayfoldAccent)
                        Text(interval.start.formatted(Date.FormatStyle(timeZone: zone).day()))
                            .font(.system(size: 28, weight: .medium)).monospacedDigit()
                    }
                    .frame(width: 56, height: 64)
                    .background(Color.dayfoldAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(proposal.title).font(.system(size: 19, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let zone = model.assistantProposalZone, let time = try? proposal.validatedTime(in: zone) {
                        let interval = time.interval(in: zone)
                        Text(interval.start.formatted(Date.FormatStyle(timeZone: zone).weekday(.wide).month(.abbreviated).day()))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(proposalTime(interval, zone: zone))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                Text("Ready for your review.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(model.assistantIsOpeningDraft ? "Opening…" : model.assistantDraftID == nil ? "Review Event" : "Reopen Draft") {
                    model.reviewAssistantProposal()
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy || model.editingDraft != nil)
            }
        }
        .padding(22)
        .background(Color.dayfoldAccent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.dayfoldAccent.opacity(0.23), lineWidth: 0.75))
    }

    private func proposalTime(_ interval: DateInterval, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
        let end = calendar.isDate(interval.start, inSameDayAs: interval.end)
            ? interval.end.formatted(clock)
            : interval.end.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
        return "\(interval.start.formatted(clock)) – \(end) · \(zone.abbreviation(for: interval.start) ?? zone.identifier)"
    }

    private var connectionSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Assistant connection").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { showingConnection = false }.keyboardShortcut(.cancelAction)
            }
            Divider()
            AssistantConnectionView(model: model)
        }
        .padding(26).frame(width: 500)
    }

    private func sendOrConnect() {
        if !model.assistantKeyPresent {
            guard !busy, !model.assistantConfigurationBusy else { return }
            showingConnection = true
        } else if canSend {
            inputFocused = false
            model.askAssistant()
        }
    }
}
