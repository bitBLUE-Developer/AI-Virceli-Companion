import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    static let avatarProfileDidChange = Notification.Name("avatar.profile.did.change")
    static let virceliSelectFolder = Notification.Name("virceli.menu.select.folder")
    static let virceliLaunchTUI = Notification.Name("virceli.menu.launch.tui")
    static let virceliStopTUI = Notification.Name("virceli.menu.stop.tui")
    static let virceliToggleAlwaysOnTop = Notification.Name("virceli.menu.toggle.always.on.top")
    static let virceliToggleClickThrough = Notification.Name("virceli.menu.toggle.click.through")
    static let virceliResetSavedPaths = Notification.Name("virceli.menu.reset.saved.paths")
    static let virceliResetCamera = Notification.Name("virceli.menu.reset.camera")
    static let virceliLaunchApp = Notification.Name("virceli.menu.launch.app")
    static let virceliStopApp = Notification.Name("virceli.menu.stop.app")
    static let virceliSelectApp = Notification.Name("virceli.menu.select.app")
    static let virceliToggleAttach = Notification.Name("virceli.menu.toggle.attach")
    static let virceliDockLeft = Notification.Name("virceli.menu.dock.left")
    static let virceliDockRight = Notification.Name("virceli.menu.dock.right")
    static let virceliNewSession = Notification.Name("virceli.menu.new.session")
    static let virceliSaveResumeFromClipboard = Notification.Name("virceli.menu.save.resume.clipboard")
    static let virceliResumeRun = Notification.Name("virceli.menu.resume.run")
    static let virceliResumeEditLabel = Notification.Name("virceli.menu.resume.edit.label")
    static let virceliResumeDelete = Notification.Name("virceli.menu.resume.delete")
    static let virceliResumeClearAll = Notification.Name("virceli.menu.resume.clear.all")
}

enum OverlayPanel: String {
    case none
    case terminal
    case system
    case monitor
}

enum TerminalStyleEditorModal: String, Identifiable {
    case inputText
    case outputText
    case background

    var id: String { rawValue }
}

enum EntryTab: String, CaseIterable {
    case terminal = "Terminal"
    case tui = "TUI"
}

enum TUIStylePreset: String, CaseIterable {
    case classic
    case studio
    case glass
    case noir
    case neon
    case paper
    case sunset
}

enum StartupFlowState: String {
    case idle
    case selectingWorkspace
    case checkingAuth
    case launchingTUI
    case ready
    case failed
}

enum CompanionVisualState {
    case idle
    case working
    case listening
    case error
}

private enum VirceliMenuCommand {
    case selectFolder
    case launchTUI
    case stopTUI
    case toggleAlwaysOnTop
    case toggleClickThrough
    case resetSavedPaths
    case resetCamera
    case launchApp
    case stopApp
    case selectApp
    case toggleAttach
    case dockLeft
    case dockRight
    case newSession
    case saveResumeFromClipboard
    case resumeRun(String)
    case resumeEditLabel(String)
    case resumeDelete(String)
    case resumeClearAll
}

