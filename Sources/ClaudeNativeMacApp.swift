import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ClaudeNativeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var shell = ShellSession()

    var body: some Scene {
        WindowGroup("Claude Native Mac") {
            RootView()
                .environmentObject(shell)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("Claude Code") {
                Button("Select Folder") {
                    NotificationCenter.default.post(name: .virceliSelectFolder, object: nil)
                }
                Divider()
                Button("Launch Claude Code") {
                    NotificationCenter.default.post(name: .virceliLaunchTUI, object: nil)
                }
                Button("Stop Claude Code") {
                    NotificationCenter.default.post(name: .virceliStopTUI, object: nil)
                }
            }
            CommandMenu("Resume") {
                Button("New Claude Session") {
                    NotificationCenter.default.post(name: .virceliNewSession, object: nil)
                }
                Button("Save Resume ID From Clipboard") {
                    NotificationCenter.default.post(name: .virceliSaveResumeFromClipboard, object: nil)
                }
                if shell.resumeSessions.isEmpty {
                    Text("No saved resume sessions")
                } else {
                    Divider()
                    ForEach(shell.resumeSessions) { session in
                        Menu(session.displayName) {
                            Button("Resume") {
                                NotificationCenter.default.post(name: .virceliResumeRun, object: session.id)
                            }
                            Button("Edit Label") {
                                NotificationCenter.default.post(name: .virceliResumeEditLabel, object: session.id)
                            }
                            Divider()
                            Button("Delete Session") {
                                NotificationCenter.default.post(name: .virceliResumeDelete, object: session.id)
                            }
                        }
                    }
                    Divider()
                    Button("Clear Saved Sessions") {
                        NotificationCenter.default.post(name: .virceliResumeClearAll, object: nil)
                    }
                }
            }
            CommandMenu("AI Virceli") {
                Button("Select App") {
                    NotificationCenter.default.post(name: .virceliSelectApp, object: nil)
                }
                Button("Launch/Relaunch App") {
                    NotificationCenter.default.post(name: .virceliLaunchApp, object: nil)
                }
                Button("Stop App") {
                    NotificationCenter.default.post(name: .virceliStopApp, object: nil)
                }
                Divider()
                Button("Attach/Detach Panel Follow") {
                    NotificationCenter.default.post(name: .virceliToggleAttach, object: nil)
                }
                Menu("Dock Side") {
                    Button("Left") {
                        NotificationCenter.default.post(name: .virceliDockLeft, object: nil)
                    }
                    Button("Right") {
                        NotificationCenter.default.post(name: .virceliDockRight, object: nil)
                    }
                }
            }
            CommandMenu("System") {
                Toggle("Always On Top", isOn: Binding(
                    get: { shell.alwaysOnTop },
                    set: { shell.alwaysOnTop = $0 }
                ))
                Toggle("Click-through", isOn: Binding(
                    get: { shell.clickThrough },
                    set: { shell.clickThrough = $0 }
                ))
                Divider()
                Button("Reset Saved Paths") {
                    NotificationCenter.default.post(name: .virceliResetSavedPaths, object: nil)
                }
                Button("Reset Avatar Camera") {
                    NotificationCenter.default.post(name: .virceliResetCamera, object: nil)
                }
            }
        }
    }
}
