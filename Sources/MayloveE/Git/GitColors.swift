import AppKit

/// File name colors for Git status, following IntelliJ IDEA.
extension GitFileChange.Kind {
    var color: NSColor {
        switch self {
        case .added: return .systemGreen
        case .modified, .renamed: return .systemBlue
        case .deleted: return .secondaryLabelColor
        case .untracked: return .systemBrown
        case .conflicted: return .systemRed
        }
    }
}

/// Change bar colors in the editor gutter and diff viewer.
extension LineHunk.Kind {
    var color: NSColor {
        switch self {
        case .inserted: return .systemGreen
        case .modified: return .systemBlue
        case .deleted: return .systemGray
        }
    }
}
