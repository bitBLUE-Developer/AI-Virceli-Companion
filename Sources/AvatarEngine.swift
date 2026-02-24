import Foundation

enum AvatarEngine: String, CaseIterable, Identifiable {
    case web
    case unity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .web:
            return "Web"
        case .unity:
            return "Unity"
        }
    }

    var symbolName: String {
        switch self {
        case .web:
            return "globe"
        case .unity:
            return "cube.transparent"
        }
    }
}