struct RootView: View {
    @EnvironmentObject var shell: ShellSession
    @StateObject var avatarBridge = AvatarEventBridge()
    @StateObject var unityRuntime = UnityRuntimeManager()
    @StateObject var runtimeMonitor = RuntimeMonitor()
    @State var panel: OverlayPanel = .none
    @State var prompt: String = ""
    @State var showRawLog: Bool = false
    @State var selectedCustomThemeID: String = ""
    @State var activeStyleEditor: TerminalStyleEditorModal?
    @State var activeEntryTab: EntryTab = .terminal
    @State var tuiLaunchID = UUID()
    @State var tuiLaunchCommand = "claude"
    @State var tuiShouldLaunch = false
    @State var didRunStartupFlow = false
    @State var startupFlowState: StartupFlowState = .idle
    @State var lastSentUnityPanelSize: CGSize = .zero
    @State var unityPanelSize: CGSize = .zero
    @State var unityRunMemory: Int = 0
    @State var unityAvatarState: String = "idle"
    @State var tuiOutputLineBurstCount = 0
    @State var tuiOutputBurstStart = Date.distantPast
    @State var didSendGreetingThisRun = false
    @State var talkingCooldownTask: Task<Void, Never>?
    @State var thinkingCooldownTask: Task<Void, Never>?
    @State var avatarStateLockUntil = Date.distantPast
    @State var avatarReturnToIdleTask: Task<Void, Never>?
    @State var showAvatarSetupWizard = false
    let unityAutoStart: Bool = false
    @AppStorage("avatar.engine") var avatarEngineRawValue: String = AvatarEngine.unity.rawValue
    @AppStorage("ui.tui.style.preset") var tuiStyleRawValue: String = TUIStylePreset.studio.rawValue
    @AppStorage("ui.terminal.card.width") var terminalCardWidth: Double = 1000
    @AppStorage("ui.terminal.output.height") var terminalOutputHeight: Double = 360
    @AppStorage("ui.terminal.raw.height") var terminalRawHeight: Double = 180
    @AppStorage("unity.camera.zoom") var unityCameraZoom: Double = 1.0
    @AppStorage("unity.camera.panX") var unityCameraPanX: Double = 0.0
    @AppStorage("unity.camera.panY") var unityCameraPanY: Double = 0.0
    @AppStorage("unity.camera.orbitX") var unityCameraOrbitX: Double = 0.0
    @AppStorage("unity.camera.orbitY") var unityCameraOrbitY: Double = 0.0
    @State var isCardResizing = false
    @State var cardResizeStartWidth: Double = 1000
    @State var cardResizeStartOutputHeight: Double = 360
    @State var isOutputResizing = false
    @State var outputResizeStartHeight: Double = 360
    @State var isRawResizing = false
    @State var rawResizeStartHeight: Double = 180
    @FocusState var promptFocused: Bool
    let showConnectControls = false
    let showTerminalPanelButton = false

    private var inputBubbleFillColor: Color {
        let input = shell.terminalInputTextColor.usingColorSpace(.deviceRGB) ?? shell.terminalInputTextColor
        let base = shell.terminalBackgroundColor.usingColorSpace(.deviceRGB) ?? shell.terminalBackgroundColor
        return Color(base.blended(withFraction: 0.18, of: input) ?? input)
    }

    private var outputBubbleFillColor: Color {
        let output = shell.terminalOutputTextColor.usingColorSpace(.deviceRGB) ?? shell.terminalOutputTextColor
        let base = shell.terminalBackgroundColor.usingColorSpace(.deviceRGB) ?? shell.terminalBackgroundColor
        return Color(base.blended(withFraction: 0.12, of: output) ?? output)
    }

    private var filteredEntries: [TerminalEntry] {
        shell.terminalEntries.filter { entry in
            switch activeEntryTab {
            case .terminal:
                return entry.source == .terminal
            case .tui:
                return entry.source == .tui
            }
        }
    }

    private var tuiStylePreset: TUIStylePreset {
        TUIStylePreset(rawValue: tuiStyleRawValue) ?? .studio
    }

    private var tuiContainerBackground: Color {
        switch tuiStylePreset {
        case .classic:
            return .black.opacity(0.95)
        case .studio:
            return Color(red: 0.05, green: 0.08, blue: 0.14).opacity(0.95)
        case .glass:
            return .white.opacity(0.16)
        case .noir:
            return Color(red: 0.03, green: 0.03, blue: 0.04).opacity(0.97)
        case .neon:
            return Color(red: 0.01, green: 0.08, blue: 0.06).opacity(0.95)
        case .paper:
            return Color(red: 0.95, green: 0.94, blue: 0.90).opacity(0.96)
        case .sunset:
            return Color(red: 0.15, green: 0.07, blue: 0.06).opacity(0.95)
        }
    }

    private var tuiContainerStroke: Color {
        switch tuiStylePreset {
        case .classic:
            return .white.opacity(0.14)
        case .studio:
            return .cyan.opacity(0.42)
        case .glass:
            return .white.opacity(0.50)
        case .noir:
            return .white.opacity(0.10)
        case .neon:
            return .green.opacity(0.44)
        case .paper:
            return .black.opacity(0.20)
        case .sunset:
            return .orange.opacity(0.45)
        }
    }

    private var tuiInnerPadding: CGFloat {
        switch tuiStylePreset {
        case .classic:
            return 0
        case .studio:
            return 6
        case .glass:
            return 10
        case .noir:
            return 4
        case .neon:
            return 8
        case .paper:
            return 8
        case .sunset:
            return 6
        }
    }

