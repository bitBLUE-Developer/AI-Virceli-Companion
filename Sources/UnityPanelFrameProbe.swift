import AppKit
import SwiftUI

struct UnityPanelFrameProbe: NSViewRepresentable {
    let onFrameChanged: (CGRect, NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onFrameChanged = onFrameChanged
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onFrameChanged = onFrameChanged
        nsView.report()
    }
}

final class ProbeView: NSView {
    var onFrameChanged: ((CGRect, NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    override func layout() {
        super.layout()
        report()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        report()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        report()
    }

    func report() {
        guard let onFrameChanged else { return }
        let frameInWindow = convert(bounds, to: nil)
        onFrameChanged(frameInWindow, window)
    }
}
