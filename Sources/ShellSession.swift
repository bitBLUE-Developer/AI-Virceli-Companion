import Foundation
import AppKit
import Darwin

private enum PendingClaudeAction {
    case none
    case browserLogin
    case apiLogin
    case enterClaude
}

private enum ClaudeStreamEvent: Sendable {
    case stepStarted(String)
    case stepSucceeded(String)
    case stepFailed(String)
}

private final class ClaudeStreamState: @unchecked Sendable {
    let lock = NSLock()
    var buffer = ""
    var collectedText = ""
    var lastErrorMessage: String?
}

@MainActor
final class ShellSession: ObservableObject {
    private static let maxOutputCharacters = 120_000
    nonisolated private static let connectTimeoutNanoseconds: UInt64 = 8_000_000_000

    @Published var output: String = ""
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var errorMessage: String?
    @Published var claudeStage: ClaudeSessionStage = .disconnected
    @Published var workspacePath: String?
    @Published var messages: [ChatMessage] = []
    @Published var terminalEntries: [TerminalEntry] = []
    @Published var resumeSessions: [ClaudeResumeSession] = []
    @Published var isSendingPrompt: Bool = false
    @Published var isClaudeBubbleMode: Bool = false
    @Published var isClaudeStreaming: Bool = false
    @Published var claudeLiveSteps: [ClaudeLiveStep] = []
    @Published var claudeLivePreviewText: String = ""
    @Published var alwaysOnTop: Bool = false {
        didSet { updateWindowLevel() }
    }
    @Published var clickThrough: Bool = false {
        didSet { updateClickThrough() }
    }
    @Published var terminalFontName: String = "Menlo-Regular"
    @Published var terminalFontSize: Double = 13
    @Published var terminalInputTextColor: NSColor = .white
    @Published var terminalOutputTextColor: NSColor = .white
    @Published var terminalBackgroundColor: NSColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
    @Published var selectedPresetID: String = "afterglow"
    @Published var customThemeName: String = ""
    @Published var customThemes: [CustomTerminalTheme] = []
    @Published var inputHexDraft: String = "#FFFFFF"
    @Published var outputHexDraft: String = "#FFFFFF"
    @Published var backgroundHexDraft: String = "#141414"
    @Published var inputRGBDraft: String = "255,255,255"
    @Published var outputRGBDraft: String = "255,255,255"
    @Published var backgroundRGBDraft: String = "20,20,20"