    private var tuiShadowColor: Color {
        switch tuiStylePreset {
        case .classic:
            return .clear
        case .studio:
            return .blue.opacity(0.26)
        case .glass:
            return .white.opacity(0.20)
        case .noir:
            return .black.opacity(0.35)
        case .neon:
            return .green.opacity(0.30)
        case .paper:
            return .black.opacity(0.10)
        case .sunset:
            return .orange.opacity(0.26)
        }
    }

    private var companionStateText: String {
        if startupFlowState == .checkingAuth || startupFlowState == .launchingTUI {
            return "Preparing"
        }
        if shell.isConnecting {
            return "Connecting"
        }
        if activeEntryTab == .tui {
            return "Listening"
        }
        return "Idle"
    }

    private var companionVisualState: CompanionVisualState {
        if startupFlowState == .failed {
            return .error
        }
        if let error = shell.errorMessage?.lowercased(), error.contains("error") || error.contains("failed") {
            return .error
        }
        if startupFlowState == .checkingAuth || startupFlowState == .launchingTUI || shell.isConnecting {
            return .working
        }
        if activeEntryTab == .tui {
            return .listening
        }
        return .idle
    }

    var avatarEngine: AvatarEngine {
        AvatarEngine(rawValue: avatarEngineRawValue) ?? .unity
    }

    var companionEventState: String {
        switch companionVisualState {
        case .idle:
            return "idle"
        case .working:
            return "thinking"
        case .listening:
            return "talking"
        case .error:
            return "error"
        }
    }

    var body: some View {
        ZStack {
            Color.clear

            VStack(spacing: 0) {
                terminalCard
            }

            if panel != .none {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { panel = .none }
                floatingPanel
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        )
        .onAppear {
            shell.resetWindowInteraction()
            promptFocused = true
            activeEntryTab = .tui
            unityRunMemory = 0
            unityRuntime.pinOnTopEnabled = shell.alwaysOnTop
            if avatarEngineRawValue != AvatarEngine.unity.rawValue {
                avatarEngineRawValue = AvatarEngine.unity.rawValue
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            runtimeMonitor.log("onAppear")
            runStartupFlowIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            shell.disconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if shell.alwaysOnTop {
                unityRuntime.nudgePanelFollowRaise()
            }
        }
        .onReceive(menuCommandPublisher) { command in
            handleMenuCommand(command)
        }
        .onDisappear {
            shell.disconnect()
            unityRuntime.stopIfRunning()
        }
        .onChange(of: activeEntryTab) { _, newTab in
            runtimeMonitor.log("activeEntryTab -> \(newTab.rawValue)")
            if newTab == .tui {
                promptFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: Notification.Name("tui.request.focus"), object: nil)
                }
                if avatarEngine == .unity, startupFlowState == .ready {
                    avatarBridge.startIfNeeded()
                    if unityAutoStart { unityRuntime.startIfNeeded() }
                    sendUnityAvatarState(unityAvatarState, force: true)
                    sendUnityCameraControl()
                }
            } else {
                avatarBridge.stop()
                unityRuntime.stopIfRunning()
            }
        }
        .onChange(of: avatarEngine) { _, newEngine in
            runtimeMonitor.log("avatarEngine -> \(newEngine.rawValue)")
            if newEngine == .unity, activeEntryTab == .tui, startupFlowState == .ready {
                avatarBridge.startIfNeeded()
                if unityAutoStart { unityRuntime.startIfNeeded() }
                sendUnityAvatarState(unityAvatarState, force: true)
                sendUnityCameraControl()
            } else {
                avatarBridge.stop()
                unityRuntime.stopIfRunning()
            }
        }
        .onChange(of: startupFlowState) { _, newState in
            runtimeMonitor.log("startupFlowState -> \(newState.rawValue)")
            guard newState == .ready else { return }
            guard avatarEngine == .unity, activeEntryTab == .tui else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                avatarBridge.startIfNeeded()
                if unityAutoStart { unityRuntime.startIfNeeded() }
                sendUnityAvatarState(unityAvatarState, force: true)
                sendUnityCameraControl()
            }
        }
        .onChange(of: shell.claudeStage) { _, newValue in
            runtimeMonitor.log("claudeStage -> \(newValue.rawValue)")
        }
        .onChange(of: shell.isConnected) { _, newValue in
            runtimeMonitor.log("shell.isConnected -> \(newValue)")
        }
        .onChange(of: shell.isConnecting) { _, newValue in
            runtimeMonitor.log("shell.isConnecting -> \(newValue)")
        }
        .onChange(of: shell.alwaysOnTop) { _, newValue in
            unityRuntime.pinOnTopEnabled = newValue
            if newValue, !unityRuntime.panelFollowEnabled {
                unityRuntime.setPanelFollowEnabled(true)
            }
        }
        .onChange(of: shell.workspacePath) { _, newValue in
            runtimeMonitor.log("workspacePath -> \(newValue ?? "nil")")
        }
        .onChange(of: shell.errorMessage) { _, newValue in
            guard let newValue else { return }
            runtimeMonitor.log("shell.errorMessage -> \(newValue)")
        }
        .onChange(of: avatarBridge.statusText) { _, newValue in
            runtimeMonitor.log("avatarBridge.status -> \(newValue)")
        }
        .onChange(of: unityRuntime.statusText) { _, newValue in
            runtimeMonitor.log("unityRuntime.status -> \(newValue)")
        }
        .onChange(of: unityRuntime.isRunning) { _, isRunning in
            unityRunMemory = isRunning ? 1 : 0
            guard isRunning else {
                didSendGreetingThisRun = false
                avatarStateLockUntil = .distantPast
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sendUnityPanelSizeIfNeeded(unityPanelSize, force: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                sendUnityPanelSizeIfNeeded(unityPanelSize, force: true)
            }
        }
        .onChange(of: avatarBridge.lastEventText) { _, newValue in
            if newValue.contains("avatar_ready"), newValue.contains("\"engine\":\"unity\""), !didSendGreetingThisRun, unityRuntime.isRunning {
                didSendGreetingThisRun = true
                playUnityAvatarState("greeting", duration: 5.2, force: true)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                sendUnityPanelSizeIfNeeded(unityPanelSize, force: true)
            }
        }
        .sheet(item: $activeStyleEditor) { modal in
            TerminalStyleEditorSheet(modal: modal)
                .environmentObject(shell)
        }
        .sheet(isPresented: $showAvatarSetupWizard) {
            AvatarSetupWizardSheet()
        }
    }

