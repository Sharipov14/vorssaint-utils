// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// The chat's providers, under the AI page's settings: any number of presets
/// and one's own, each with its address, key and models.
struct NotchChatSettingsControls: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchChatProviders) private var stored = ""
    @AppStorage(DefaultsKey.notchChatModel) private var selectedModel = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: UUID?
    private var text: NotchChatStrings { FeatureStrings.notchChat(l10n.language) }
    private var providers: [ChatProvider] { NotchChatSupport.providers(from: stored) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.settingsDescription).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if providers.isEmpty {
                Text(text.noProviders).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(providers) { provider in
                ChatProviderRow(provider: binding(provider.id), expanded: expanded == provider.id, text: text,
                                toggle: { animate { expanded = expanded == provider.id ? nil : provider.id } },
                                delete: { delete(provider) })
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            Menu {
                ForEach(ChatPreset.all) { preset in
                    Button(preset.name) { add(preset.provider()) }
                }
                Divider()
                Button(text.customProvider) { add(ChatProvider(name: text.customProvider, wire: .openAI, baseURL: "")) }
            } label: {
                Label(text.addProvider, systemImage: "plus")
            }
            .fixedSize()
        }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86), change)
    }

    private func binding(_ id: UUID) -> Binding<ChatProvider> {
        Binding {
            // A row being removed may still be drawn once after its provider is gone.
            providers.first { $0.id == id } ?? ChatProvider(id: id, name: "", wire: .openAI, baseURL: "")
        } set: { changed in
            var list = providers
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index] = changed
            stored = NotchChatSupport.json(list)
        }
    }

    private func add(_ provider: ChatProvider) {
        animate {
            stored = NotchChatSupport.json(providers + [provider])
            expanded = provider.id
        }
    }

    private func delete(_ provider: ChatProvider) {
        ChatKeychain.remove(provider)
        if NotchChatSupport.selection(selectedModel)?.provider == provider.id { selectedModel = "" }
        animate {
            stored = NotchChatSupport.json(providers.filter { $0.id != provider.id })
            if expanded == provider.id { expanded = nil }
        }
    }
}

/// One provider: a summary line that opens into its editor.
private struct ChatProviderRow: View {
    @Binding var provider: ChatProvider
    let expanded: Bool
    let text: NotchChatStrings
    let toggle: () -> Void
    let delete: () -> Void
    @State private var key = ""
    @State private var newModel = ""
    /// Models the server listed that are not added yet; nil until loaded.
    @State private var available: [String]?
    @State private var status: String?
    @State private var busy = false
    @State private var confirmsDelete = false

