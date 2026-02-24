import AppKit
import ApplicationServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class UnityRuntimeManager: ObservableObject {
    enum DockSide: String, CaseIterable {
        case right
        case left
    }

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "app: idle"
    @Published private(set) var selectedAppPath: String = ""
    @Published private(set) var panelFollowEnabled = false
    @Published var pinOnTopEnabled = true
    @Published var dockSide: DockSide = .right {
        didSet {
            UserDefaults.standard.set(dockSide.rawValue, forKey: dockSideDefaultsKey)
        }
    }

    private let pathDefaultsKey = "unity.runtime.app.path"
    private let dockSideDefaultsKey = "unity.runtime.dock.side"
    private var overlayTimer: Timer?
    private var runningStateTimer: Timer?
    private var overlayInFlight = false
    private var targetRectOnScreen: CGRect = .zero
    private var panelFrameInHostWindow: CGRect = .zero
    private weak var hostWindow: NSWindow?
    private var lastAppliedRectOnScreen: CGRect = .zero
    private var lastUnityPID: pid_t = 0
    private var hasReportedNoAccessibility = false
    private var hasRequestedAccessibilityPromptThisRun = false

    init() {
        if let bundled = bundledUnityAppURL() {
            selectedAppPath = bundled.path
            UserDefaults.standard.set(selectedAppPath, forKey: pathDefaultsKey)
            statusText = "app: bundled app ready"
        } else {
            selectedAppPath = UserDefaults.standard.string(forKey: pathDefaultsKey) ?? ""
        }
        if let raw = UserDefaults.standard.string(forKey: dockSideDefaultsKey),
           let saved = DockSide(rawValue: raw) {
            dockSide = saved
        }
        refreshRunningState()
        startRunningStateMonitor()
    }

    func chooseUnityApp() {
        let panel = NSOpenPanel()
        panel.title = "Select AI Virceli App"
        panel.prompt = "Select"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setUnityAppURL(url)
    }

    func setUnityAppURL(_ url: URL) {
        let normalized = url.resolvingSymlinksInPath()
        selectedAppPath = normalized.path
        UserDefaults.standard.set(selectedAppPath, forKey: pathDefaultsKey)
        statusText = "app: selected \(normalized.lastPathComponent)"
        refreshRunningState()
    }

    func startIfNeeded() {
        requestAccessibilityPermissionIfNeeded(prompt: true)

        guard let appURL = resolveUnityAppURL() else {
            statusText = "app: not found (select .app)"
            isRunning = false
            return
        }

        if runningApplication(for: appURL) != nil {
            isRunning = true
            statusText = "app: running"
            if !panelFollowEnabled {
                setPanelFollowEnabled(true)
            }
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false
        config.arguments = [
            "-screen-fullscreen", "0",
            "-window-mode", "windowed",
            "-popupwindow", "0"
        ]

        statusText = "app: launching..."
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.isRunning = false
                    self.statusText = "app: launch failed (\(error.localizedDescription))"
                    return
                }
                self.isRunning = (app != nil)
                self.statusText = self.isRunning ? "app: running" : "app: launch failed"
                if self.isRunning, !self.panelFollowEnabled {
                    self.setPanelFollowEnabled(true)
                }
            }
        }
    }

    func stopIfRunning() {
        guard let appURL = resolveUnityAppURL() else {
            statusText = "app: stopped"
            isRunning = false
            return
        }

        guard let app = runningApplication(for: appURL) else {
            statusText = "app: stopped"
            isRunning = false
            return
        }

        if !app.terminate() {
            _ = app.forceTerminate()
        }
        stopPanelFollow()
        isRunning = false
        statusText = "app: stopped"
    }

    func refreshRunningState() {
        guard let appURL = resolveUnityAppURL() else {
            isRunning = false
            if statusText != "app: launching..." {
                statusText = "app: idle"
            }
            return
        }
        let running = (runningApplication(for: appURL) != nil)
        isRunning = running
        if running {
            statusText = "app: running"
        } else if statusText != "app: launching..." {
            statusText = "app: idle"
        }
    }

    func setPanelFollowEnabled(_ enabled: Bool) {
        panelFollowEnabled = enabled
        if enabled {
            requestAccessibilityPermissionIfNeeded(prompt: true)
            hasReportedNoAccessibility = false
            startPanelFollow()
        } else {
            stopPanelFollow()
            statusText = isRunning ? "app: running" : "app: idle"
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func requestAccessibilityPermissionIfNeeded(prompt: Bool) {
        guard !AXIsProcessTrusted() else { return }
        guard prompt else { return }
        guard !hasRequestedAccessibilityPromptThisRun else { return }

        hasRequestedAccessibilityPromptThisRun = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        setStatusIfNeeded("app: grant Accessibility permission")
    }

    func clearSavedSelection() {
        stopIfRunning()
        UserDefaults.standard.removeObject(forKey: pathDefaultsKey)
        UserDefaults.standard.removeObject(forKey: dockSideDefaultsKey)
        dockSide = .right
        if let bundled = bundledUnityAppURL() {
            selectedAppPath = bundled.path
            UserDefaults.standard.set(selectedAppPath, forKey: pathDefaultsKey)
            statusText = "app: reset to bundled app"
        } else {
            selectedAppPath = ""
            statusText = "app: selection cleared"
        }
        refreshRunningState()
    }

    func updateOverlayTarget(panelFrameInWindow: CGRect, hostWindow: NSWindow?) {
        guard let hostWindow else { return }
        self.hostWindow = hostWindow
        panelFrameInHostWindow = panelFrameInWindow
        targetRectOnScreen = computeDockRect()
    }

    func nudgePanelFollowRaise() {
        guard panelFollowEnabled else { return }
        guard let appURL = resolveUnityAppURL(), let unityApp = runningApplication(for: appURL) else { return }
        if hostWindow == nil {
            hostWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first
        }
        guard let hostWindow else { return }

        let targetRect = computeDockRect()
        guard targetRect.width > 40, targetRect.height > 40 else { return }
        let axRect = toAccessibilityScreenRect(targetRect, on: hostWindow.screen)
        let pid = unityApp.processIdentifier

        DispatchQueue.global(qos: .userInitiated).async {
            Self.applyWindowRectForUnity(pid: pid, targetRect: axRect, raiseWindow: true)
        }
    }

    private func startPanelFollow() {
        guard overlayTimer == nil else { return }
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickPanelFollow()
            }
        }
        if let overlayTimer {
            RunLoop.main.add(overlayTimer, forMode: .common)
        }
    }

    private func stopPanelFollow() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        overlayInFlight = false
        lastAppliedRectOnScreen = .zero
        lastUnityPID = 0
    }

    private func startRunningStateMonitor() {
        guard runningStateTimer == nil else { return }
        runningStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunningState()
            }
        }
        if let runningStateTimer {
            RunLoop.main.add(runningStateTimer, forMode: .common)
        }
    }

    private func tickPanelFollow() {
        guard panelFollowEnabled else { return }
        guard !overlayInFlight else { return }
        if hostWindow == nil {
            hostWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first
        }
        targetRectOnScreen = computeDockRect()
        guard targetRectOnScreen.width > 40, targetRectOnScreen.height > 40 else { return }
        guard let appURL = resolveUnityAppURL(), let unityApp = runningApplication(for: appURL) else {
            isRunning = false
            return
        }
        guard let hostWindow else { return }
        if !isRunning {
            isRunning = true
        }

        let pid = unityApp.processIdentifier
        let targetRect = targetRectOnScreen
        let axRect = toAccessibilityScreenRect(targetRect, on: hostWindow.screen)

        overlayInFlight = true
        let pinOnTop = pinOnTopEnabled
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.applyWindowRectForUnity(pid: pid, targetRect: axRect, raiseWindow: pinOnTop)
            Task { @MainActor in
                guard let self else { return }
                self.overlayInFlight = false
                self.lastUnityPID = pid
                self.lastAppliedRectOnScreen = targetRect

                if !AXIsProcessTrusted() {
                    if !self.hasReportedNoAccessibility {
                        self.setStatusIfNeeded("app: running (panel follow needs Accessibility)")
                        self.hasReportedNoAccessibility = true
                    }
                } else if self.hasReportedNoAccessibility {
                    self.hasReportedNoAccessibility = false
                    self.setStatusIfNeeded("app: panel follow on")
                } else {
                    self.setStatusIfNeeded("app: panel follow on")
                }
            }
        }
    }

    private func computeDockRect() -> CGRect {
        guard let hostWindow else { return .zero }
        let windowFrame = hostWindow.frame
        let targetHeight = max(420, windowFrame.height)
        let targetWidth = max(360, targetHeight * (9.0 / 16.0))
        let gap: CGFloat = 8

        let x: CGFloat
        switch dockSide {
        case .right:
            x = windowFrame.maxX + gap
        case .left:
            x = windowFrame.minX - targetWidth - gap
        }
        let y = windowFrame.minY
        return CGRect(x: x, y: y, width: targetWidth, height: targetHeight).integral
    }

    private func toAccessibilityScreenRect(_ rect: CGRect, on screen: NSScreen?) -> CGRect {
        guard let screen else { return rect }
        let frame = screen.frame
        let convertedY = frame.maxY - rect.maxY
        return CGRect(x: rect.origin.x, y: convertedY, width: rect.width, height: rect.height).integral
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 1.0
            && abs(lhs.origin.y - rhs.origin.y) < 1.0
            && abs(lhs.size.width - rhs.size.width) < 1.0
            && abs(lhs.size.height - rhs.size.height) < 1.0
    }

    private func setStatusIfNeeded(_ value: String) {
        if statusText != value {
            statusText = value
        }
    }

    nonisolated
    private static func applyWindowRectForUnity(pid: pid_t, targetRect: CGRect, raiseWindow: Bool) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return
        }
        let window = bestControllableWindow(from: windows) ?? windows[0]

        var origin = targetRect.origin
        var size = targetRect.size
        if let pos = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
        if let sz = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        }

        if raiseWindow {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    nonisolated
    private static func bestControllableWindow(from windows: [AXUIElement]) -> AXUIElement? {
        var best: AXUIElement?
        var bestArea: CGFloat = 0

        for window in windows {
            guard let size = axSize(of: window) else { continue }
            let area = max(0, size.width) * max(0, size.height)
            if area > bestArea {
                bestArea = area
                best = window
            }
        }
        return best
    }

    nonisolated
    private static func axSize(of window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard result == .success, let raw = sizeRef else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func resolveUnityAppURL() -> URL? {
        if let bundled = bundledUnityAppURL() {
            return bundled
        }

        if !selectedAppPath.isEmpty {
            let url = URL(fileURLWithPath: selectedAppPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private func bundledUnityAppURL() -> URL? {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("UnityPlayer/AvatarUnity.app"),
              FileManager.default.fileExists(atPath: bundled.path) else {
            return nil
        }
        return bundled
    }

    private func runningApplication(for appURL: URL) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard let bundleURL = app.bundleURL else { return false }
            return bundleURL.resolvingSymlinksInPath().path == appURL.resolvingSymlinksInPath().path
        }
    }
}
