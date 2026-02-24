import SwiftUI

struct UnityCompanionPlaceholderView: View {
    let stateText: String
    let isWorking: Bool
    let isError: Bool
    @ObservedObject var bridge: AvatarEventBridge
    @ObservedObject var runtime: UnityRuntimeManager
    let onOrbit: (_ dx: CGFloat, _ dy: CGFloat, _ withPanModifier: Bool) -> Void
    let onZoom: (_ delta: CGFloat) -> Void
    let onResetCamera: () -> Void
    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnifyValue: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.cyan)
                Text("AI Virceli Companion (Phase 1)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(bridge.isRunning ? "ON" : "OFF")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((bridge.isRunning ? Color.green : Color.gray).opacity(0.28), in: Capsule())
                Text(runtime.isRunning ? "APP" : "APP OFF")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((runtime.isRunning ? Color.cyan : Color.gray).opacity(0.25), in: Capsule())
            }

            Text("state: \(stateText)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))

            Text(bridge.statusText)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.7))

            if !bridge.lastEventText.isEmpty {
                Text("last event: \(bridge.lastEventText)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
            }

            Text(runtime.statusText)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.72))

            if !runtime.selectedAppPath.isEmpty {
                Text(runtime.selectedAppPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("Select App") {
                    runtime.chooseUnityApp()
                }
                Button(runtime.isRunning ? "Relaunch App" : "Launch App") {
                    runtime.startIfNeeded()
                }
                Button("Stop App") {
                    runtime.stopIfRunning()
                }
                .disabled(!runtime.isRunning)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button(runtime.panelFollowEnabled ? "Detach Panel Follow" : "Attach Panel Follow") {
                    runtime.setPanelFollowEnabled(!runtime.panelFollowEnabled)
                }
                .buttonStyle(.borderedProminent)
                .tint(runtime.panelFollowEnabled ? .orange : .cyan)
                Button("Accessibility") {
                    runtime.openAccessibilitySettings()
                }
                .buttonStyle(.bordered)
                Toggle("Pin On Top", isOn: $runtime.pinOnTopEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .disabled(!runtime.panelFollowEnabled)
            }

            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.06))
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .foregroundStyle(.white.opacity(0.75))
                        Text("Camera Control Surface")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.88))
                        Text("Drag: orbit  |  Option+Drag: pan  |  Pinch: zoom  |  Double-click: reset")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.66))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                )
                .frame(height: 120)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let dx = value.translation.width - lastDragTranslation.width
                            let dy = value.translation.height - lastDragTranslation.height
                            let isPan = NSEvent.modifierFlags.contains(.option)
                            onOrbit(dx, dy, isPan)
                            lastDragTranslation = value.translation
                        }
                        .onEnded { _ in
                            lastDragTranslation = .zero
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value - lastMagnifyValue
                            onZoom(delta)
                            lastMagnifyValue = value
                        }
                        .onEnded { _ in
                            lastMagnifyValue = 1.0
                        }
                )
                .onTapGesture(count: 2) {
                    onResetCamera()
                }

            Spacer()

            Text(isError ? "Avatar error state detected." : (isWorking ? "Avatar working state detected." : "Avatar idle/listening state detected."))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
    }
}
