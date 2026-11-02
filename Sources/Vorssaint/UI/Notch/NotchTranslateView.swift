// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import Translation

/// The section's settings: where translations are made, the online service
/// and its key, and how long the history stays.
struct NotchTranslateSettingsControls: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var translator = NotchTranslateService.shared
    @AppStorage(DefaultsKey.notchTranslateEnabled) private var enabled = true
    @AppStorage(DefaultsKey.notchTranslateShortcutEnabled) private var shortcutEnabled = false
    @AppStorage(DefaultsKey.notchTranslateEngine) private var engine = NotchTranslateEngine.apple.rawValue
    @AppStorage(DefaultsKey.notchTranslateProvider) private var provider = NotchTranslateProvider.deepL.rawValue
    @AppStorage(DefaultsKey.notchTranslateModel) private var model = ""
    @AppStorage(DefaultsKey.notchTranslateAutoDetect) private var autoDetect = true
    @AppStorage(DefaultsKey.notchTranslateKeepsHistory) private var keepsHistory = true
    @AppStorage(DefaultsKey.notchTranslateRetention) private var retention = ScratchpadRetention.never.rawValue
    @State private var serverURL = ""
    @State private var key = ""
    @State private var testResult: String?
    @State private var testing = false
    private var text: NotchTranslateStrings { FeatureStrings.notchTranslate(l10n.language) }
    private var selectedProvider: NotchTranslateProvider { NotchTranslateProvider(rawValue: provider) ?? .deepL }
    private var selectedEngine: NotchTranslateEngine { NotchTranslateEngine.saved() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(text.title, isOn: $enabled)
                .disabled(!AppFeature.notchTranslate.isAvailable)
            Text(text.description).font(.caption).foregroundStyle(.secondary)
            if enabled {
                if NotchTranslateEngine.appleIsSupported {
                    Picker(text.engine, selection: $engine) {
                        Text(text.engineMac).tag(NotchTranslateEngine.apple.rawValue)
                        Text(text.engineOnline).tag(NotchTranslateEngine.online.rawValue)
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text(text.failureApple).font(.caption).foregroundStyle(.secondary)
                }
                if selectedEngine == .apple {
                    Text(text.engineMacHint).font(.caption).foregroundStyle(.secondary)
                    Button(text.manageLanguages) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                    }
                } else {
                    onlineControls
                }
                Toggle(text.autoDetect, isOn: $autoDetect)
                Toggle(text.keepHistory, isOn: $keepsHistory)
                if keepsHistory {
                    Picker(text.keepFor, selection: $retention) {
                        ForEach(ScratchpadRetention.allCases, id: \.self) { value in
                            Text(text.retention(value)).tag(value.rawValue)
                        }
                    }
                }
                Toggle(l10n.s.quickToolShortcutToggle, isOn: $shortcutEnabled)
                if shortcutEnabled {
                    ShortcutPreferenceRow(role: .notchTranslate) { NotchService.shared.syncWithPreferences() }
                    if translator.shortcutFailed {
                        Text(l10n.s.shortcutUnavailable).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .onAppear(perform: loadProvider)
        .onChange(of: provider) { loadProvider() }
        .onChange(of: enabled) { NotchService.shared.syncWithPreferences() }
        .onChange(of: shortcutEnabled) { NotchService.shared.syncWithPreferences() }
    }

    @ViewBuilder private var onlineControls: some View {
        Text(text.engineOnlineHint).font(.caption).foregroundStyle(.secondary)
        Picker(text.provider, selection: $provider) {
            ForEach(NotchTranslateProvider.allCases) { Text($0.title).tag($0.rawValue) }
        }
        if selectedProvider.usesServerURL {
            labeled(text.serverURL) {
                TextField("", text: $serverURL, prompt: Text(selectedProvider.defaultServerURL))
                    .onChange(of: serverURL) { saveServerURL() }
            }
        }
        if selectedProvider.usesModel {
            labeled(text.model) {
                TextField("", text: $model, prompt: Text("gpt-4o-mini"))
            }
        }
        // A self-hosted service or a local model may need no key.
        labeled(selectedProvider.requiresKey ? text.apiKey : "\(text.apiKey) (\(text.optional.lowercased()))") {
            SecureField("", text: $key)
                .onChange(of: key) { TranslationKeychain.setKey(key, for: selectedProvider) }
        }
        HStack {
            Button(text.test, action: test).disabled(testing)
            if testing { ProgressView().controlSize(.small) }
            if let testResult {
                Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// The field's name above it: these settings draw no label of a field's own.
    private func labeled(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            field().textFieldStyle(.roundedBorder)
        }
    }

    private func loadProvider() {
        serverURL = UserDefaults.standard.string(forKey: NotchTranslateService.serverURLKey(selectedProvider)) ?? ""
        key = TranslationKeychain.key(for: selectedProvider)
        testResult = nil
    }

    private func saveServerURL() {
        UserDefaults.standard.set(serverURL, forKey: NotchTranslateService.serverURLKey(selectedProvider))
    }

    private func test() {
        saveServerURL()
        testing = true
        testResult = nil
        let config = NotchTranslateService.savedOnlineConfig()
        let target = NotchTranslateSupport.defaultTarget()
        let strings = text
        Task { @MainActor in
            do {
                let result = try await NotchTranslateService.translateOnline(
                    text: "Hello", source: "en", target: NotchTranslateSupport.sameLanguage(target, "en") ? "es" : target,
                    config: config)
                testResult = "\(strings.testWorks): \(result)"
            } catch {
                testResult = strings.failure(error as? NotchTranslateFailure ?? .offline)
            }
            testing = false
        }
    }
}

/// The page: the text and its language above, the translation below, the
/// language pair and the actions in the island's top row.
struct NotchTranslateView: View {
    /// In its own window the page draws the island's top row itself.
    var inWindow = false
    @ObservedObject private var translator = NotchTranslateService.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.notchSettingsPreview) private var preview
    @Environment(\.notchBand) private var band
    @AppStorage(DefaultsKey.notchTranslateAutoDetect) private var autoDetect = true
    @State private var showsHistory = false
    @State private var copied = false
    @State private var editor = EditorHandle()
    private var text: NotchTranslateStrings { FeatureStrings.notchTranslate(l10n.language) }
    private static let editorInset = NSSize(width: 6, height: 6)
    private static let textSize: CGFloat = 13

    /// The editor's text view, so opening the page can put the caret in it.
    private final class EditorHandle {
        weak var view: NSTextView?
    }

    var body: some View {
        Group {
            if preview {
                NotchEmptyView(symbol: "translate", message: FeatureStrings.notchEditor(l10n.language).translateSummary)
            } else if showsHistory {
                historyList
            } else {
                VStack(spacing: 6) {
                    inputCard
                    outputCard
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .notchBand(leading: { if !preview && !inWindow { languageControls } },
                   trailing: { if !preview && !inWindow { actions } })
        .safeAreaInset(edge: .top, spacing: inWindow ? 6 : 0) {
            if inWindow {
                HStack {
                    languageControls
                    Spacer(minLength: 6)
                    actions
                }
            }
        }
        .modifier(NotchAppleTranslationHost(translator: translator))
        .onAppear {
            translator.loadHistory()
            translator.resume()
            DispatchQueue.main.async { focusEditor() }
        }
        .onDisappear { translator.commit() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    private var inputCard: some View {
        HStack(alignment: .top, spacing: 0) {
            editorField
            VStack(spacing: 2) {
                NotchIconButton(symbol: "speaker.wave.2", title: text.listen) {
                    translator.speak(translator.input, in: translator.source)
                }
                NotchIconButton(symbol: "xmark", title: text.clear) {
                    translator.input = ""
                    focusEditor()
                }
                Spacer(minLength: 0)
                NotchIconButton(symbol: "arrow.right.circle.fill", title: text.translate, action: translator.translateAndRecord)
                    .disabled(translator.working)
            }
            .disabled(translator.input.isEmpty)
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
    }

    private var editorField: some View {
        ZStack(alignment: .topLeading) {
            PlainTextEditor(text: $translator.input, fontSize: Self.textSize, textColor: .white,
                            textContainerInset: Self.editorInset,
                            onCommandReturn: { translator.translateAndRecord() },
                            onReturn: { translator.translateAndRecord() }) { view in
                view.insertionPointColor = .white
                editor.view = view
                DispatchQueue.main.async { focusEditor() }
            }
            if translator.input.isEmpty {
                Text(text.placeholder)
                    .font(.system(size: Self.textSize))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, Self.editorInset.width + PlainTextEditor.lineFragmentPadding)
                    .padding(.top, Self.editorInset.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outputCard: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    outputText
                    if let variants = translator.variants { variantsList(variants) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Self.editorInset.width + PlainTextEditor.lineFragmentPadding)
            }
            VStack(spacing: 2) {
                NotchIconButton(symbol: "speaker.wave.2", title: text.listen) {
                    translator.speak(translator.output, in: translator.target)
                }
                .disabled(translator.output.isEmpty)
                if translator.working { ProgressView().controlSize(.small).frame(width: 28, height: 28) }
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
    }

    private var outputText: some View {
        Group {
            if let failure = translator.failure {
                Label(text.failure(failure), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white.opacity(0.6))
            } else if translator.output.isEmpty {
                Text(translator.engine == .online && !translator.input.isEmpty ? text.translateHint : " ")
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                Text(translator.output)
                    .foregroundStyle(.white.opacity(translator.working ? 0.5 : 0.9))
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: Self.textSize))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A word's other translations by part of speech, or its dictionary entry.
    @ViewBuilder private func variantsList(_ variants: NotchTranslateVariants) -> some View {
        switch variants {
        case .groups(let groups):
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle(group.partOfSpeech)
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 2) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.word).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                                if !item.back.isEmpty {
                                    Text(item.back.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            .textSelection(.enabled)
                            Spacer(minLength: 4)
                            NotchIconButton(symbol: "doc.on.doc", title: text.copy) { translator.copy(item.word) }
                            NotchIconButton(symbol: "speaker.wave.2", title: text.listen) {
                                translator.speak(item.word, in: translator.target)
                            }
                        }
                    }
                }
            }
        case .definition(let definition):
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle(text.dictionary)
                Text(definition)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
    }

    private var historyList: some View {
        Group {
            if translator.history.isEmpty {
                NotchEmptyView(symbol: "clock.arrow.circlepath", message: text.historyEmpty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(translator.history) { entry in
                            Button {
                                translator.use(entry)
                                showsHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.source).foregroundStyle(.white.opacity(0.55))
                                    Text(entry.result).foregroundStyle(.white.opacity(0.9))
                                }
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                            .buttonStyle(NotchButtonStyle(cornerRadius: 10, lifts: false))
                        }
                    }
                }
            }
        }
    }

    /// What the text is in, the way to swap, and what it goes into.
    private var languageControls: some View {
        HStack(spacing: 4) {
            // Beside the camera only the pair's controls fit.
            if !band.besideCamera {
                NotchMenuButton(title: text.translateFrom, items: sourceItems, cornerRadius: 9) {
                    NotchBandMenuLabel(title: sourceTitle)
                }
                .help(text.translateFrom)
            }
            NotchIconButton(symbol: "arrow.left.arrow.right", title: text.swap, action: translator.swap)
            NotchMenuButton(title: text.translateInto, items: languageItems, cornerRadius: 9) {
                NotchBandMenuLabel(title: name(translator.target))
            }
            .help(text.translateInto)
        }
    }

    private var sourceTitle: String {
        guard autoDetect else { return name(translator.chosenSource) }
        return translator.detected.map { text.detected(name($0)) } ?? text.autoDetect
    }

    private var sourceItems: [NotchMenuItem] {
        [NotchMenuItem(title: text.autoDetect, checked: autoDetect) { translator.chooseSource(nil) }, .separator]
            + sortedLanguages.map { language, name in
                NotchMenuItem(title: name, checked: !autoDetect && language == translator.chosenSource) {
                    translator.chooseSource(language)
                }
            }
    }

    private var languageItems: [NotchMenuItem] {
        sortedLanguages.map { language, name in
            NotchMenuItem(title: name, checked: language == translator.target) { translator.choose(language) }
        }
    }

    private var sortedLanguages: [(String, String)] {
        NotchTranslateSupport.languages(for: translator.engine)
            .map { ($0, name($0)) }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
    }

    private func name(_ language: String) -> String {
        NotchTranslateSupport.displayName(language, in: l10n.language)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            NotchIconButton(symbol: "clock.arrow.circlepath", title: text.history, selected: showsHistory) {
                showsHistory.toggle()
            }
            if showsHistory {
                NotchIconButton(symbol: "trash", title: text.clearHistory, action: translator.clearHistory)
                    .disabled(translator.history.isEmpty)
            } else {
                NotchIconButton(symbol: copied ? "checkmark" : "doc.on.doc", title: copied ? text.copied : text.copy) {
                    translator.copyOutput()
                    copied = true
                }
                .disabled(translator.output.isEmpty)
            }
            if inWindow {
                NotchIconButton(symbol: "xmark", title: text.close) { NotchTranslateWindow.shared.close() }
            } else {
                NotchIconButton(symbol: "pip.exit", title: text.openInWindow) {
                    NotchService.shared.collapse()
                    NotchTranslateWindow.shared.show()
                }
            }
        }
    }

    private func focusEditor() {
        guard let view = editor.view, let window = view.window, window.isKeyWindow else { return }
        window.makeFirstResponder(view)
        let end = NSRange(location: (view.string as NSString).length, length: 0)
        view.setSelectedRange(end)
    }
}

/// The translator lifted out of the island: a panel over every window that
/// stays where it is dragged until its close button puts it away.
final class NotchTranslateWindow {
    static let shared = NotchTranslateWindow()
    private var panel: NSPanel?

    /// Borderless panels refuse key status, and typing needs it.
    private final class KeyablePanel: OverlayPanel {
        override var canBecomeKey: Bool { true }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 380, height: 340)
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // The text views keep their drags for selecting; the rest moves the window.
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = NSSize(width: 300, height: 240)
        let host = NSHostingController(rootView: NotchTranslateView(inWindow: true)
            .padding(10)
            .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .environment(\.colorScheme, .dark))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(size)
        panel.center()
        // Where it was last dragged, across launches.
        panel.setFrameAutosaveName("VorssaintTranslateWindow")
        return panel
    }
}

/// Runs the service's on-device jobs where a translation session can exist.
private struct NotchAppleTranslationHost: ViewModifier {
    @ObservedObject var translator: NotchTranslateService

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(NotchAppleTranslationTask(translator: translator))
        } else {
            content
        }
    }
}

@available(macOS 15, *)
private struct NotchAppleTranslationTask: ViewModifier {
    @ObservedObject var translator: NotchTranslateService
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: translator.appleJob) { _, job in
                guard let job else { return }
                let next = TranslationSession.Configuration(source: Locale.Language(identifier: job.source),
                                                            target: Locale.Language(identifier: job.target))
                // The same pair runs again only when told to.
                if configuration == next { configuration?.invalidate() } else { configuration = next }
            }
            .translationTask(configuration) { session in
                guard let job = translator.appleJob else { return }
                let status = await LanguageAvailability().status(from: Locale.Language(identifier: job.source),
                                                                 to: Locale.Language(identifier: job.target))
                if status == .unsupported {
                    translator.finishApple(job, result: .failure(.unsupportedPair))
                    return
                }
                do {
                    let response = try await session.translate(job.text)
                    translator.finishApple(job, result: .success(response.targetText))
                } catch is CancellationError {
                } catch {
                    translator.finishApple(job, result: .failure(.unknown))
                }
            }
    }
}
