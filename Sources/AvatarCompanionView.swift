import SwiftUI
import WebKit
import Foundation
import AppKit

final class AvatarWKWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}

enum AvatarMotion: String, CaseIterable {
    case greeting
    case idle
    case idleYawn
    case looking
    case lookingDeep
    case talking1
    case talking2
    case talking3

    var jsName: String { rawValue }
}

struct AvatarCompanionView: View {
    let workspacePath: String?
    let sessionID: UUID
    let stateText: String
    let isWorking: Bool
    let isError: Bool

    @State private var tick: Int = 0
    @State private var hasPlayedGreeting = false
    @State private var currentMotion: AvatarMotion = .idle
    @State private var assetStatus: String = "avatar: booting"
    @State private var assetLog: [String] = []

    var body: some View {
        VStack(spacing: 8) {
            AvatarWebRenderer(
                workspacePath: workspacePath,
                motion: currentMotion,
                statusText: $assetStatus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(stateText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text(assetStatus)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(spacing: 6) {
                HStack {
                    Text("Avatar Logs")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button("Copy Logs") {
                        copyLogsToPasteboard()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(assetLog.indices, id: \.self) { index in
                            Text(assetLog[index])
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .textSelection(.enabled)
                .frame(height: 110)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.28))
                )
            }
        }
        .onAppear { playGreetingAndIdle() }
        .onChange(of: assetStatus) { _, newValue in
            guard !newValue.isEmpty else { return }
            let line = "[\(Self.nowStamp())] \(newValue)"
            if assetLog.last == line { return }
            assetLog.append(line)
            if assetLog.count > 80 {
                assetLog.removeFirst(assetLog.count - 80)
            }
        }
        .onChange(of: sessionID) { _, _ in
            hasPlayedGreeting = false
            playGreetingAndIdle()
        }
        .onChange(of: isError) { _, newValue in
            if newValue { currentMotion = .lookingDeep }
        }
        .onChange(of: isWorking) { _, newValue in
            if newValue {
                tick += 1
                currentMotion = tick.isMultiple(of: 2) ? .looking : .lookingDeep
            } else if !isError {
                currentMotion = .idle
            }
        }
        .onReceive(Timer.publish(every: 7, on: .main, in: .common).autoconnect()) { _ in
            guard !isWorking, !isError else { return }
            tick += 1
            switch tick % 6 {
            case 0: currentMotion = .idleYawn
            case 1: currentMotion = .talking1
            case 2: currentMotion = .talking2
            case 3: currentMotion = .talking3
            case 4: currentMotion = .looking
            default: currentMotion = .idle
            }
        }
    }

    private func playGreetingAndIdle() {
        guard !hasPlayedGreeting else { return }
        hasPlayedGreeting = true
        currentMotion = .greeting
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if !isWorking && !isError {
                currentMotion = .idle
            }
        }
    }

    private static func nowStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func copyLogsToPasteboard() {
        let text = assetLog.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private struct AvatarWebRenderer: NSViewRepresentable {
    let workspacePath: String?
    let motion: AvatarMotion
    @Binding var statusText: String

    func makeCoordinator() -> Coordinator {
        let binding = _statusText
        return Coordinator(statusSink: { text in
            DispatchQueue.main.async {
                binding.wrappedValue = text
            }
        })
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = AvatarWKWebView(frame: .zero, configuration: context.coordinator.makeConfiguration())
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView: webView)
        context.coordinator.pushStatus("avatar: starting local renderer")
        context.coordinator.bootstrapAndLoadHTML()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.pendingMotion = motion
        context.coordinator.pendingWorkspacePath = workspacePath
        context.coordinator.applyIfReady()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "avatarStatus")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var webView: WKWebView?
        private let statusSink: (String) -> Void
        private var isWebReady = false
        private var isSceneReady = false
        private var lastStatus = ""
        private var lastMotion: AvatarMotion?
        private var lastAssetRoot = ""
        private var lastInjectedProfileDigest = ""
        private var contentBaseURL: String?

        var pendingMotion: AvatarMotion = .idle
        var pendingWorkspacePath: String?

        init(statusSink: @escaping (String) -> Void) {
            self.statusSink = statusSink
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAvatarProfileDidChange),
                name: .avatarProfileDidChange,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self, name: .avatarProfileDidChange, object: nil)
        }

        @objc private func handleAvatarProfileDidChange(_ notification: Notification) {
            reloadProfileAndAvatar()
        }

        func makeConfiguration() -> WKWebViewConfiguration {
            let contentController = WKUserContentController()
            contentController.add(self, name: "avatarStatus")

            let config = WKWebViewConfiguration()
            config.userContentController = contentController
            return config
        }

        func attach(webView: WKWebView) {
            self.webView = webView
        }

        func pushStatus(_ text: String) {
            emit(text)
        }

        func bootstrapAndLoadHTML() {
            // Web renderer path is intentionally disabled.
            contentBaseURL = nil
            isSceneReady = false
            let placeholder = """
            <!doctype html>
            <html><body style="background:transparent;color:#ddd;font:13px -apple-system;padding:12px;">
            Avatar WebView renderer is disabled.
            </body></html>
            """
            webView?.loadHTMLString(placeholder, baseURL: nil)
            emit("avatar: web renderer disabled")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isWebReady = true
            emit("avatar: web ready")
            applyIfReady()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            emit("avatar: web fail (\(error.localizedDescription))")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            emit("avatar: web provisional fail (\(error.localizedDescription))")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "avatarStatus" else { return }
            if let text = message.body as? String {
                if text == "avatar: scene ready" { isSceneReady = true }
                emit(text)
                applyIfReady()
            }
        }

