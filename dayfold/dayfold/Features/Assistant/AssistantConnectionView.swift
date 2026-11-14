import SwiftUI
import CalendarCore

/// Inline connection controls shared by Settings and the assistant's setup card.
/// The key field is always empty when this view opens; it never reads a stored key.
struct AssistantConnectionView: View {
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var selectedModel = ""

    private var busy: Bool { model.assistantConfigurationBusy || model.isLoading }
    private var modelID: String { selectedModel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canApplyModel: Bool { !busy && !modelID.isEmpty && modelID != model.preferences.assistantModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect OpenAI").font(.system(size: 14, weight: .medium))
                Text("Use your own API key. API usage is billed to your OpenAI account.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(model.assistantKeyPresent ? "API key saved" : "No API key saved",
                      systemImage: model.assistantKeyPresent ? "checkmark.circle.fill" : "key")
                    .font(.system(size: 11))
                    .foregroundStyle(model.assistantKeyPresent ? Color.dayfoldAccent : Color.secondary)
                SecureField(model.assistantKeyPresent ? "Enter a replacement API key" : "OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .disabled(busy)
                    .onSubmit(saveKey)
                    .accessibilityLabel("OpenAI API key")
                    .accessibilityIdentifier("assistant-api-key")
                HStack(spacing: 12) {
                    Button(model.assistantKeyPresent ? "Replace API Key" : "Save API Key", action: saveKey)
                        .disabled(busy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.assistantKeyPresent {
                        Button("Remove Key", role: .destructive, action: removeKey)
                            .disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small).accessibilityLabel("Updating assistant connection") }
                }
                Text("Saved in this Mac’s Keychain, separately for demo and Google calendars. Saving a key does not send a request.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    TextField("Model", text: $selectedModel)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .disabled(busy)
                        .onSubmit(applyModel)
                        .accessibilityLabel("OpenAI model ID")
                        .accessibilityIdentifier("assistant-model")
                    Button("Apply Model", action: applyModel).disabled(!canApplyModel)
                }
                Text("Use a model available to your OpenAI account.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let message = model.assistantConfigurationMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant-connection-status")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Your requests and relevant event titles and times are sent to OpenAI. Calendar tools do not read Google credentials, guest lists, event descriptions, or meeting links.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                Link("OpenAI data usage and retention", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                    .font(.system(size: 11)).foregroundStyle(Color.dayfoldAccent)
            }
        }
        .onAppear { selectedModel = model.preferences.assistantModel }
        .task { await model.refreshAssistantConnection() }
        .onChange(of: model.sessionGeneration) {
            apiKey = ""
            selectedModel = model.preferences.assistantModel
        }
        .onChange(of: model.preferences.assistantModel) { selectedModel = model.preferences.assistantModel }
        .onDisappear { apiKey = "" }
    }

    private func saveKey() {
        guard !busy, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = apiKey, generation = model.sessionGeneration
        Task {
            guard generation == model.sessionGeneration else { return }
            let saved = await model.saveAssistantKey(key)
            if saved, generation == model.sessionGeneration { apiKey = "" }
        }
    }

    private func removeKey() {
        guard !busy else { return }
        let generation = model.sessionGeneration
        Task {
            guard generation == model.sessionGeneration else { return }
            await model.removeAssistantKey()
            if generation == model.sessionGeneration { apiKey = "" }
        }
    }

    private func applyModel() {
        guard canApplyModel else { return }
        model.preferences.assistantModel = modelID
        model.savePreferences()
    }
}