    private var pty: PTYProcess?
    private var connectionAttemptID = UUID()
    private var pendingOutput = ""
    private var flushScheduled = false
    private var pendingAction: PendingClaudeAction = .none
    private var parseLineBuffer = ""
    private var currentCommand: String?
    private var currentOutputLines: [String] = []
    private var cachedClaudeExecutablePath: String?
    private static let workspaceDefaultsKey = "claude.workspace.path"
    private static let customThemesDefaultsKey = "terminal.custom.themes"
    private static let resumeSessionsDefaultsKey = "claude.resume.sessions"
    private static let terminalPresets: [TerminalPreset] = [
        TerminalPreset(id: "afterglow", name: "Afterglow", fontName: "Menlo-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.87, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.74, green: 0.78, blue: 0.79, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1)),
        TerminalPreset(id: "atomonelight", name: "Atom One Light", fontName: "SFMono-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.23, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.21, green: 0.24, blue: 0.28, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)),
        TerminalPreset(id: "alabaster", name: "Alabaster", fontName: "Menlo-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.12, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.20, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.90, alpha: 1)),
        TerminalPreset(id: "ayu", name: "ayu", fontName: "SFMono-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.86, green: 0.90, blue: 0.90, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.74, green: 0.78, blue: 0.78, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1)),
        TerminalPreset(id: "dracula", name: "Dracula", fontName: "Menlo-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.98, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.90, green: 0.89, blue: 0.94, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.21, alpha: 1)),
        TerminalPreset(id: "nord", name: "Nord", fontName: "SFMono-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.96, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.82, green: 0.87, blue: 0.91, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.25, alpha: 1)),
        TerminalPreset(id: "solarizeddark", name: "Solarized Dark", fontName: "Menlo-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.51, green: 0.58, blue: 0.59, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.40, green: 0.48, blue: 0.51, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.00, green: 0.17, blue: 0.21, alpha: 1)),
        TerminalPreset(id: "gruvboxdark", name: "Gruvbox Dark", fontName: "Courier", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.92, green: 0.86, blue: 0.70, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.83, green: 0.76, blue: 0.61, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.13, alpha: 1)),
        TerminalPreset(id: "onehalflight", name: "One Half Light", fontName: "SFMono-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.31, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.39, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.98, green: 0.99, blue: 0.99, alpha: 1)),
        TerminalPreset(id: "cobalt2", name: "Cobalt2", fontName: "Menlo-Regular", fontSize: 13, inputTextColor: NSColor(calibratedRed: 0.94, green: 0.94, blue: 0.96, alpha: 1), outputTextColor: NSColor(calibratedRed: 0.85, green: 0.88, blue: 0.92, alpha: 1), backgroundColor: NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.38, alpha: 1))
    ]

    init() {
        workspacePath = UserDefaults.standard.string(forKey: Self.workspaceDefaultsKey)
        loadCustomThemes()
        loadResumeSessions()
        applyPreset(id: selectedPresetID)
        syncColorDrafts()
    }

    var presets: [TerminalPreset] { Self.terminalPresets }

    var availableFonts: [String] {
        ["Menlo-Regular", "SFMono-Regular", "Courier", "Courier New", "Monaco", "Andale Mono"]
    }

    func applyPreset(id: String) {
        guard let preset = Self.terminalPresets.first(where: { $0.id == id }) else { return }
        selectedPresetID = id
        terminalFontName = preset.fontName
        terminalFontSize = preset.fontSize
        terminalInputTextColor = preset.inputTextColor
        terminalOutputTextColor = preset.outputTextColor
        terminalBackgroundColor = preset.backgroundColor
        syncColorDrafts()
    }

    func setTerminalFontName(_ name: String) {
        terminalFontName = name
    }

    func setTerminalFontSize(_ size: Double) {
        terminalFontSize = max(10, min(22, size))
    }

    func saveCurrentAsCustomTheme() {
        let name = customThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let theme = CustomTerminalTheme(
            id: UUID().uuidString,
            name: name,
            fontName: terminalFontName,
            fontSize: terminalFontSize,
            inputTextHex: terminalInputTextColor.hexRGB,
            outputTextHex: terminalOutputTextColor.hexRGB,
            backgroundHex: terminalBackgroundColor.hexRGB
        )
        customThemes.append(theme)
        saveCustomThemes()
        customThemeName = ""
    }

    func applyCustomTheme(id: String) {
        guard let theme = customThemes.first(where: { $0.id == id }) else { return }
        terminalFontName = theme.fontName
        terminalFontSize = theme.fontSize
        if let value = NSColor.fromHex(theme.inputTextHex) { terminalInputTextColor = value }
        if let value = NSColor.fromHex(theme.outputTextHex) { terminalOutputTextColor = value }
        if let value = NSColor.fromHex(theme.backgroundHex) { terminalBackgroundColor = value }
        syncColorDrafts()
    }

    func deleteCustomTheme(id: String) {
        customThemes.removeAll { $0.id == id }
        saveCustomThemes()
    }

    func clearResumeSessions() {
        resumeSessions.removeAll(keepingCapacity: false)
        saveResumeSessions()
    }

    func saveResumeSession(id: String) {
        saveResumeSession(id: id, label: nil)
    }

    func saveResumeSession(id: String, label: String?) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isLikelyResumeUUID(trimmed) else { return }
        let normalizedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingIndex = resumeSessions.firstIndex(where: { $0.id == trimmed }) {
            let existing = resumeSessions[existingIndex]
            resumeSessions.remove(at: existingIndex)
            let finalLabel = (normalizedLabel?.isEmpty == false) ? normalizedLabel : existing.label
            resumeSessions.insert(ClaudeResumeSession(id: trimmed, label: finalLabel, savedAt: Date()), at: 0)
        } else {
            let finalLabel = (normalizedLabel?.isEmpty == false) ? normalizedLabel : nil
            resumeSessions.insert(ClaudeResumeSession(id: trimmed, label: finalLabel, savedAt: Date()), at: 0)
        }
        if resumeSessions.count > 20 {
            resumeSessions.removeLast(resumeSessions.count - 20)
        }
        saveResumeSessions()
    }

    func saveResumeSession(fromCommand command: String) {
        guard let id = Self.extractResumeSessionID(from: command) else { return }
        saveResumeSession(id: id)
    }

    func deleteResumeSession(id: String) {
        resumeSessions.removeAll { $0.id == id }
        saveResumeSessions()
    }

    func clearResumeLabel(id: String) {
        guard let index = resumeSessions.firstIndex(where: { $0.id == id }) else { return }
        resumeSessions[index].label = nil
        saveResumeSessions()
    }

    func updateResumeLabel(id: String, label: String?) {
        guard let index = resumeSessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        resumeSessions[index].label = trimmed.isEmpty ? nil : trimmed
        saveResumeSessions()
    }

    func resolvedResumeID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLikelyResumeUUID(trimmed) {
            return trimmed
        }
        return Self.extractResumeSessionID(from: text)
    }

    func promptResumeLabel(for id: String) {
        guard let session = resumeSessions.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Set Resume Label"
        alert.informativeText = "Enter a session label. If left blank, the session ID will be shown."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = session.label ?? ""
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        updateResumeLabel(id: id, label: field.stringValue)
    }

    func saveResumeFromClipboardAndPrompt() {
        let value = clipboardString()
        guard let id = resolvedResumeID(from: value) else {
            errorMessage = "No resume ID found in clipboard"
            NSSound.beep()
            return
        }

        saveResumeSession(id: id)
        errorMessage = "resume id saved"

        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            self.promptResumeLabel(for: id)
        }
    }

    private func clipboardString() -> String {
        if let plain = NSPasteboard.general.string(forType: .string),
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plain
        }
        if let objects = NSPasteboard.general.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
           let first = objects.first {
            return first as String
        }
        return ""
    }

    func setTerminalInputTextColor(named name: String) {
        switch name {
        case "White": terminalInputTextColor = .white
        case "Black": terminalInputTextColor = .black
        case "Green": terminalInputTextColor = NSColor(calibratedRed: 0.47, green: 1.0, blue: 0.56, alpha: 1)
        case "Amber": terminalInputTextColor = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.28, alpha: 1)
        case "Blue": terminalInputTextColor = NSColor(calibratedRed: 0.78, green: 0.90, blue: 1.0, alpha: 1)
        case "Violet": terminalInputTextColor = NSColor(calibratedRed: 0.94, green: 0.86, blue: 1.0, alpha: 1)
        default: break
        }
        syncColorDrafts()
    }

    func setTerminalOutputTextColor(named name: String) {
        switch name {
        case "White": terminalOutputTextColor = .white
        case "Black": terminalOutputTextColor = .black
        case "Green": terminalOutputTextColor = NSColor(calibratedRed: 0.47, green: 1.0, blue: 0.56, alpha: 1)
        case "Amber": terminalOutputTextColor = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.28, alpha: 1)
        case "Blue": terminalOutputTextColor = NSColor(calibratedRed: 0.78, green: 0.90, blue: 1.0, alpha: 1)
        case "Violet": terminalOutputTextColor = NSColor(calibratedRed: 0.94, green: 0.86, blue: 1.0, alpha: 1)
        default: break
        }
        syncColorDrafts()
    }

