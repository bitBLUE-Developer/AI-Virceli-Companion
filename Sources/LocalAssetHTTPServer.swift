import Foundation

@MainActor
final class LocalAssetHTTPServer {
    static let shared = LocalAssetHTTPServer()

    private var process: Process?
    private var activePort: Int?
    private var activeRoot: URL?
    private var lastFailure: String?

    func startIfNeeded(projectRoot: URL, status: (String) -> Void) -> URL? {
        if let activePort, let activeRoot, activeRoot.path == projectRoot.path {
            return URL(string: "http://127.0.0.1:\(activePort)")
        }

        stop()

        let ports = [8741, 8742, 8743, 8744, 8745, 8746]
        let launchers: [([String], String)] = [
            (["/usr/bin/python3"], "/usr/bin/python3"),
            (["/opt/homebrew/bin/python3"], "/opt/homebrew/bin/python3"),
            (["/usr/bin/env", "python3"], "/usr/bin/env python3")
        ]

        for port in ports {
            for (launcher, label) in launchers {
                guard let exec = launcher.first else { continue }
                if exec != "/usr/bin/env", !FileManager.default.isExecutableFile(atPath: exec) {
                    continue
                }

                let p = Process()
                p.executableURL = URL(fileURLWithPath: exec)
                p.arguments = Array(launcher.dropFirst()) + ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
                p.currentDirectoryURL = projectRoot
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err

                do {
                    try p.run()
                    Thread.sleep(forTimeInterval: 0.35)
                    if p.isRunning {
                        process = p
                        activePort = port
                        activeRoot = projectRoot
                        lastFailure = nil
                        status("avatar: localhost server on :\(port)")
                        return URL(string: "http://127.0.0.1:\(port)")
                    }

                    let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !errText.isEmpty {
                        lastFailure = "\(label): \(errText)"
                    } else {
                        lastFailure = "\(label): exited immediately"
                    }
                } catch {
                    lastFailure = "\(label): \(error.localizedDescription)"
                    continue
                }
            }
        }

        if let lastFailure, !lastFailure.isEmpty {
            status("avatar: localhost server failed (\(lastFailure))")
        } else {
            status("avatar: localhost server failed")
        }
        return nil
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        activePort = nil
        activeRoot = nil
    }
}
