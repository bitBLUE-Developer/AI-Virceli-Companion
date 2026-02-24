import SwiftUI
import AppKit
#if canImport(SwiftTerm)
import SwiftTerm
#endif

struct TUITerminalView: View {
    let workspacePath: String
    let launchID: UUID
    let launchCommand: String
    let onUserInput: ((ArraySlice<UInt8>) -> Void)?
    let onOutput: ((String) -> Void)?

    var body: some View {
#if canImport(SwiftTerm)
        NativeTUITerminalRepresentable(
            workspacePath: workspacePath,
            launchID: launchID,
            launchCommand: launchCommand,
            onUserInput: onUserInput,
            onOutput: onOutput
        )
            .id(launchID)
#else
        VStack(spacing: 8) {
            Text("SwiftTerm dependency is not available.")
                .foregroundStyle(.white)
            Text("Install package dependencies and relaunch.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
#endif
    }
}

#if canImport(SwiftTerm)
private struct NativeTUITerminalRepresentable: NSViewRepresentable {
    let workspacePath: String
    let launchID: UUID
    let launchCommand: String
    let onUserInput: ((ArraySlice<UInt8>) -> Void)?
    let onOutput: ((String) -> Void)?

    @MainActor
    final class Coordinator: NSObject {
        weak var terminalView: LocalProcessTerminalView?
        private var didInitialFocus = false

        func focusTerminal() {
            if Thread.isMainThread {
                focusTerminalNow()
            } else {
                performSelector(onMainThread: #selector(focusTerminalNow), with: nil, waitUntilDone: false)
            }
        }

        @objc func handleFocusRequest() {
            focusTerminal()
        }

        func focusTerminalIfNeeded() {
            guard !didInitialFocus else { return }
            didInitialFocus = true
            focusTerminal()
        }

        @objc private func focusTerminalNow() {
            guard let terminalView else { return }
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let view = ObservedLocalProcessTerminalView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.onUserInputBytes = { data in
            DispatchQueue.main.async {
                onUserInput?(data)
            }
        }
        view.onOutputBytes = { data in
            guard let text = String(bytes: data, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async {
                onOutput?(text)
            }
        }

        let command = "cd \(shellQuoted(workspacePath)) && \(launchCommand)"
        DispatchQueue.main.async {
            view.startProcess(executable: "/bin/zsh", args: ["-ilc", command])
        }
        context.coordinator.terminalView = view

        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let coordinator = context.coordinator
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.handleFocusRequest),
            name: .tuiRequestFocus,
            object: nil
        )

        DispatchQueue.main.async {
            coordinator.focusTerminalIfNeeded()
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .tuiRequestFocus, object: nil)
    }

    private func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private final class ObservedLocalProcessTerminalView: LocalProcessTerminalView {
    var onUserInputBytes: ((ArraySlice<UInt8>) -> Void)?
    var onOutputBytes: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInputBytes?(data)
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutputBytes?(slice)
        super.dataReceived(slice: slice)
    }
}

private extension Notification.Name {
    static let tuiRequestFocus = Notification.Name("tui.request.focus")
}
#endif
