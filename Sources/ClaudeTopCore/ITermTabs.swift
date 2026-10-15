import Foundation

public struct ITermTab: Equatable, Sendable {
    public var windowIndex: Int
    public var tabIndex: Int
    public var title: String

    public init(windowIndex: Int, tabIndex: Int, title: String) {
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.title = title
    }

    /// Claude Code adds a status glyph and " (claude)" to the title. The list
    /// shows its own status, so both are removed.
    public var displayTitle: String {
        var text = Substring(title)
        while let first = text.first, !(first.isLetter || first.isNumber) { text = text.dropFirst() }
        let suffix = " (claude)"
        if text.hasSuffix(suffix) { text = text.dropLast(suffix.count) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// `ITERM_SESSION_ID` has the form `w0t1p0:<UUID>`.
public enum ITermSessionID {
    public static func uuid(from value: String?) -> String? {
        guard let value, let uuid = value.split(separator: ":").last.map(String.init) else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef-")
        guard !uuid.isEmpty, uuid.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return uuid
    }

    /// The tab position when the shell started, counted from 1. Later tab moves
    /// do not change it, so use it only when iTerm2 cannot give the live position.
    public static func startTabNumber(from value: String?) -> Int? {
        guard let prefix = value?.split(separator: ":").first,
              let t = prefix.firstIndex(of: "t"),
              let p = prefix.firstIndex(of: "p"),
              t < p,
              let index = Int(prefix[prefix.index(after: t)..<p])
        else { return nil }
        return index + 1
    }
}

public enum ITermListing {
    public static let fieldSeparator: Character = "\u{1F}"

    /// Parses lines of `uuid<US>window<US>tab<US>title`, as the app's AppleScript writes them.
    public static func parse(_ text: String) -> [String: ITermTab] {
        var tabs: [String: ITermTab] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let window = Int(fields[1]),
                  let tab = Int(fields[2])
            else { continue }
            tabs[String(fields[0])] = ITermTab(windowIndex: window, tabIndex: tab, title: String(fields[3]))
        }
        return tabs
    }
}
