import AppKit
import SwiftUI

extension RootView {
    var topDock: some View {
        HStack(spacing: 10) {
            actionButton(symbol: "folder", title: "Folder", active: false) {
                if shell.selectWorkspaceFolder() {
                    runtimeMonitor.log("folder selected -> startTUI")
                    startupFlowState = .ready
                } else {
                    startupFlowState = .failed
                    runtimeMonitor.log("folder selection cancelled")
                }
            }
            if showConnectControls {
                actionButton(symbol: shell.isConnected ? "bolt.horizontal.fill" : "bolt.horizontal", title: shell.isConnected ? "Connected" : "Connect", active: shell.isConnected) {
                    shell.connect()
                }
                actionButton(symbol: "xmark.circle", title: "Disconnect", active: false) {
                    shell.disconnect()
                }
            }
            if showTerminalPanelButton {
                actionButton(symbol: "slider.horizontal.3", title: "Terminal", active: panel == .terminal) {
                    panel = panel == .terminal ? .none : .terminal
                }
            }
            systemMenu
            unityRuntimeMenu
            resumeMenuButton
        }
        .padding(8)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.22), lineWidth: 1))
    }

    @ViewBuilder
    var floatingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch panel {
            case .terminal:
                Text("Terminal Style")
                    .font(.headline)
                Picker("Preset", selection: $shell.selectedPresetID) {
                    ForEach(shell.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .onChange(of: shell.selectedPresetID) { _, newValue in
                    shell.applyPreset(id: newValue)
                }
                Picker("Font", selection: $shell.terminalFontName) {
                    ForEach(shell.availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
                .onChange(of: shell.terminalFontName) { _, newValue in
                    shell.setTerminalFontName(newValue)
                }
                HStack {
                    Text("Size")
                    Slider(
                        value: Binding(
                            get: { shell.terminalFontSize },
                            set: { shell.setTerminalFontSize($0) }
                        ),
                        in: 10...22
                    )
                    Text("\(Int(shell.terminalFontSize))")
                        .frame(width: 26)
                }
                Text("Resize by mouse drag:")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                Text("• Bottom-right corner: width + output height")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                Text("• Bottom divider on each area: section height")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.62))
                Button("Reset Size") {
                    terminalCardWidth = 1000
                    terminalOutputHeight = 360
                    terminalRawHeight = 180
                }
                styleEditorLaunchButton(
                    title: "Input Text",
                    subtitle: shell.terminalInputTextColor.hexRGB,
                    color: shell.terminalInputTextColor
                ) {
                    activeStyleEditor = .inputText
                }
                styleEditorLaunchButton(
                    title: "Output Text",
                    subtitle: shell.terminalOutputTextColor.hexRGB,
                    color: shell.terminalOutputTextColor
                ) {
                    activeStyleEditor = .outputText
                }
                styleEditorLaunchButton(
                    title: "Background",
                    subtitle: shell.terminalBackgroundColor.hexRGB,
                    color: shell.terminalBackgroundColor
                ) {
                    activeStyleEditor = .background
                }
                Divider().overlay(.white.opacity(0.2))
                Text("Custom Themes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.84))
                TextField("Theme name", text: $shell.customThemeName)
                    .textFieldStyle(.roundedBorder)
                Button("Save Current Theme") { shell.saveCurrentAsCustomTheme() }
                    .disabled(shell.customThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if shell.customThemes.isEmpty {
                    Text("No saved themes yet.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Picker("Saved", selection: $selectedCustomThemeID) {
                        Text("Select").tag("")
                        ForEach(shell.customThemes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Apply Saved") {
                            guard !selectedCustomThemeID.isEmpty else { return }
                            shell.applyCustomTheme(id: selectedCustomThemeID)
                        }
                        .disabled(selectedCustomThemeID.isEmpty)
                        Button("Delete Saved") {
                            guard !selectedCustomThemeID.isEmpty else { return }
                            shell.deleteCustomTheme(id: selectedCustomThemeID)
                            selectedCustomThemeID = ""
                        }
                        .disabled(selectedCustomThemeID.isEmpty)
                    }
                }
            case .system:
                Text("System")
                    .font(.headline)
                Toggle("Always on top", isOn: $shell.alwaysOnTop)
                Toggle("Click-through", isOn: $shell.clickThrough)
                Divider().overlay(.white.opacity(0.2))
                Button("Reset Saved Paths") {
                    shell.clearWorkspaceSelection()
                    unityRuntime.clearSavedSelection()
                }
                Button("Reset Avatar Camera") {
                    unityCameraZoom = 1.0
                    unityCameraPanX = 0.0
                    unityCameraPanY = 0.0
                    unityCameraOrbitX = 0.0
                    unityCameraOrbitY = 0.0
                    sendUnityCameraControl(reset: true)
                }
            case .monitor:
                RuntimeMonitorPanel(
                    monitor: runtimeMonitor,
                    startupFlowState: startupFlowState,
                    activeEntryTab: activeEntryTab,
                    workspacePath: shell.workspacePath,
                    shellConnected: shell.isConnected,
                    shellConnecting: shell.isConnecting,
                    claudeStage: shell.claudeStage,
                    shellError: shell.errorMessage,
                    bridgeStatus: avatarBridge.statusText,
                    unityStatus: unityRuntime.statusText
                )
            case .none:
                EmptyView()
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.22), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 84)
        .padding(.trailing, 14)
    }

    func actionButton(symbol: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(active ? Color.white.opacity(0.25) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }

    var unityRuntimeMenu: some View {
        Menu {
            Button("Select App") {
                unityRuntime.chooseUnityApp()
            }
            Button(unityRuntime.isRunning ? "Relaunch App" : "Launch App") {
                unityRuntime.startIfNeeded()
            }
            Button("Stop App") {
                unityRuntime.stopIfRunning()
            }
            .disabled(!unityRuntime.isRunning)
            Divider()
            Button(unityRuntime.panelFollowEnabled ? "Detach Panel Follow" : "Attach Panel Follow") {
                unityRuntime.setPanelFollowEnabled(!unityRuntime.panelFollowEnabled)
            }
            Menu("Dock Side: \(unityRuntime.dockSide.rawValue.capitalized)") {
                Button("Right") {
                    unityRuntime.dockSide = .right
                }
                Button("Left") {
                    unityRuntime.dockSide = .left
                }
            }
            Button(unityRuntime.pinOnTopEnabled ? "Pin On Top: ON" : "Pin On Top: OFF") {
                unityRuntime.pinOnTopEnabled.toggle()
            }
            .disabled(!unityRuntime.panelFollowEnabled)
            Button("Accessibility Settings") {
                unityRuntime.openAccessibilitySettings()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("AI Virceli")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    var systemMenu: some View {
        Menu {
            Button(shell.alwaysOnTop ? "Always On Top: ON" : "Always On Top: OFF") {
                shell.alwaysOnTop.toggle()
            }
            Button(shell.clickThrough ? "Click-through: ON" : "Click-through: OFF") {
                shell.clickThrough.toggle()
            }
            Divider()
            Button("Reset Saved Paths") {
                shell.clearWorkspaceSelection()
                unityRuntime.clearSavedSelection()
            }
            Button("Reset Avatar Camera") {
                unityCameraZoom = 1.0
                unityCameraPanX = 0.0
                unityCameraPanY = 0.0
                unityCameraOrbitX = 0.0
                unityCameraOrbitY = 0.0
                sendUnityCameraControl(reset: true)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "switch.2")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("System")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    func sendUnityCameraControl(reset: Bool = false) {
        guard avatarEngine == .unity, activeEntryTab == .tui else { return }
        avatarBridge.sendCameraControl(
            zoom: unityCameraZoom,
            panX: unityCameraPanX,
            panY: unityCameraPanY,
            orbitX: unityCameraOrbitX,
            orbitY: unityCameraOrbitY,
            reset: reset
        )
    }

    func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    var resumeMenuButton: some View {
        Menu {
            Button("New Claude Session") {
                activeEntryTab = .tui
                tuiLaunchCommand = "claude"
                tuiLaunchID = UUID()
            }
            Divider()
            Button("Save Resume ID From Clipboard") {
                shell.saveResumeFromClipboardAndPrompt()
            }
            if shell.resumeSessions.isEmpty {
                Text("No saved resume sessions")
            } else {
                Divider()
                ForEach(shell.resumeSessions) { session in
                    Menu(session.displayName) {
                        Button("Resume") {
                            activeEntryTab = .tui
                            tuiLaunchCommand = "claude --resume \(session.id)"
                            tuiLaunchID = UUID()
                        }
                        Button("Edit Label") {
                            shell.promptResumeLabel(for: session.id)
                        }
                        Button("Remove Label") {
                            shell.clearResumeLabel(id: session.id)
                        }
                        .disabled((session.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Divider()
                        Button("Delete Session") {
                            shell.deleteResumeSession(id: session.id)
                        }
                    }
                }
                Divider()
                Button("Clear Saved Sessions") {
                    shell.clearResumeSessions()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("Resume")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    func styleEditorLaunchButton(
        title: String,
        subtitle: String,
        color: NSColor,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(color))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(8)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}
