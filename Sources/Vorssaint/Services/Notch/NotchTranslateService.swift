// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import AVFoundation
import Combine
import CoreServices

/// One text for Apple's on-device translation. The page runs it, since a
/// translation session only exists inside a SwiftUI view.
struct NotchTranslateAppleJob: Equatable {
    let id = UUID()
    let text: String
    let source: String
    let target: String
}

/// The island's translator: what is typed, its translation and the history.
/// On this Mac a translation follows typing; online it waits for
/// Return, so half-typed words are not sent anywhere.
final class NotchTranslateService: ObservableObject {
    static let shared = NotchTranslateService()

    @Published var input = "" { didSet { if input != oldValue { inputChanged() } } }
    @Published private(set) var output = ""
    @Published private(set) var detected: String?
    @Published private(set) var variants: NotchTranslateVariants?
    @Published private(set) var working = false
    @Published private(set) var failure: NotchTranslateFailure?
    @Published private(set) var appleJob: NotchTranslateAppleJob?
    @Published private(set) var history: [NotchTranslateEntry] = []
    @Published private(set) var preferred: String
    @Published private(set) var alternate: String
    /// The text's language when it is picked rather than recognized.
    @Published private(set) var chosenSource: String
    /// True when macOS refused the shortcut, so Settings can say so.
    @Published private(set) var shortcutFailed = false
    private let hotkey = QuickToolHotkey(id: 82)

    /// The text `output` translates; history keeps the pair only when they match.
    private var outputSource = ""
    /// The language `output` is in, which the pair may have moved on from.
    private var outputTarget = ""
    private var recordsWhenDone = false
    private var liveWork: DispatchWorkItem?
    private var onlineTask: Task<Void, Never>?
    private var variantsTask: Task<Void, Never>?
    private let speech = AVSpeechSynthesizer()
    private var spoken = ""
    private var historyLoaded = false
    private let defaults = UserDefaults.standard

    private init() {
        let preferred = NotchTranslateSupport.supportedLanguage(defaults.string(forKey: DefaultsKey.notchTranslateTarget))
            ?? NotchTranslateSupport.defaultTarget()
        self.preferred = preferred
        let alternate = NotchTranslateSupport.supportedLanguage(defaults.string(forKey: DefaultsKey.notchTranslateAlternate))
            ?? NotchTranslateSupport.defaultAlternate(for: preferred)
        self.alternate = alternate
        chosenSource = NotchTranslateSupport.supportedLanguage(defaults.string(forKey: DefaultsKey.notchTranslateSource))
            ?? alternate
        hotkey.onPress = { NotchService.shared.showTranslate(toggle: true) }
    }