    func setTerminalBackgroundColor(named name: String) {
        switch name {
        case "Black": terminalBackgroundColor = .black
        case "Midnight": terminalBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        case "Graphite": terminalBackgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        case "Paper": terminalBackgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1)
        case "Navy": terminalBackgroundColor = NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.16, alpha: 1)
        case "Purple": terminalBackgroundColor = NSColor(calibratedRed: 0.13, green: 0.08, blue: 0.18, alpha: 1)
        default: break
        }
        syncColorDrafts()
    }

    func color(for target: TerminalStyleTarget) -> NSColor {
        switch target {
        case .inputText:
            terminalInputTextColor
        case .outputText:
            terminalOutputTextColor
        case .background:
            terminalBackgroundColor
        }
    }

    func setColor(_ color: NSColor, for target: TerminalStyleTarget) {
        switch target {
        case .inputText:
            terminalInputTextColor = color
        case .outputText:
            terminalOutputTextColor = color
        case .background:
            terminalBackgroundColor = color
        }
        syncColorDrafts()
    }

    @discardableResult
    func setHexColor(_ value: String, for target: TerminalStyleTarget) -> Bool {
        guard let color = NSColor.fromHex(value) else { return false }
        setColor(color, for: target)
        return true
    }

    @discardableResult
    func setRGBColor(_ value: String, for target: TerminalStyleTarget) -> Bool {
        guard let color = NSColor.fromRGBString(value) else { return false }
        setColor(color, for: target)
        return true
    }

    func applyHexColors() {
        if let value = NSColor.fromHex(inputHexDraft) { terminalInputTextColor = value }
        if let value = NSColor.fromHex(outputHexDraft) { terminalOutputTextColor = value }
        if let value = NSColor.fromHex(backgroundHexDraft) { terminalBackgroundColor = value }
        syncColorDrafts()
    }

    func applyRGBColors() {
        if let value = NSColor.fromRGBString(inputRGBDraft) { terminalInputTextColor = value }
        if let value = NSColor.fromRGBString(outputRGBDraft) { terminalOutputTextColor = value }
        if let value = NSColor.fromRGBString(backgroundRGBDraft) { terminalBackgroundColor = value }
        syncColorDrafts()
    }

    func connect() {
        guard !isConnecting else { return }
        guard !isConnected else { return }
        guard ensureWorkspaceSelected() else { return }
        disconnect()
        let process = PTYProcess()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        pty = process
        isConnecting = true
        errorMessage = "starting shell..."
        claudeStage = .preparingShell
        terminalEntries.removeAll(keepingCapacity: true)
        parseLineBuffer = ""
        currentCommand = nil
        currentOutputLines.removeAll(keepingCapacity: true)

        process.onData = { [weak self] text in
            let cleaned = Self.stripANSIEscapeSequences(from: text)
            guard !cleaned.isEmpty else { return }
            DispatchQueue.main.async {
                self?.enqueueOutput(cleaned)
                self?.consumeReadableTerminal(cleaned)
                self?.consumeClaudeSignals(cleaned)
            }
        }
        process.onExit = { [weak self] code in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.isConnecting = false
                self?.errorMessage = "exited (\(code))"
            }
        }

        Task { [weak self, process] in
            do {
                try await Self.startWithTimeout(process, attemptID: attemptID) { [weak self] id in
                    await MainActor.run {
                        guard let self, self.connectionAttemptID == id, self.isConnecting else { return }
                        self.errorMessage = "connect timeout"
                        self.isConnecting = false
                        self.isConnected = false
                        self.connectionAttemptID = UUID()
                        self.pty?.terminate(force: true)
                        self.pty = nil
                    }
                }
                guard self?.connectionAttemptID == attemptID, self?.pty === process, self?.isConnecting == true else {
                    process.terminate()
                    return
                }
                self?.isConnected = true
                self?.isConnecting = false
                self?.errorMessage = "connected. choose login method."
                self?.claudeStage = .loginRequired
                self?.changeShellDirectoryToWorkspace()
                self?.runPendingActionIfNeeded()
            } catch {
                guard self?.connectionAttemptID == attemptID else { return }
                self?.isConnected = false
                self?.isConnecting = false
                self?.errorMessage = error.localizedDescription
                self?.pty = nil
                self?.claudeStage = .disconnected
            }
        }
    }

    func send(_ text: String) {
        guard let pty else { return }
        do {
            try pty.write(text)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitCommandFromUI(_ command: String) {
        let trimmed = command.trimmingCharacters(in: Self.extendedWhitespaceSet)
        guard !trimmed.isEmpty else { return }

        if trimmed == "claude" {
            isClaudeBubbleMode = true
            claudeStage = .running
            errorMessage = "Claude bubble mode on"
            appendTerminalEntry(
                command: "claude",
                output: "Switched from interactive Claude TUI to bubble mode. Next inputs run with `claude -p`. Use /exit to leave bubble mode.",
                isError: false,
                source: .tui
            )
            return
        }

        if isClaudeBubbleMode {
            if trimmed == "/exit" || trimmed == "exit" {
                isClaudeBubbleMode = false
                errorMessage = "Claude bubble mode off"
                appendTerminalEntry(command: trimmed, output: "Claude bubble mode exited", isError: false, source: .tui)
                return
            }
            runClaudePromptInBubble(trimmed)
            return
        }

        send(trimmed + "\r")
    }

    func disconnect() {
        connectionAttemptID = UUID()
        pty?.terminate(force: true)
        pty = nil
        isConnected = false
        isConnecting = false
        pendingOutput = ""
        flushScheduled = false
        pendingAction = .none
        claudeStage = .disconnected
        isSendingPrompt = false
        parseLineBuffer = ""
        currentCommand = nil
        currentOutputLines.removeAll(keepingCapacity: true)
    }

    func prepareClaudeFlow() {
        if !isConnected && !isConnecting {
            connect()
            return
        }
        guard isConnected else { return }
        if claudeStage == .disconnected || claudeStage == .preparingShell {
            claudeStage = .loginRequired
        }
    }

    func startBrowserLogin() {
        guard isConnected else {
            pendingAction = .browserLogin
            prepareClaudeFlow()
            return
        }
        pendingAction = .none
        claudeStage = .authenticating
        errorMessage = "waiting for Claude login..."
        if let url = URL(string: "https://claude.ai/login") {
            NSWorkspace.shared.open(url)
        }
        send("claude login\r")
    }

    func startAPILogin() {
        guard isConnected else {
            pendingAction = .apiLogin
            prepareClaudeFlow()
            return
        }
        pendingAction = .none
        claudeStage = .authenticating
        errorMessage = "waiting for API auth..."
        send("claude auth login\r")
    }

    func enterClaudeCode() {
        guard isConnected else {
            pendingAction = .enterClaude
            prepareClaudeFlow()
            return
        }
        pendingAction = .none
        claudeStage = .running
        errorMessage = "launching Claude Code..."
        send("claude\r")
    }

    func sendChatPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isSendingPrompt else { return }
        guard let workspacePath else {
            messages.append(ChatMessage(role: .system, text: "Workspace folder is not selected."))
            return
        }

        messages.append(ChatMessage(role: .user, text: trimmed))
        isSendingPrompt = true
        errorMessage = "Claude is generating response..."

        Task { [weak self] in
            do {
                let response = try await Self.runClaudePrintPrompt(prompt: trimmed, workspacePath: workspacePath)
                await MainActor.run {
                    self?.isSendingPrompt = false
                    let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        self?.messages.append(ChatMessage(role: .system, text: "No response returned."))
                    } else {
                        self?.messages.append(ChatMessage(role: .assistant, text: text))
                        self?.claudeStage = .readyToLaunch
                        self?.errorMessage = "response received"
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isSendingPrompt = false
                    self?.messages.append(ChatMessage(role: .system, text: "Claude request failed: \(error.localizedDescription)"))
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func trustWorkspaceYes() {
        guard isConnected else { return }
        errorMessage = "trusting workspace..."
        claudeStage = .authenticating
        send("1\r")
    }

    func trustWorkspaceNo() {
        guard isConnected else { return }
        errorMessage = "cancelling trust prompt..."
        claudeStage = .loginRequired
        send("2\r")
    }

    @discardableResult
    func selectWorkspaceFolder() -> Bool {
        ensureWorkspaceSelected(forcePrompt: true)
    }

    @discardableResult
    func ensureWorkspaceSelectedForStartup() -> Bool {
        ensureWorkspaceSelected()
    }

    func checkClaudeAuthStatus() async -> Bool {
        guard let workspacePath else { return false }
        do {
            let result = try await Self.runShellCommand(
                command: "cd \(Self.shellQuoted(workspacePath)) && claude auth status"
            )
            let lower = result.output.lowercased()
            if lower.contains("not logged in") || lower.contains("login required") {
                return false
            }
            if lower.contains("logged in")
                || lower.contains("authenticated")
                || lower.contains("claude pro")
                || lower.contains("organization") {
                return true
            }
            return result.status == 0
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func resetWindowInteraction() {
        if let window = NSApplication.shared.windows.first {
            window.ignoresMouseEvents = false
            window.makeKeyAndOrderFront(nil)
        }
        clickThrough = false
    }

    func clearWorkspaceSelection() {
        workspacePath = nil
        UserDefaults.standard.removeObject(forKey: Self.workspaceDefaultsKey)
        errorMessage = "workspace selection cleared"
        claudeStage = .disconnected
    }

    private func ensureWorkspaceSelected(forcePrompt: Bool = false) -> Bool {
        if !forcePrompt, workspacePath != nil {
            return true
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select the root folder where Claude Code should start."
        panel.directoryURL = workspacePath.map(URL.init(fileURLWithPath:))

        let response = panel.runModal()
        guard response == .OK, let selectedURL = panel.url else {
            errorMessage = "workspace selection cancelled"
            claudeStage = .disconnected
            return false
        }

        let path = selectedURL.path
        workspacePath = path
        UserDefaults.standard.set(path, forKey: Self.workspaceDefaultsKey)
        errorMessage = "workspace set: \(selectedURL.lastPathComponent)"
        return true
    }

    private func changeShellDirectoryToWorkspace() {
        guard let workspacePath else { return }
        send("cd \(Self.shellQuoted(workspacePath))\r")
        send("pwd\r")
    }

    private func syncColorDrafts() {
        inputHexDraft = terminalInputTextColor.hexRGB
        outputHexDraft = terminalOutputTextColor.hexRGB
        backgroundHexDraft = terminalBackgroundColor.hexRGB
        inputRGBDraft = terminalInputTextColor.rgbString
        outputRGBDraft = terminalOutputTextColor.rgbString
        backgroundRGBDraft = terminalBackgroundColor.rgbString
    }

    private func loadCustomThemes() {
        guard let data = UserDefaults.standard.data(forKey: Self.customThemesDefaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([CustomTerminalTheme].self, from: data) else { return }
        customThemes = decoded
    }

    private func saveCustomThemes() {
        guard let data = try? JSONEncoder().encode(customThemes) else { return }
        UserDefaults.standard.set(data, forKey: Self.customThemesDefaultsKey)
    }

    private func loadResumeSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.resumeSessionsDefaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([ClaudeResumeSession].self, from: data) else { return }
        resumeSessions = decoded.sorted { $0.savedAt > $1.savedAt }
    }

    private func saveResumeSessions() {
        guard let data = try? JSONEncoder().encode(resumeSessions) else { return }
        UserDefaults.standard.set(data, forKey: Self.resumeSessionsDefaultsKey)
    }

    private func captureResumeSessionIfPresent(in line: String) {
        guard let sessionID = Self.extractResumeSessionID(from: line) else { return }
        saveResumeSession(id: sessionID)
    }

    private func consumeClaudeSignals(_ text: String) {
        let lower = text.lowercased()

        if lower.contains("quick safety check") || lower.contains("enter to confirm") {
            errorMessage = "workspace trust confirmation required"
            claudeStage = .trustPrompt
            return
        }

        if lower.contains("not logged in") || lower.contains("login required") || lower.contains("run `claude login`") {
            if claudeStage != .running {
                claudeStage = .loginRequired
            }
            return
        }

        if lower.contains("logged in")
            || lower.contains("authentication successful")
            || lower.contains("successfully authenticated")
            || lower.contains("successfully logged in") {
            if claudeStage != .running {
                claudeStage = .readyToLaunch
                messages.append(ChatMessage(role: .system, text: "Login successful. You can start chatting now."))
            }
            return
        }

        if lower.contains("quick safety check")
            || lower.contains("accessing workspace")
            || lower.contains("claude code") {
            claudeStage = .running
            errorMessage = "claude code ready"
        }
    }

    private func runPendingActionIfNeeded() {
        switch pendingAction {
        case .none:
            return
        case .browserLogin:
            pendingAction = .none
            startBrowserLogin()
        case .apiLogin:
            pendingAction = .none
            startAPILogin()
        case .enterClaude:
            pendingAction = .none
            enterClaudeCode()
        }
    }

    private func consumeReadableTerminal(_ text: String) {
        parseLineBuffer += text
        let normalized = parseLineBuffer.replacingOccurrences(of: "\r\n", with: "\n")
        let segments = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        guard !segments.isEmpty else { return }
        let completedCount = normalized.hasSuffix("\n") ? segments.count : max(segments.count - 1, 0)

        for idx in 0..<completedCount {
            consumeReadableLine(String(segments[idx]))
        }

        if normalized.hasSuffix("\n") {
            parseLineBuffer = ""
        } else if let last = segments.last {
            parseLineBuffer = String(last)
        }
    }

    private func consumeReadableLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: Self.extendedWhitespaceSet)
        guard !trimmed.isEmpty else { return }
        captureResumeSessionIfPresent(in: trimmed)

        if let commandFromPrompt = Self.extractPromptCommand(from: trimmed) {
            finalizeCurrentEntryIfNeeded()
            if !commandFromPrompt.isEmpty {
                currentCommand = commandFromPrompt
            }
            return
        }

        currentOutputLines.append(trimmed)
    }

    private func finalizeCurrentEntryIfNeeded() {
        let output = currentOutputLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            currentOutputLines.removeAll(keepingCapacity: true)
            currentCommand = nil
        }

        guard let command = currentCommand, !command.isEmpty else { return }
        let finalOutput = output.isEmpty ? "(no output)" : output
        let lower = finalOutput.lowercased()
        let isError = lower.contains("error") || lower.contains("not found") || lower.contains("failed")
        appendTerminalEntry(command: command, output: finalOutput, isError: isError, source: .terminal)
    }

    private func runClaudePromptInBubble(_ prompt: String) {
        guard let workspacePath else {
            appendTerminalEntry(command: prompt, output: "Workspace folder is not selected.", isError: true, source: .tui)
            return
        }
        guard !isSendingPrompt else { return }

        isSendingPrompt = true
        isClaudeStreaming = true
        claudeLiveSteps.removeAll(keepingCapacity: true)
        claudeLivePreviewText = ""
        errorMessage = "Generating Claude response..."
        let commandLabel = prompt

        Task { [weak self] in
            guard let self else { return }
            do {
                let claudeExecutable = try await self.resolveClaudeExecutablePathCached()
                let response = try await Self.runClaudeStreamingPrompt(
                    prompt: prompt,
                    workspacePath: workspacePath,
                    claudeExecutable: claudeExecutable,
                    onEvent: { [weak self] event in
                        guard let self else { return }
                        Task { @MainActor in
                            self.consumeLiveClaudeEvent(event)
                        }
                    },
                    onText: { [weak self] chunk in
                        guard let self else { return }
                        Task { @MainActor in
                            self.claudeLivePreviewText += chunk
                        }
                    }
                )
                await MainActor.run {
                    self.isSendingPrompt = false
                    self.isClaudeStreaming = false
                    self.finalizeRunningStepsAsSuccess()
                    let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.appendTerminalEntry(
                        command: commandLabel,
                        output: cleaned.isEmpty ? "(no output)" : cleaned,
                        isError: false,
                        source: .tui
                    )
                    self.errorMessage = "response received"
                    self.claudeLivePreviewText = ""
                }
            } catch {
                await MainActor.run {
                    self.isSendingPrompt = false
                    self.isClaudeStreaming = false
                    self.markLatestRunningStepFailedIfNeeded()
                    self.appendTerminalEntry(
                        command: commandLabel,
                        output: error.localizedDescription,
                        isError: true,
                        source: .tui
                    )
                    self.errorMessage = error.localizedDescription
                    self.claudeLivePreviewText = ""
                }
            }
        }
    }

    private func appendTerminalEntry(command: String, output: String, isError: Bool, source: TerminalEntrySource) {
        terminalEntries.append(TerminalEntry(command: command, output: output, isError: isError, source: source))
        if terminalEntries.count > 150 {
            terminalEntries.removeFirst(terminalEntries.count - 150)
        }
    }

    private func consumeLiveClaudeEvent(_ event: ClaudeStreamEvent) {
        switch event {
        case let .stepStarted(title):
            startLiveStep(title)
        case let .stepSucceeded(title):
            completeLiveStep(title, success: true)
        case let .stepFailed(title):
            completeLiveStep(title, success: false)
        }
    }

    private func startLiveStep(_ title: String) {
        guard !title.isEmpty else { return }
        if let index = claudeLiveSteps.lastIndex(where: { $0.title == title && $0.status == .running }) {
            claudeLiveSteps[index].status = .running
            return
        }
        claudeLiveSteps.append(ClaudeLiveStep(title: title, status: .running))
    }

    private func completeLiveStep(_ title: String, success: Bool) {
        if let index = claudeLiveSteps.lastIndex(where: { $0.title == title }) {
            claudeLiveSteps[index].status = success ? .success : .failure
            return
        }
        claudeLiveSteps.append(ClaudeLiveStep(title: title, status: success ? .success : .failure))
    }

    private func markLatestRunningStepFailedIfNeeded() {
        if let index = claudeLiveSteps.lastIndex(where: { $0.status == .running }) {
            claudeLiveSteps[index].status = .failure
        }
    }

    private func finalizeRunningStepsAsSuccess() {
        for index in claudeLiveSteps.indices where claudeLiveSteps[index].status == .running {
            claudeLiveSteps[index].status = .success
        }
    }

    private func resolveClaudeExecutablePathCached() async throws -> String {
        if let cachedClaudeExecutablePath {
            return cachedClaudeExecutablePath
        }
        let resolved = try await Self.resolveClaudeExecutablePath()
        cachedClaudeExecutablePath = resolved
        return resolved
    }

    nonisolated private static func runClaudePrintPrompt(prompt: String, workspacePath: String) async throws -> String {
        let claudeExecutable = try await resolveClaudeExecutablePath()
        return try await runClaudePrintPrompt(prompt: prompt, workspacePath: workspacePath, claudeExecutable: claudeExecutable)
    }

    nonisolated private static func runClaudePrintPrompt(
        prompt: String,
        workspacePath: String,
        claudeExecutable: String
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")

            let command = "cd \(shellQuoted(workspacePath)) && \(shellQuoted(claudeExecutable)) -p \(shellQuoted(prompt))"
            process.arguments = ["-ilc", command]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            process.terminationHandler = { proc in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let cleaned = stripANSIEscapeSequences(from: text)
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: cleaned)
                } else {
                    let message = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: NSError(
                        domain: "ClaudePrompt",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "claude exited with \(proc.terminationStatus)" : message]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func runShellCommand(command: String) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", command]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            process.terminationHandler = { proc in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, stripANSIEscapeSequences(from: text)))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func runClaudeStreamingPrompt(
        prompt: String,
        workspacePath: String,
        claudeExecutable: String,
        onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let state = ClaudeStreamState()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")

            let command = """
            cd \(shellQuoted(workspacePath)) && \(shellQuoted(claudeExecutable)) -p --output-format stream-json --include-partial-messages \(shellQuoted(prompt))
            """
            process.arguments = ["-ilc", command]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            let handle = outputPipe.fileHandleForReading
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                processStreamChunk(
                    chunk,
                    state: state,
                    onEvent: onEvent,
                    onText: onText
                )
            }

            process.terminationHandler = { proc in
                handle.readabilityHandler = nil
                let remainingData = handle.readDataToEndOfFile()
                let remaining = String(data: remainingData, encoding: .utf8) ?? ""
                if !remaining.isEmpty {
                    processStreamChunk(
                        remaining,
                        state: state,
                        onEvent: onEvent,
                        onText: onText
                    )
                }
                flushRemainingStreamLine(state: state, onEvent: onEvent, onText: onText)

                state.lock.lock()
                let output = state.collectedText
                let message = state.lastErrorMessage
                state.lock.unlock()

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "ClaudePrompt",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message ?? "claude exited with \(proc.terminationStatus)"]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func resolveClaudeExecutablePath() async throws -> String {
        if let discovered = try await discoverClaudePathViaShell() {
            return discovered
        }

        let home = NSHomeDirectory()
        let fallbackCandidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/bin/claude"
        ]

        if let existing = fallbackCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return existing
        }

        throw NSError(
            domain: "ClaudePrompt",
            code: 127,
            userInfo: [NSLocalizedDescriptionKey: "claude command not found. Install Claude Code CLI or ensure PATH includes it."]
        )
    }

    nonisolated private static func processStreamChunk(
        _ chunk: String,
        state: ClaudeStreamState,
        onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void,
        onText: @escaping @Sendable (String) -> Void
    ) {
        state.lock.lock()
        state.buffer += chunk
        var lines: [String] = []
        while let newlineIndex = state.buffer.firstIndex(of: "\n") {
            let line = String(state.buffer[..<newlineIndex])
            state.buffer.removeSubrange(...newlineIndex)
            lines.append(line)
        }
        state.lock.unlock()

        for line in lines {
            processStreamLine(line, state: state, onEvent: onEvent, onText: onText)
        }
    }

    nonisolated private static func flushRemainingStreamLine(
        state: ClaudeStreamState,
        onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void,
        onText: @escaping @Sendable (String) -> Void
    ) {
        state.lock.lock()
        let remaining = state.buffer
        state.buffer = ""
        state.lock.unlock()

        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            processStreamLine(remaining, state: state, onEvent: onEvent, onText: onText)
        }
    }

    nonisolated private static func processStreamLine(
        _ line: String,
        state: ClaudeStreamState,
        onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void,
        onText: @escaping @Sendable (String) -> Void
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let event = parseClaudeStreamEvent(from: trimmed) {
            onEvent(event)
        }

        if let text = extractClaudeStreamText(from: trimmed), !text.isEmpty {
            state.lock.lock()
            state.collectedText += text
            state.lock.unlock()
            onText(text)
        }

        if let errorMessage = extractClaudeStreamError(from: trimmed), !errorMessage.isEmpty {
            state.lock.lock()
            state.lastErrorMessage = errorMessage
            state.lock.unlock()
        }
    }

    nonisolated private static func parseClaudeStreamEvent(from jsonLine: String) -> ClaudeStreamEvent? {
        guard
            let data = jsonLine.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return nil
        }

        let type = (dict["type"] as? String)?.lowercased() ?? ""
        let subtype = (dict["subtype"] as? String)?.lowercased() ?? ""

        if type == "error" {
            return .stepFailed("Request")
        }

        if type.contains("tool_use") || subtype.contains("tool_use") {
            let name = (dict["tool_name"] as? String) ?? (dict["name"] as? String) ?? "Tool"
            return .stepStarted(name)
        }

        if type.contains("tool_result") || subtype.contains("tool_result") {
            let name = (dict["tool_name"] as? String) ?? (dict["name"] as? String) ?? "Tool"
            let isError = dict["is_error"] as? Bool ?? false
            return isError ? .stepFailed(name) : .stepSucceeded(name)
        }

        if type == "message_start" {
            return .stepStarted("Thinking")
        }

        if type == "message_stop" || type == "result" {
            return .stepSucceeded("Thinking")
        }

        return nil
    }

    nonisolated private static func extractClaudeStreamText(from jsonLine: String) -> String? {
        guard
            let data = jsonLine.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return nil
        }

        if let text = dict["text"] as? String {
            return text
        }

        if
            let delta = dict["delta"] as? [String: Any],
            let text = delta["text"] as? String {
            return text
        }

        if
            let message = dict["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined()
        }

        if let result = dict["result"] as? String {
            return result
        }

        return nil
    }

    nonisolated private static func extractClaudeStreamError(from jsonLine: String) -> String? {
        guard
            let data = jsonLine.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return nil
        }

        let type = (dict["type"] as? String)?.lowercased() ?? ""
        guard type == "error" else { return nil }
        return (dict["message"] as? String) ?? (dict["error"] as? String)
    }

    nonisolated private static func discoverClaudePathViaShell() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", "command -v claude 2>/dev/null || true"]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            process.terminationHandler = { proc in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                let candidate = text
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty && $0.hasSuffix("claude") })

                if proc.terminationStatus == 0 || proc.terminationStatus == 1 {
                    continuation.resume(returning: candidate)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "ClaudePrompt",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "failed to resolve claude executable path"]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func updateWindowLevel() {
        guard let window = NSApplication.shared.windows.first else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }

    private func updateClickThrough() {
        guard let window = NSApplication.shared.windows.first else { return }
        window.ignoresMouseEvents = clickThrough
    }

    private func appendOutput(_ incoming: String) {
        output += incoming
        let overflow = output.count - Self.maxOutputCharacters
        guard overflow > 0 else { return }
        output.removeFirst(overflow)
    }

    private func enqueueOutput(_ incoming: String) {
        pendingOutput += incoming
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.pendingOutput.isEmpty else { return }
            let chunk = self.pendingOutput
            self.pendingOutput.removeAll(keepingCapacity: true)
            self.appendOutput(chunk)
        }
    }

    nonisolated private static func startProcessInBackground(_ process: PTYProcess) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.start()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func startWithTimeout(
        _ process: PTYProcess,
        attemptID: UUID,
        onTimeout: @escaping @Sendable (UUID) async -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await startProcessInBackground(process)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: connectTimeoutNanoseconds)
                await onTimeout(attemptID)
            }
            guard try await group.next() != nil else { return }
            group.cancelAll()
        }
    }

    nonisolated private static func stripANSIEscapeSequences(from text: String) -> String {
        var cleaned = text

        // CSI sequences, e.g. ESC[?2004h
        cleaned = cleaned.replacingOccurrences(
            of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
        // OSC sequences, e.g. ESC]...BEL or ESC]...ESC\
        cleaned = cleaned.replacingOccurrences(
            of: #"\u{001B}\][^\u{0007}\u{001B}]*(\u{0007}|\u{001B}\\)"#,
            with: "",
            options: .regularExpression
        )
        // Incomplete CSI fragments that may be split across chunks
        cleaned = cleaned.replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*"#,
            with: "",
            options: .regularExpression
        )
        // Generic ESC-prefixed leftovers
        cleaned = cleaned.replacingOccurrences(
            of: #"\u{001B}[^\n\r\t]*"#,
            with: "",
            options: .regularExpression
        )
        // Cursor-forward remnants when ESC was stripped before parsing, e.g. [1C
        cleaned = cleaned.replacingOccurrences(
            of: #"\[(?:\?|[0-9])[0-9;]*C"#,
            with: " ",
            options: .regularExpression
        )
        // Generic bracketed ANSI remnants, e.g. [?2004h, [?2026l
        cleaned = cleaned.replacingOccurrences(
            of: #"\[(?:\?|[0-9])[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
        // Remove other control characters except line breaks and tab
        cleaned = cleaned.replacingOccurrences(
            of: #"[^\P{Cc}\n\r\t]"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "")
        cleaned = cleaned.replacingOccurrences(
            of: #" {2,}"#,
            with: " ",
            options: .regularExpression
        )

        return cleaned
    }

    nonisolated private static func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    nonisolated private static func extractPromptCommand(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: extendedWhitespaceSet)

        if trimmed.hasPrefix("❯") {
            let raw = String(trimmed.dropFirst())
            return raw.trimmingCharacters(in: extendedWhitespaceSet)
        }

        if trimmed.hasPrefix("% ") {
            guard let promptSeparator = trimmed.range(of: " % ", options: .backwards) else { return nil }
            return String(trimmed[promptSeparator.upperBound...]).trimmingCharacters(in: extendedWhitespaceSet)
        }

        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("# ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: extendedWhitespaceSet)
        }

        return nil
    }

    nonisolated private static func extractResumeSessionID(from line: String) -> String? {
        let pattern = #"claude\s+--resume\s+([0-9a-fA-F-]{36})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        let idRange = match.range(at: 1)
        guard let swiftRange = Range(idRange, in: line) else { return nil }
        return String(line[swiftRange])
    }

    nonisolated private static func isLikelyResumeUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    nonisolated private static var extendedWhitespaceSet: CharacterSet {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{00A0}\u{2007}\u{202F}")
        return set
    }
}

