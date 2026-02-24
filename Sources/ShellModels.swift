import Foundation
import AppKit

struct TerminalPreset: Identifiable {
    let id: String
    let name: String
    let fontName: String
    let fontSize: Double
    let inputTextColor: NSColor
    let outputTextColor: NSColor
    let backgroundColor: NSColor
}

struct CustomTerminalTheme: Identifiable, Codable {
    let id: String
    let name: String
    let fontName: String
    let fontSize: Double
    let inputTextHex: String
    let outputTextHex: String
    let backgroundHex: String
}

enum TerminalStyleTarget {
    case inputText
    case outputText
    case background
}

enum ClaudeSessionStage: String {
    case disconnected
    case preparingShell
    case loginRequired
    case authenticating
    case trustPrompt
    case readyToLaunch
    case running
}

enum ChatRole {
    case user
    case assistant
    case system
}

enum ClaudeStepStatus: Sendable {
    case running
    case success
    case failure
}

struct ClaudeLiveStep: Identifiable, Sendable {
    let id = UUID()
    let title: String
    var status: ClaudeStepStatus
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String
}

struct ClaudeResumeSession: Identifiable, Codable, Sendable {
    let id: String
    var label: String?
    let savedAt: Date

    var displayName: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }
}

struct TerminalEntry: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let isError: Bool
    let source: TerminalEntrySource
}

enum TerminalEntrySource: Sendable {
    case terminal
    case tui
}