    /// Registered while the page is in the island, and quiet while another
    /// shortcut field is recording.
    func syncShortcut() {
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.notchTranslateShortcut, fallback: .notchTranslateDefault)
        let failed = !hotkey.sync(enabled: NotchSupport.routesTranslate()
                                    && defaults.bool(forKey: DefaultsKey.notchTranslateShortcutEnabled)
                                    && !ShortcutCapture.isCapturing,
                                  shortcut: shortcut, storageKey: DefaultsKey.notchTranslateShortcut)
        if failed != shortcutFailed { shortcutFailed = failed }
    }

    func suspendShortcut() {
        hotkey.unregister()
        if shortcutFailed { shortcutFailed = false }
    }

    var engine: NotchTranslateEngine { NotchTranslateEngine.saved(in: defaults) }

    var autoDetect: Bool { defaults.bool(forKey: DefaultsKey.notchTranslateAutoDetect) }

    var target: String {
        NotchTranslateSupport.target(detected: autoDetect ? detected : chosenSource, preferred: preferred, alternate: alternate)
    }

    /// The language the text is read in. Apple's translation is never left to
    /// guess it, since it then asks with a sheet the island can't hold.
    var source: String {
        autoDetect ? detected ?? alternate : chosenSource
    }

    // MARK: Typing and translating

    private func inputChanged() {
        liveWork?.cancel()
        onlineTask?.cancel()
        variantsTask?.cancel()
        variants = nil
        appleJob = nil
        working = false
        failure = nil
        recordsWhenDone = false
        detected = NotchTranslateSupport.detectLanguage(input, likely: [preferred, alternate])
        // Online nothing is sent until Return, and a translation of other
        // text would read as this one's.
        let empty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty || engine == .online {
            output = ""
            outputSource = ""
        }
        guard engine == .apple, !empty else { return }
        let work = DispatchWorkItem { [weak self] in self?.translate() }
        liveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTranslateSupport.liveDelay, execute: work)
    }

    /// Return: translate now and keep the result in the history.
    func translateAndRecord() {
        if !output.isEmpty, outputSource == input, !working {
            record()
            return
        }
        recordsWhenDone = true
        translate()
    }

    func translate() {
        liveWork?.cancel()
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.count <= NotchTranslateSupport.characterLimit else { return fail(.tooLong) }
        let target = self.target
        failure = nil
        working = true
        switch engine {
        case .apple:
            appleJob = NotchTranslateAppleJob(text: text, source: source, target: target)
        case .online:
            onlineTask?.cancel()
            // An unrecognized language is left to the service to tell.
            let source = autoDetect ? detected : chosenSource
            let config = Self.savedOnlineConfig()
            onlineTask = Task { @MainActor [weak self] in
                do {
                    let result = try await Self.translateOnline(text: text, source: source, target: target, config: config)
                    guard !Task.isCancelled else { return }
                    self?.finish(text: text, target: target, result: result)
                } catch is CancellationError {
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(error as? NotchTranslateFailure ?? .offline)
                }
            }
        }
    }

    /// The page reports how Apple's translation of `job` went.
    func finishApple(_ job: NotchTranslateAppleJob, result: Result<String, NotchTranslateFailure>) {
        guard job == appleJob else { return }
        appleJob = nil
        switch result {
        case .success(let text): finish(text: job.text, target: job.target, result: text)
        case .failure(let failure): fail(failure)
        }
    }

    private func finish(text: String, target: String, result: String) {
        guard text == input else { return }
        working = false
        output = result
        outputSource = text
        outputTarget = target
        if recordsWhenDone { record() }
        lookUpVariants(text)
    }

    /// A job asked for while no page was up to run it is asked again by the
    /// page that appears, or its spinner would never stop.
    func resume() {
        if appleJob != nil { translate() }
    }

    /// Alternatives for a single word: from the online model when one
    /// translates, else from the dictionaries macOS keeps on the Mac.
    private func lookUpVariants(_ text: String) {
        variantsTask?.cancel()
        variants = nil
        guard NotchTranslateSupport.isWord(text) else { return }
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = engine == .online ? Self.savedOnlineConfig() : nil
        let (source, target) = (self.source, outputTarget)
        let interface = L10n.shared.language.rawValue
        variantsTask = Task { @MainActor [weak self] in
            let found: NotchTranslateVariants?
            if let config, config.provider == .openAI {
                let groups = try? await Self.onlineVariants(word: word, source: source, target: target,
                                                            interface: interface, config: config)
                found = groups.flatMap { $0.isEmpty ? nil : .groups($0) }
            } else {
                found = await Task.detached { Self.definition(of: word) }.value.map { .definition($0) }
            }
            guard !Task.isCancelled, let self, self.input == text else { return }
            self.variants = found
        }
    }

    private static func definition(of word: String) -> String? {
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let definition = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() else { return nil }
        let text = (definition as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func fail(_ failure: NotchTranslateFailure) {
        working = false
        recordsWhenDone = false
        self.failure = failure
    }

    // MARK: Languages

    func choose(_ language: String) {
        // A picked text language that becomes the target trades places.
        if !autoDetect, NotchTranslateSupport.sameLanguage(language, chosenSource) { setSource(target) }
        let pair = NotchTranslateSupport.choosing(language, preferred: preferred, alternate: alternate)
        setPair(preferred: pair.preferred, alternate: pair.alternate)
        retranslate()
    }

    /// Nil goes back to recognizing the text's language.
    func chooseSource(_ language: String?) {
        defaults.set(language == nil, forKey: DefaultsKey.notchTranslateAutoDetect)
        if let language { setSource(language) }
        detected = NotchTranslateSupport.detectLanguage(input, likely: [preferred, alternate])
        retranslate()
    }

    private func setSource(_ language: String) {
        chosenSource = language
        defaults.set(language, forKey: DefaultsKey.notchTranslateSource)
    }

    /// The translation becomes the text, and its language the other side.
    func swap() {
        let (source, target) = (self.source, self.target)
        if !autoDetect { setSource(target) }
        setPair(preferred: source, alternate: target)
        if !output.isEmpty { input = output } else { retranslate() }
    }

    private func setPair(preferred: String, alternate: String) {
        self.preferred = preferred
        self.alternate = NotchTranslateSupport.sameLanguage(preferred, alternate)
            ? NotchTranslateSupport.defaultAlternate(for: preferred) : alternate
        defaults.set(self.preferred, forKey: DefaultsKey.notchTranslateTarget)
        defaults.set(self.alternate, forKey: DefaultsKey.notchTranslateAlternate)
    }

    private func retranslate() {
        guard !input.isEmpty else { return }
        if engine == .apple { translate() } else { output = ""; outputSource = ""; variants = nil }
    }

    // MARK: Results

    func copyOutput() {
        guard !output.isEmpty else { return }
        copy(output)
        record()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Reads the text aloud; the same text again stops it.
    func speak(_ text: String, in language: String) {
        let repeated = speech.isSpeaking && spoken == text
        speech.stopSpeaking(at: .immediate)
        guard !repeated, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        spoken = text
        speech.speak(utterance)
    }

    /// Leaving the page keeps a finished translation, as copying does.
    func commit() {
        guard !output.isEmpty, outputSource == input else { return }
        record()
    }

    private func record() {
        guard !output.isEmpty, defaults.bool(forKey: DefaultsKey.notchTranslateKeepsHistory) else { return }
        loadHistory()
        let entry = NotchTranslateEntry(source: outputSource, result: output, target: outputTarget, date: Date())
        history = NotchTranslateSupport.recording(entry, in: history)
        saveHistory()
    }

    func use(_ entry: NotchTranslateEntry) {
        input = entry.source
        if engine == .online { output = entry.result; outputSource = entry.source; outputTarget = entry.target }
    }

    func clearHistory() {
        history = []
        if let url = Self.historyURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Reads the saved history once, dropping what is past its time.
    func loadHistory() {
        guard !historyLoaded else { return }
        historyLoaded = true
        let retention = ScratchpadRetention.sanitized(defaults.string(forKey: DefaultsKey.notchTranslateRetention))
        guard let url = Self.historyURL, let data = try? Data(contentsOf: url),
              let saved = try? Self.decoder.decode([NotchTranslateEntry].self, from: data) else { return }
        history = NotchTranslateSupport.pruned(saved, retention: retention, now: Date())
        if history.count != saved.count { saveHistory() }
    }

    private func saveHistory() {
        guard let directory = PrivateFileStore.containerURL, let url = Self.historyURL,
              PrivateFileStore.createDirectory(at: directory),
              let data = try? Self.encoder.encode(history) else { return }
        if history.isEmpty { try? FileManager.default.removeItem(at: url) } else { PrivateFileStore.write(data, to: url) }
    }

    /// Turning the section off or uninstalling it ends any work; the history
    /// stays on disk until it is cleared, as other features keep their data.
    func stop() {
        liveWork?.cancel()
        onlineTask?.cancel()
        variantsTask?.cancel()
        speech.stopSpeaking(at: .immediate)
        NotchTranslateWindow.shared.close()
        appleJob = nil
        working = false
        input = ""
        history = []
        historyLoaded = false
    }

    private static var historyURL: URL? {
        PrivateFileStore.containerURL?.appendingPathComponent("TranslateHistory.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Online

    static func savedOnlineConfig(in defaults: UserDefaults = .standard) -> NotchTranslateOnlineConfig {
        let provider = NotchTranslateProvider.saved(in: defaults)
        let serverURL = defaults.string(forKey: serverURLKey(provider)) ?? ""
        return NotchTranslateOnlineConfig(
            provider: provider,
            serverURL: serverURL.isEmpty ? provider.defaultServerURL : serverURL,
            model: defaults.string(forKey: DefaultsKey.notchTranslateModel) ?? "",
            key: TranslationKeychain.key(for: provider))
    }

    /// Each self-hosted service remembers its own address.
    static func serverURLKey(_ provider: NotchTranslateProvider) -> String {
        DefaultsKey.notchTranslateServerURL + "." + provider.rawValue
    }

    /// No cookies, no cache and no stored credentials go along.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "Vorssaint/\(AppInfo.version)"]
        return URLSession(configuration: configuration)
    }()

    static func translateOnline(text: String, source: String?, target: String,
                                config: NotchTranslateOnlineConfig) async throws -> String {
        let request = try NotchTranslateSupport.request(text: text, source: source, target: target, config: config)
        return try NotchTranslateSupport.translation(from: await send(request), provider: config.provider)
    }

    static func onlineVariants(word: String, source: String, target: String, interface: String,
                               config: NotchTranslateOnlineConfig) async throws -> [NotchTranslateVariantGroup] {
        let request = try NotchTranslateSupport.variantsRequest(word: word, source: source, target: target,
                                                                interface: interface, config: config)
        return try NotchTranslateSupport.variants(from: await send(request))
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw NotchTranslateFailure.offline
        }
        if let status = (response as? HTTPURLResponse)?.statusCode,
           let failure = NotchTranslateSupport.failure(status: status) { throw failure }
        return data
    }
}