    private var menuCommandPublisher: AnyPublisher<VirceliMenuCommand, Never> {
        let center = NotificationCenter.default
        let publishers: [AnyPublisher<VirceliMenuCommand, Never>] = [
            center.publisher(for: .virceliSelectFolder).map { _ in .selectFolder }.eraseToAnyPublisher(),
            center.publisher(for: .virceliLaunchTUI).map { _ in .launchTUI }.eraseToAnyPublisher(),
            center.publisher(for: .virceliStopTUI).map { _ in .stopTUI }.eraseToAnyPublisher(),
            center.publisher(for: .virceliToggleAlwaysOnTop).map { _ in .toggleAlwaysOnTop }.eraseToAnyPublisher(),
            center.publisher(for: .virceliToggleClickThrough).map { _ in .toggleClickThrough }.eraseToAnyPublisher(),
            center.publisher(for: .virceliResetSavedPaths).map { _ in .resetSavedPaths }.eraseToAnyPublisher(),
            center.publisher(for: .virceliResetCamera).map { _ in .resetCamera }.eraseToAnyPublisher(),
            center.publisher(for: .virceliLaunchApp).map { _ in .launchApp }.eraseToAnyPublisher(),
            center.publisher(for: .virceliStopApp).map { _ in .stopApp }.eraseToAnyPublisher(),
            center.publisher(for: .virceliSelectApp).map { _ in .selectApp }.eraseToAnyPublisher(),
            center.publisher(for: .virceliToggleAttach).map { _ in .toggleAttach }.eraseToAnyPublisher(),
            center.publisher(for: .virceliDockLeft).map { _ in .dockLeft }.eraseToAnyPublisher(),
            center.publisher(for: .virceliDockRight).map { _ in .dockRight }.eraseToAnyPublisher(),
            center.publisher(for: .virceliNewSession).map { _ in .newSession }.eraseToAnyPublisher(),
            center.publisher(for: .virceliSaveResumeFromClipboard).map { _ in .saveResumeFromClipboard }.eraseToAnyPublisher(),
            center.publisher(for: .virceliResumeRun)
                .compactMap { ($0.object as? String).map { .resumeRun($0) } }
                .eraseToAnyPublisher(),
            center.publisher(for: .virceliResumeEditLabel)
                .compactMap { ($0.object as? String).map { .resumeEditLabel($0) } }
                .eraseToAnyPublisher(),
            center.publisher(for: .virceliResumeDelete)
                .compactMap { ($0.object as? String).map { .resumeDelete($0) } }
                .eraseToAnyPublisher(),
            center.publisher(for: .virceliResumeClearAll)
                .map { _ in .resumeClearAll }
                .eraseToAnyPublisher(),
        ]
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    private func handleMenuCommand(_ command: VirceliMenuCommand) {
        switch command {
        case .selectFolder:
            if shell.selectWorkspaceFolder() {
                startupFlowState = .ready
            } else {
                startupFlowState = .failed
            }
        case .launchTUI:
            startClaudeCodeSession(command: "claude")
        case .stopTUI:
            tuiShouldLaunch = false
        case .toggleAlwaysOnTop:
            shell.alwaysOnTop.toggle()
        case .toggleClickThrough:
            shell.clickThrough.toggle()
        case .resetSavedPaths:
            shell.clearWorkspaceSelection()
            unityRuntime.clearSavedSelection()
        case .resetCamera:
            unityCameraZoom = 1.0
            unityCameraPanX = 0.0
            unityCameraPanY = 0.0
            unityCameraOrbitX = 0.0
            unityCameraOrbitY = 0.0
            sendUnityCameraControl(reset: true)
        case .launchApp:
            unityRuntime.startIfNeeded()
        case .stopApp:
            unityRuntime.stopIfRunning()
        case .selectApp:
            unityRuntime.chooseUnityApp()
        case .toggleAttach:
            unityRuntime.setPanelFollowEnabled(!unityRuntime.panelFollowEnabled)
        case .dockLeft:
            unityRuntime.dockSide = .left
        case .dockRight:
            unityRuntime.dockSide = .right
        case .newSession:
            startClaudeCodeSession(command: "claude")
        case .saveResumeFromClipboard:
            shell.saveResumeFromClipboardAndPrompt()
        case .resumeRun(let id):
            startClaudeCodeSession(command: "claude --resume \(id)")
        case .resumeEditLabel(let id):
            shell.promptResumeLabel(for: id)
        case .resumeDelete(let id):
            shell.deleteResumeSession(id: id)
        case .resumeClearAll:
            shell.clearResumeSessions()
        }
    }


    private var terminalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let workspacePath = shell.workspacePath {
                HStack(spacing: 8) {
                    Button("Launch Claude Code") {
                        startClaudeCodeSession(command: "claude")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 210.0 / 255.0, green: 108.0 / 255.0, blue: 77.0 / 255.0))
                    Button("Stop Claude Code") {
                        tuiShouldLaunch = false
                    }
                    .buttonStyle(.bordered)
                    Menu {
                        ForEach(TUIStylePreset.allCases, id: \.rawValue) { preset in
                            Button(preset.rawValue.capitalized) {
                                tuiStyleRawValue = preset.rawValue
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paintpalette")
                            Text("Style: \(tuiStylePreset.rawValue.capitalized)")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    Button {
                        if shell.selectWorkspaceFolder() {
                            startupFlowState = .ready
                        } else {
                            startupFlowState = .failed
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(workspacePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                GeometryReader { geo in
                    Group {
                        if tuiShouldLaunch {
                            TUITerminalView(
                                workspacePath: workspacePath,
                                launchID: tuiLaunchID,
                                launchCommand: tuiLaunchCommand,
                                onUserInput: { bytes in
                                    handleTUIUserInput(bytes)
                                },
                                onOutput: { text in
                                    handleTUIOutput(text)
                                }
                            )
                        } else {
                            VStack(spacing: 10) {
                                Text("Claude Code is stopped")
                                    .font(.headline)
                                    .foregroundStyle(.white.opacity(0.9))
                                Text("Click Launch Claude Code to start a Claude Code session.")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: max(8, 12 - tuiInnerPadding / 2)))
                    .background(
                        ZStack {
                            GeometryReader { innerGeo in
                                Color.clear
                                    .onAppear {
                                        sendUnityPanelSizeIfNeeded(innerGeo.size, force: true)
                                    }
                                    .onChange(of: innerGeo.size) { _, _ in
                                        sendUnityPanelSizeIfNeeded(innerGeo.size)
                                    }
                            }
                            UnityPanelFrameProbe { frameInWindow, window in
                                unityRuntime.updateOverlayTarget(panelFrameInWindow: frameInWindow, hostWindow: window)
                            }
                        }
                    )
                }
                .frame(maxHeight: .infinity)
                .padding(tuiInnerPadding)
                .background(tuiContainerBackground, in: RoundedRectangle(cornerRadius: 14))
                .overlay(styleOverlay)
                .shadow(color: tuiShadowColor, radius: 14, x: 0, y: 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Select a workspace first to launch the TUI.")
                        .foregroundStyle(.white.opacity(0.82))
                    Button("Select Folder") { shell.selectWorkspaceFolder() }
                }
                .padding(10)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }

            if activeEntryTab == .terminal {
                if shell.claudeStage == .trustPrompt {
                    HStack(spacing: 8) {
                        Button("Trust Folder (1)") { shell.trustWorkspaceYes() }
                        Button("Exit (2)") { shell.trustWorkspaceNo() }
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if filteredEntries.isEmpty {
                                Text("Run a command and results will appear as cards.")
                                    .foregroundStyle(.white.opacity(0.68))
                                    .padding(.vertical, 10)
                            }
                            ForEach(filteredEntries) { entry in
                                terminalEntryCard(entry)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("terminal-end")
                        }
                    }
                    .onChange(of: shell.terminalEntries.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("terminal-end", anchor: .bottom)
                        }
                    }
                    .frame(height: terminalOutputHeight)
                    .background(Color(shell.terminalBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottom) {
                        resizeBar
                            .gesture(outputHeightDragGesture)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Type terminal command...", text: $prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: shell.terminalFontSize, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(shell.terminalInputTextColor))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(shell.terminalBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .focused($promptFocused)
                        .onSubmit(sendPrompt)

                    Button("Send", action: sendPrompt)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !shell.isConnected)
                }
            }

            if activeEntryTab == .terminal, showRawLog {
                TerminalTextView(
                    text: shell.output,
                    fontName: shell.terminalFontName,
                    fontSize: shell.terminalFontSize,
                    textColor: .white,
                    backgroundColor: NSColor(calibratedWhite: 0.08, alpha: 1.0)
                )
                .frame(height: terminalRawHeight)
                .background(Color(NSColor(calibratedWhite: 0.08, alpha: 1.0)).opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    resizeBar
                        .gesture(rawHeightDragGesture)
                }
            }
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.94))
    }

    private func terminalEntryCard(_ entry: TerminalEntry) -> some View {
        let isTUI = entry.source == .tui
        let commandChipBackground: Color = isTUI ? Color.blue.opacity(0.24) : inputBubbleFillColor
        let cardBackground: Color = isTUI ? Color.blue.opacity(0.12) : outputBubbleFillColor.opacity(0.82)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if isTUI {
                    Text("TUI")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.28), in: Capsule())
                        .foregroundStyle(.white)
                }
                Text(entry.command)
                    .font(.system(size: max(10, shell.terminalFontSize - 1), weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(commandChipBackground, in: Capsule())
                    .foregroundStyle(Color(shell.terminalInputTextColor))
            }

            Text(entry.output)
                .font(.system(size: shell.terminalFontSize - 1, weight: .regular, design: .monospaced))
                .foregroundStyle(entry.isError ? Color.red.opacity(0.95) : Color(shell.terminalOutputTextColor).opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(entry.isError ? Color.red.opacity(0.28) : Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    func sendUnityPanelSizeIfNeeded(_ size: CGSize, force: Bool = false) {
        guard avatarEngine == .unity, activeEntryTab == .tui else { return }
        let baseSize = NSApp.windows.first?.contentLayoutRect.size ?? size
        let scale = NSApp.windows.first?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        let aspectWidthFromHeight = baseSize.height * (9.0 / 16.0)
        let width = max(480, Int((aspectWidthFromHeight * scale).rounded()))
        let height = max(1, Int((baseSize.height * scale).rounded()))
        let normalized = CGSize(width: width, height: height)
        if !force, normalized == lastSentUnityPanelSize { return }
        lastSentUnityPanelSize = normalized
        avatarBridge.sendPanelSize(width: width, height: height)
        runtimeMonitor.log("unity panel size(px) -> \(width)x\(height) scale=\(String(format: "%.2f", scale))")
    }

    func sendUnityAvatarState(_ state: String, force: Bool = false) {
        guard avatarEngine == .unity, activeEntryTab == .tui else { return }
        if !force, unityAvatarState == state { return }
        unityAvatarState = state
        avatarBridge.sendAvatarState(state)
        runtimeMonitor.log("unity avatar state -> \(state)")
    }

    func playUnityAvatarState(_ state: String, duration: TimeInterval, force: Bool = false) {
        guard avatarEngine == .unity, activeEntryTab == .tui else { return }
        let now = Date()
        if !force, now < avatarStateLockUntil {
            return
        }

        sendUnityAvatarState(state, force: force)
        avatarStateLockUntil = now.addingTimeInterval(duration)
        avatarReturnToIdleTask?.cancel()
        avatarReturnToIdleTask = Task { @MainActor in
            let nanos = UInt64(max(0.2, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Date() >= avatarStateLockUntil {
                sendUnityAvatarState("idle")
            }
        }
    }

    func handleTUIUserInput(_ bytes: ArraySlice<UInt8>) {
        guard bytes.contains(10) || bytes.contains(13) else { return }
        playUnityAvatarState("thinking", duration: 4.9)
        talkingCooldownTask?.cancel()
        thinkingCooldownTask?.cancel()
        thinkingCooldownTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if Date() >= avatarStateLockUntil {
                sendUnityAvatarState("idle")
            }
        }
    }

    func handleTUIOutput(_ text: String) {
        let now = Date()
        if now.timeIntervalSince(tuiOutputBurstStart) > 1.7 {
            tuiOutputBurstStart = now
            tuiOutputLineBurstCount = 0
        }

        let lines = text.split(whereSeparator: \.isNewline).count
        if lines > 0 {
            tuiOutputLineBurstCount += lines
        }

        if tuiOutputLineBurstCount >= 3 {
            playUnityAvatarState("talking", duration: 4.2)
            thinkingCooldownTask?.cancel()
            talkingCooldownTask?.cancel()
            talkingCooldownTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if Date() >= avatarStateLockUntil {
                    sendUnityAvatarState("idle")
                }
            }
        }
    }

    private var liveClaudePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Claude is working...")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            if !shell.claudeLiveSteps.isEmpty {
                ForEach(shell.claudeLiveSteps) { step in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(liveStepColor(step.status))
                            .frame(width: 8, height: 8)
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.86))
                    }
                }
            }

            if !shell.claudeLivePreviewText.isEmpty {
                Text(shell.claudeLivePreviewText)
                    .font(.system(size: max(10, shell.terminalFontSize - 1), weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(shell.terminalOutputTextColor).opacity(0.9))
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.28), lineWidth: 1))
    }

    private func liveStepColor(_ status: ClaudeStepStatus) -> Color {
        switch status {
        case .running:
            return .yellow
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    @ViewBuilder
    private var styleOverlay: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(tuiContainerStroke, lineWidth: 1)
            .overlay(alignment: .top) {
                if tuiStylePreset == .studio {
                    LinearGradient(
                        colors: [.cyan.opacity(0.55), .blue.opacity(0.25), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if tuiStylePreset == .glass {
                    LinearGradient(
                        colors: [.white.opacity(0.24), .white.opacity(0.06), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if tuiStylePreset == .neon {
                    LinearGradient(
                        colors: [.green.opacity(0.35), .mint.opacity(0.14), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if tuiStylePreset == .sunset {
                    LinearGradient(
                        colors: [.orange.opacity(0.32), .red.opacity(0.16), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if tuiStylePreset == .paper {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.08))
                }
            }
            .allowsHitTesting(false)
    }

    // Character panel is now rendered by AvatarCompanionView (SceneKit + FBX clips).

    private var resizeBar: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 56, height: 4)
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var cornerResizeHandle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.14))
                .frame(width: 20, height: 20)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var outputHeightDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isOutputResizing {
                    isOutputResizing = true
                    outputResizeStartHeight = terminalOutputHeight
                }
                terminalOutputHeight = clamp(outputResizeStartHeight + value.translation.height, min: 220, max: 760)
            }
            .onEnded { _ in
                isOutputResizing = false
            }
    }

    private var rawHeightDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isRawResizing {
                    isRawResizing = true
                    rawResizeStartHeight = terminalRawHeight
                }
                terminalRawHeight = clamp(rawResizeStartHeight + value.translation.height, min: 120, max: 500)
            }
            .onEnded { _ in
                isRawResizing = false
            }
    }

    private var cardResizeDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isCardResizing {
                    isCardResizing = true
                    cardResizeStartWidth = terminalCardWidth
                    cardResizeStartOutputHeight = terminalOutputHeight
                }
                terminalCardWidth = clamp(cardResizeStartWidth + value.translation.width, min: 760, max: 1800)
                terminalOutputHeight = clamp(cardResizeStartOutputHeight + value.translation.height, min: 220, max: 760)
            }
            .onEnded { _ in
                isCardResizing = false
            }
    }

    private func clamp(_ value: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        Swift.max(lowerBound, Swift.min(upperBound, value))
    }

    private func sendPrompt() {
        let command = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        if command == "claude" {
            activeEntryTab = .tui
            tuiLaunchCommand = "claude"
            tuiLaunchID = UUID()
            prompt = ""
            promptFocused = false
            return
        } else if command.hasPrefix("claude --resume ") {
            shell.saveResumeSession(fromCommand: command)
            activeEntryTab = .tui
            tuiLaunchCommand = command
            tuiLaunchID = UUID()
            prompt = ""
            promptFocused = false
            return
        }
        shell.submitCommandFromUI(command)
        prompt = ""
        promptFocused = true
    }

    var startupFlowStateLabel: String {
        switch startupFlowState {
        case .idle:
            return "idle"
        case .selectingWorkspace:
            return "selecting folder..."
        case .checkingAuth:
            return "checking auth..."
        case .launchingTUI:
            return "launching TUI..."
        case .ready:
            return "ready"
        case .failed:
            return "startup failed"
        }
    }

    private func runStartupFlowIfNeeded() {
        guard !didRunStartupFlow else { return }
        didRunStartupFlow = true

        Task { @MainActor [weak shell] in
            guard let shell else { return }
            startupFlowState = .checkingAuth
            runtimeMonitor.log("startup begin")
            guard shell.workspacePath != nil else {
                startupFlowState = .failed
                activeEntryTab = .tui
                shell.errorMessage = "workspace not selected (click Folder)"
                runtimeMonitor.log("startup failed: workspace missing")
                return
            }
            runtimeMonitor.log("startup workspace ok (auto TUI disabled)")
            activeEntryTab = .tui
            tuiShouldLaunch = false
            startupFlowState = .ready
        }
    }

    func startTUI(command: String) {
        runtimeMonitor.log("startTUI command=\(command)")
        startupFlowState = .launchingTUI
        activeEntryTab = .tui
        tuiShouldLaunch = true
        tuiLaunchCommand = command
        tuiLaunchID = UUID()
        promptFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: Notification.Name("tui.request.focus"), object: nil)
        }
        startupFlowState = .ready
    }

    private func startClaudeCodeSession(command: String) {
        activeEntryTab = .tui
        tuiShouldLaunch = true
        tuiLaunchCommand = command
        tuiLaunchID = UUID()
        promptFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: Notification.Name("tui.request.focus"), object: nil)
        }

        guard avatarEngine == .unity else { return }
        avatarBridge.startIfNeeded()
        unityRuntime.refreshRunningState()
        if !unityRuntime.isRunning {
            unityRunMemory = 0
        }

        if unityRunMemory == 0 {
            unityRuntime.startIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.unityRuntime.refreshRunningState()
                if !self.unityRuntime.isRunning {
                    self.unityRuntime.startIfNeeded()
                }
                self.unityRunMemory = self.unityRuntime.isRunning ? 1 : 0
            }
        } else {
            unityRunMemory = 1
        }
    }
}