extension NSColor {
    var hexRGB: String {
        let color = usingColorSpace(.deviceRGB) ?? self
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var rgbString: String {
        let color = usingColorSpace(.deviceRGB) ?? self
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        return "\(r),\(g),\(b)"
    }

    static func fromHex(_ value: String) -> NSColor? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let intValue = Int(hex, radix: 16) else { return nil }
        let r = CGFloat((intValue >> 16) & 0xFF) / 255
        let g = CGFloat((intValue >> 8) & 0xFF) / 255
        let b = CGFloat(intValue & 0xFF) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    static func fromRGBString(_ value: String) -> NSColor? {
        let parts = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 3 else { return nil }
        guard
            let r = Int(parts[0]), let g = Int(parts[1]), let b = Int(parts[2]),
            (0...255).contains(r), (0...255).contains(g), (0...255).contains(b)
        else { return nil }

        return NSColor(
            calibratedRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}

final class PTYProcess: @unchecked Sendable {
    var onData: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private let readQueue = DispatchQueue(label: "pty.read.queue")
    private let waitQueue = DispatchQueue(label: "pty.wait.queue")
    private let killQueue = DispatchQueue(label: "pty.kill.queue")
    private var readSource: DispatchSourceRead?

    func start() throws {
        var master: Int32 = -1
        var slave: Int32 = -1

        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            if slave >= 0 {
                close(slave)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var spawnAttributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&spawnAttributes) == 0 else {
            close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { posix_spawnattr_destroy(&spawnAttributes) }

#if os(macOS)
        _ = posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETSID))
#endif

        var ttyPathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard ttyname_r(slave, &ttyPathBuffer, ttyPathBuffer.count) == 0 else {
            close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        try ttyPathBuffer.withUnsafeBufferPointer { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
            try Self.posixCheck(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    baseAddress,
                    O_RDWR,
                    mode_t(0)
                )
            )
        }
        try Self.posixCheck(posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDOUT_FILENO))
        try Self.posixCheck(posix_spawn_file_actions_adddup2(&fileActions, STDIN_FILENO, STDERR_FILENO))
        try Self.posixCheck(posix_spawn_file_actions_addclose(&fileActions, master))
        try Self.posixCheck(posix_spawn_file_actions_addclose(&fileActions, slave))

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let shellArg0 = strdup(shell), let interactiveArg = strdup("-i") else {
            close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer {
            free(shellArg0)
            free(interactiveArg)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [shellArg0, interactiveArg, nil]
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, shellArg0, &fileActions, &spawnAttributes, buffer.baseAddress, environ)
        }

        if spawnResult != 0 {
            close(master)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnResult))
        }

