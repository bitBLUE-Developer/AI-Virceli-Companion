import SwiftUI

struct TerminalStyleEditorSheet: View {
    @EnvironmentObject private var shell: ShellSession
    @Environment(\.dismiss) private var dismiss

    let modal: TerminalStyleEditorModal
    @State private var hexValue: String = ""
    @State private var rgbValue: String = ""
    @State private var red: Double = 255
    @State private var green: Double = 255
    @State private var blue: Double = 255
    @State private var draftColor: NSColor = .white
    @State private var draftFontSize: Double = 13
    @State private var applyErrorMessage: String?

    private let paletteHexes: [String] = [
        "#282A36", "#1D1F21", "#002B36", "#3B4252", "#282828",
        "#F8F8F2", "#D8DEE9", "#93A1A1", "#FFD866", "#A6E22E",
        "#61AFEF", "#FF79C6", "#C678DD", "#E5C07B", "#98C379"
    ]

    private var target: TerminalStyleTarget {
        switch modal {
        case .inputText:
            .inputText
        case .outputText:
            .outputText
        case .background:
            .background
        }
    }

    private var title: String {
        switch modal {
        case .inputText:
            "Input Text Style"
        case .outputText:
            "Output Text Style"
        case .background:
            "Background Style"
        }
    }

    private var supportsFontSize: Bool {
        modal != .background
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }

            if supportsFontSize {
                HStack {
                    Text("Text Size")
                    Slider(value: $draftFontSize, in: 10...22)
                    Text("\(Int(draftFontSize))")
                        .frame(width: 28)
                }
            }

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(draftColor))
                    .frame(width: 42, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.45), lineWidth: 1))
                Text(draftColor.hexRGB)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text("Palette")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 26))], spacing: 8) {
                ForEach(paletteHexes, id: \.self) { hex in
                    Button {
                        guard let color = NSColor.fromHex(hex) else { return }
                        updateDraftColor(color)
                    } label: {
                        Circle()
                            .fill(Color(NSColor.fromHex(hex) ?? .white))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(.white.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
            }

            TextField("HEX (#RRGGBB)", text: $hexValue)
                .textFieldStyle(.roundedBorder)

            TextField("RGB (r,g,b)", text: $rgbValue)
                .textFieldStyle(.roundedBorder)

            Group {
                channelSlider("R", value: $red)
                channelSlider("G", value: $green)
                channelSlider("B", value: $blue)
            }
            .onChange(of: red) { _, _ in syncDraftFromSliders() }
            .onChange(of: green) { _, _ in syncDraftFromSliders() }
            .onChange(of: blue) { _, _ in syncDraftFromSliders() }

            if let applyErrorMessage {
                Text(applyErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Apply") {
                applyDraft()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            let currentColor = shell.color(for: target)
            updateDraftColor(currentColor)
            draftFontSize = shell.terminalFontSize
        }
    }

    private func channelSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
                .frame(width: 14, alignment: .leading)
            Slider(value: value, in: 0...255, step: 1)
            Text("\(Int(value.wrappedValue))")
                .frame(width: 34, alignment: .trailing)
                .font(.caption.monospacedDigit())
        }
    }

    private func syncDraftFromSliders() {
        let sliderColor = NSColor(
            calibratedRed: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: 1
        )
        draftColor = sliderColor
        hexValue = sliderColor.hexRGB
        rgbValue = sliderColor.rgbString
    }

    private func updateDraftColor(_ color: NSColor) {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        draftColor = converted
        hexValue = converted.hexRGB
        rgbValue = converted.rgbString
        red = Double(Int(round(converted.redComponent * 255)))
        green = Double(Int(round(converted.greenComponent * 255)))
        blue = Double(Int(round(converted.blueComponent * 255)))
        applyErrorMessage = nil
    }

    private func applyDraft() {
        if let hexColor = NSColor.fromHex(hexValue) {
            draftColor = hexColor
        } else if let rgbColor = NSColor.fromRGBString(rgbValue) {
            draftColor = rgbColor
        } else {
            let sliderColor = NSColor(
                calibratedRed: red / 255,
                green: green / 255,
                blue: blue / 255,
                alpha: 1
            )
            draftColor = sliderColor
        }

        shell.setColor(draftColor, for: target)
        if supportsFontSize {
            shell.setTerminalFontSize(draftFontSize)
        }
        let color = draftColor.usingColorSpace(.deviceRGB) ?? draftColor
        hexValue = color.hexRGB
        rgbValue = color.rgbString
        red = Double(Int(round(color.redComponent * 255)))
        green = Double(Int(round(color.greenComponent * 255)))
        blue = Double(Int(round(color.blueComponent * 255)))
        applyErrorMessage = nil
    }
}
