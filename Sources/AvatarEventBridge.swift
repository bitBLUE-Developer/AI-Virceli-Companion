import Foundation
import Combine
import Network

@MainActor
final class AvatarEventBridge: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "bridge: idle"
    @Published private(set) var lastEventText = ""

    private let port: Int
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "avatar.bridge.tcp")

    init(port: Int = 18400) {
        self.port = port
    }

    func startIfNeeded() {
        guard !isRunning else { return }
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                statusText = "bridge: failed (invalid port \(port))"
                isRunning = false
                return
            }
            var parameters = NWParameters.tcp
            if let loopback = IPv4Address("127.0.0.1") {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: nwPort)
            } else {
                let host = NWEndpoint.Host("127.0.0.1")
                parameters.requiredLocalEndpoint = .hostPort(host: host, port: nwPort)
            }
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.statusText = "bridge: running (tcp://127.0.0.1:\(self.port))"
                    case .failed(let error):
                        self.statusText = "bridge: failed (\(error.localizedDescription))"
                        self.isRunning = false
                    case .cancelled:
                        self.statusText = "bridge: stopped"
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            isRunning = false
            statusText = "bridge: failed (\(error.localizedDescription))"
        }
    }

    func stop() {
        for client in clients.values {
            client.cancel()
        }
        clients.removeAll(keepingCapacity: false)
        listener?.cancel()
        listener = nil
        statusText = "bridge: stopped"
        isRunning = false
    }

    func sendAvatarState(_ state: String) {
        sendEvent(type: "avatar_state", payload: ["state": state])
    }

    func sendCameraControl(
        zoom: Double,
        panX: Double,
        panY: Double,
        orbitX: Double,
        orbitY: Double,
        reset: Bool = false
    ) {
        sendEvent(
            type: "avatar_camera",
            payload: [
                "zoom": String(format: "%.4f", zoom),
                "panX": String(format: "%.4f", panX),
                "panY": String(format: "%.4f", panY),
                "orbitX": String(format: "%.4f", orbitX),
                "orbitY": String(format: "%.4f", orbitY),
                "reset": reset ? "true" : "false"
            ]
        )
    }

    func sendPanelSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        sendEvent(
            type: "avatar_panel_size",
            payload: [
                "width": "\(width)",
                "height": "\(height)"
            ]
        )
    }

    private func sendEvent(type: String, payload: [String: String]) {
        guard isRunning else { return }
        var body = payload
        body["type"] = type
        body["ts"] = String(Int(Date().timeIntervalSince1970))

        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []),
              var text = String(data: data, encoding: .utf8)
        else {
            return
        }
        text += "\n"
        lastEventText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let bytes = Array(text.utf8)
        let content = Data(bytes)
        for connection in clients.values {
            connection.send(content: content, completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                Task { @MainActor in
                    self.statusText = "bridge: send error (\(error.localizedDescription))"
                }
            })
        }
    }

    private func accept(connection: NWConnection) {
        let id = UUID()
        clients[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.statusText = "bridge: client connected (\(self.clients.count))"
                    self.sendEvent(type: "avatar_ready", payload: ["ok": "true", "engine": "swift-host"])
                    self.receiveLoop(connection: connection, id: id)
                case .failed(let error):
                    self.clients[id] = nil
                    self.statusText = "bridge: client failed (\(error.localizedDescription))"
                case .cancelled:
                    self.clients[id] = nil
                    self.statusText = "bridge: client disconnected (\(self.clients.count))"
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.clients[id] = nil
                    self.statusText = "bridge: receive error (\(error.localizedDescription))"
                }
                return
            }

            if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self.lastEventText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if isComplete {
                Task { @MainActor in
                    self.clients[id] = nil
                    self.statusText = "bridge: client disconnected (\(self.clients.count))"
                }
                return
            }

            Task { @MainActor in
                self.receiveLoop(connection: connection, id: id)
            }
        }
    }
}
