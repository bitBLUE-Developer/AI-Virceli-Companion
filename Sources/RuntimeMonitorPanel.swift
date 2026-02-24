import AppKit
import SwiftUI

struct RuntimeMonitorEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

@MainActor
final class RuntimeMonitor: ObservableObject {
    @Published private(set) var entries: [RuntimeMonitorEntry] = []

    func log(_ message: String) {
        entries.append(RuntimeMonitorEntry(timestamp: Date(), message: message))
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var joinedText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries
            .map { "[\(formatter.string(from: $0.timestamp))] \($0.message)" }
            .joined(separator: "\n")
    }
}

struct RuntimeMonitorPanel: View {
    @ObservedObject var monitor: RuntimeMonitor
    let startupFlowState: StartupFlowState
    let activeEntryTab: EntryTab
    let workspacePath: String?
    let shellConnected: Bool
    let shellConnecting: Bool
    let claudeStage: ClaudeSessionStage
    let shellError: String?
    let bridgeStatus: String
    let unityStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runtime Monitor")
                .font(.headline)

            Group {
                monitorRow("startup", startupFlowState.rawValue)
                monitorRow("entryTab", activeEntryTab.rawValue)
                monitorRow("workspace", workspacePath ?? "not selected")
                monitorRow("shell", shellConnected ? "on" : "off")
                monitorRow("connecting", shellConnecting ? "yes" : "no")
                monitorRow("claudeStage", claudeStage.rawValue)
                monitorRow("shellError", shellError ?? "-")
                monitorRow("bridge", bridgeStatus)
                monitorRow("unity", unityStatus)
            }

            HStack(spacing: 8) {
                Button("Copy Logs") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(monitor.joinedText, forType: .string)
                }
                Button("Clear Logs") {
                    monitor.clear()
                }
            }

            Divider()
                .overlay(.white.opacity(0.2))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(monitor.entries) { entry in
                            Text(lineText(for: entry))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.82))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("monitor-end")
                    }
                }
                .onChange(of: monitor.entries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("monitor-end", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func monitorRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(key):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lineText(for entry: RuntimeMonitorEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return "[\(formatter.string(from: entry.timestamp))] \(entry.message)"
    }
}