        func applyIfReady() {
            guard isWebReady, isSceneReady, let webView, let contentBaseURL else { return }

            let assetRoot = resolveAssetRootURLString(contentBaseURL: contentBaseURL)
            if assetRoot != lastAssetRoot {
                lastAssetRoot = assetRoot
                if let assetRootURL = resolveAssetRootFileURL() {
                    injectProfileIfNeeded(assetRootURL: assetRootURL, webView: webView)
                } else {
                    lastInjectedProfileDigest = ""
                    webView.evaluateJavaScript("window.avatarSetProfileJSON('');")
                }
                let js = "window.avatarSetAssetRoot('" + jsEscaped(assetRoot) + "');"
                webView.evaluateJavaScript(js)
            }

            if pendingMotion != lastMotion {
                lastMotion = pendingMotion
                let js = "window.avatarPlay('" + jsEscaped(pendingMotion.jsName) + "');"
                webView.evaluateJavaScript(js)
            }
        }

        private func reloadProfileAndAvatar() {
            guard isWebReady, isSceneReady, let webView else { return }
            if let assetRootURL = resolveAssetRootFileURL() {
                injectProfileIfNeeded(assetRootURL: assetRootURL, webView: webView, force: true)
            }
            webView.evaluateJavaScript("window.avatarReload?.();")
            emit("avatar: profile hot reloaded")
        }

        private func resolveAssetRootURLString(contentBaseURL: String) -> String {
            if let local = resolveAssetRootFileURL() {
                return fileURLToBaseURL(fileURL: local, contentBaseURL: contentBaseURL)
            }
            return contentBaseURL + "/native-macos/public/assets"
        }

        private func resolveAssetRootFileURL() -> URL? {
            if let workspace = pendingWorkspacePath {
                let direct = URL(fileURLWithPath: workspace, isDirectory: true)
                    .appendingPathComponent("public/assets", isDirectory: true)
                if FileManager.default.fileExists(atPath: direct.path) {
                    return direct
                }
            }

            if let root = Self.resolveProjectRoot() {
                let native = root.appendingPathComponent("native-macos/public/assets", isDirectory: true)
                if FileManager.default.fileExists(atPath: native.path) {
                    return native
                }
                let plain = root.appendingPathComponent("public/assets", isDirectory: true)
                if FileManager.default.fileExists(atPath: plain.path) {
                    return plain
                }
            }
            return nil
        }

        private func fileURLToBaseURL(fileURL: URL, contentBaseURL: String) -> String {
            if contentBaseURL.hasPrefix("file://") {
                return fileURL.absoluteString.hasSuffix("/") ? String(fileURL.absoluteString.dropLast()) : fileURL.absoluteString
            }
            guard let root = Self.resolveProjectRoot() else {
                return contentBaseURL + "/native-macos/public/assets"
            }
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let targetPath = fileURL.path
            if targetPath.hasPrefix(rootPath) {
                let relative = String(targetPath.dropFirst(rootPath.count))
                return contentBaseURL + "/" + relative
            }
            return contentBaseURL + "/native-macos/public/assets"
        }

        private func jsEscaped(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }

        private func injectProfileIfNeeded(assetRootURL: URL, webView: WKWebView, force: Bool = false) {
            guard let profileJSON = loadAvatarProfileJSONString(assetRootURL: assetRootURL) else {
                if force || !lastInjectedProfileDigest.isEmpty {
                    lastInjectedProfileDigest = ""
                    webView.evaluateJavaScript("window.avatarSetProfileJSON('');")
                }
                return
            }
            let digest = String(profileJSON.hashValue)
            if !force, digest == lastInjectedProfileDigest {
                return
            }
            lastInjectedProfileDigest = digest
            let js = "window.avatarSetProfileJSON('" + jsEscaped(profileJSON) + "');"
            webView.evaluateJavaScript(js)
        }

        private func loadAvatarProfileJSONString(assetRootURL: URL) -> String? {
            let profileURL = assetRootURL
                .appendingPathComponent("avatars", isDirectory: true)
                .appendingPathComponent("avatar_profile.json")
            guard FileManager.default.fileExists(atPath: profileURL.path) else { return nil }
            do {
                let data = try Data(contentsOf: profileURL)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let normalized = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                    return String(data: normalized, encoding: .utf8)
                }
                return nil
            } catch {
                return nil
            }
        }

        private func emit(_ text: String) {
            guard text != lastStatus else { return }
            lastStatus = text
            statusSink(text)
        }

        private static func resolveProjectRoot() -> URL? {
            let fileManager = FileManager.default
            if let savedWorkspace = UserDefaults.standard.string(forKey: "claude.workspace.path"), !savedWorkspace.isEmpty {
                let workspaceURL = URL(fileURLWithPath: savedWorkspace, isDirectory: true)
                if fileManager.fileExists(atPath: workspaceURL.path) {
                    return workspaceURL
                }
            }
            let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            if fileManager.fileExists(atPath: cwd.path) {
                return cwd
            }
            return nil
        }

        private func writeRuntimeHTML(html: String, projectRoot: URL) -> URL? {
            let dir = projectRoot.appendingPathComponent(".codex-runtime", isDirectory: true)
            let file = dir.appendingPathComponent("avatar_runtime.html")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
                try html.write(to: file, atomically: true, encoding: .utf8)
                return file
            } catch {
                return nil
            }
        }
    }
}