        // Parent
        childPID = pid
        masterFD = master
        let currentFlags = fcntl(masterFD, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(masterFD, F_SETFL, currentFlags | O_NONBLOCK)
        }
        slave = -1
        startReadLoop()
        startWaitLoop()
    }

    func write(_ text: String) throws {
        guard masterFD >= 0 else { return }
        guard let data = text.data(using: .utf8) else { return }
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = data.count
            var attempts = 0

            while remaining > 0 {
                let written = Darwin.write(masterFD, base, remaining)
                if written > 0 {
                    remaining -= written
                    base += written
                    attempts = 0
                    continue
                }

                if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && attempts < 40 {
                    attempts += 1
                    usleep(5_000)
                    continue
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    func terminate(force: Bool = false) {
        readSource?.cancel()
        readSource = nil

        if childPID > 0 {
            let pid = childPID
            if force {
                killQueue.asyncAfter(deadline: .now() + .milliseconds(150)) {
                    if kill(pid, 0) == 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
            kill(pid, SIGTERM)
            childPID = 0
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    private func startReadLoop() {
        let fd = masterFD
        let onData = self.onData
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var pending = ""

            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer[0..<count])
                    if let text = String(data: data, encoding: .utf8) {
                        pending += text
                    }
                    continue
                }

                if count == 0 {
                    source.cancel()
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    source.cancel()
                }
                break
            }

            if !pending.isEmpty {
                onData?(pending)
            }
        }
        source.setCancelHandler { }
        readSource = source
        source.resume()
    }

    private func startWaitLoop() {
        let pid = childPID
        let onExit = self.onExit
        waitQueue.async {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            onExit?(Self.exitCode(from: status))
        }
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let terminatedBySignal = (status & 0x7f) != 0
        if terminatedBySignal {
            return -1
        }
        return (status >> 8) & 0xff
    }

    private static func posixCheck(_ code: Int32) throws {
        guard code == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
}