    private var validURL: Bool { NotchTranslateSupport.serverURL(provider.baseURL) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if expanded {
                editor.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(expanded ? 0.45 : 0.25),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { key = ChatKeychain.key(for: provider) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    ChatProviderBadge(provider: provider)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.name.isEmpty ? text.customProvider : provider.name)
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(summary)
            Toggle(text.enabled, isOn: $provider.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private var summary: String {
        let host = URL(string: provider.baseURL)?.host ?? provider.baseURL
        let state = provider.requiresKey && key.isEmpty ? text.keyMissing : text.modelCount(provider.models.count)
        return host.isEmpty ? state : "\(host) · \(state)"
    }

    @ViewBuilder private var editor: some View {
        labeled(text.name) { TextField("", text: $provider.name) }
        Picker(text.wire, selection: $provider.wire) {
            ForEach(ChatWire.allCases, id: \.self) { Text(text.wire($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        labeled(text.baseURL) {
            TextField("", text: $provider.baseURL,
                      prompt: Text(ChatPreset.named(provider.preset)?.baseURL ?? "https://api.example.com/v1"))
        }
        // Said before any request: a key must never cross the network readable.
        if !provider.baseURL.isEmpty, !validURL {
            Text(text.invalidURL).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        labeled(provider.requiresKey ? text.apiKey : "\(text.apiKey) (\(text.optional.lowercased()))") {
            SecureField("", text: $key)
                .onChange(of: key) { ChatKeychain.setKey(key, for: provider) }
        }
        labeled(text.models) { modelList }
        HStack(spacing: 8) {
            fetchControl
            Button(text.test, action: test).disabled(busy || !validURL)
            if busy { ProgressView().controlSize(.small) }
        }
        if let status {
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
        Button(text.deleteProvider, role: .destructive) { confirmsDelete = true }
            .buttonStyle(.link)
            .font(.caption)
            .confirmationDialog(text.deleteTitle(provider.name), isPresented: $confirmsDelete) {
                Button(text.delete, role: .destructive, action: delete)
                Button(text.cancel, role: .cancel) {}
            } message: {
                Text(text.deleteMessage)
            }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A long list scrolls rather than stretching the settings page.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(provider.models, id: \.self) { model in
                        HStack {
                            Text(model).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Button {
                                provider.models.removeAll { $0 == model }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(text.removeModel)
                            .accessibilityLabel(text.removeModel)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: provider.models.count > 6 ? 150 : nil)
            .fixedSize(horizontal: false, vertical: provider.models.count <= 6)
            TextField("", text: $newModel, prompt: Text(text.addModel))
                .onSubmit { addModels([newModel]); newModel = "" }
        }
    }

    /// Loads the server's list once, then offers what is not added yet.
    @ViewBuilder private var fetchControl: some View {
        let missing = (available ?? []).filter { !provider.models.contains($0) }
        if missing.isEmpty {
            Button(text.fetchModels, action: fetchModels).disabled(busy || !validURL)
        } else {
            Menu(text.fetched(missing.count)) {
                ForEach(missing, id: \.self) { model in
                    Button(model) { addModels([model]) }
                }
            }
            .fixedSize()
        }
    }

    private func addModels(_ names: [String]) {
        for name in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !name.isEmpty && !provider.models.contains(name) {
            provider.models.append(name)
        }
    }

    private func fetchModels() {
        busy = true
        status = nil
        let provider = provider
        let text = text
        Task { @MainActor in
            do {
                let models = try await NotchChatClient.models(provider: provider)
                available = models
                if models.isEmpty { status = text.noModelsFound }
            } catch is CancellationError {
            } catch {
                status = text.failure(error as? NotchChatFailure ?? .badResponse)
            }
            busy = false
        }
    }

    /// A short real request to the first model: it proves the address, key
    /// and model name together.
    private func test() {
        guard let model = provider.models.first else { status = text.needsModel; return }
        busy = true
        status = nil
        let provider = provider
        let text = text
        Task { @MainActor in
            var reply = ""
            do {
                let stream = NotchChatClient.stream(provider: provider, model: model,
                                                    messages: [ChatMessage(role: .user, text: "Hi")],
                                                    system: "Reply in a few words.")
                for try await case .text(let piece) in stream {
                    reply += piece
                    if reply.count > 200 { break }
                }
                let answer = NotchChatSupport.split(reply).answer
                status = answer.isEmpty ? text.testWorks : "\(text.testWorks): \(answer.prefix(80))"
            } catch is CancellationError {
            } catch {
                status = text.failure(error as? NotchChatFailure ?? .badResponse)
            }
            busy = false
        }
    }

    /// The field's name above it: these settings draw no label of a field's own.
    private func labeled(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            field().textFieldStyle(.roundedBorder)
        }
    }
}

/// A provider's mark: its initial on its colour. No brand logos.
struct ChatProviderBadge: View {
    let provider: ChatProvider
    var size: CGFloat = 26

    var body: some View {
        Text(provider.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(provider.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .saturation(provider.enabled ? 1 : 0)
            .opacity(provider.enabled ? 1 : 0.55)
            .accessibilityHidden(true)
    }
}

extension ChatProvider {
    /// A preset's own colour; one's own provider gets a steady one from its id.
    var tint: Color {
        switch preset {
        case "anthropic": return .orange
        case "openAI": return .green
        case "openCodeZen": return .gray
        case "openRouter": return .indigo
        case "deepSeek": return .blue
        case "gemini": return .teal
        case "ollama": return .brown
        case "lmStudio": return .purple
        default:
            let palette: [Color] = [.pink, .mint, .cyan, .red, .yellow, .indigo]
            return palette[Int(id.uuid.0) % palette.count]
        }
    }
}
