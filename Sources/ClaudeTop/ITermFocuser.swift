import AppKit
import ClaudeTopCore

@MainActor
enum ITermFocuser {
    static let bundleID = "com.googlecode.iterm2"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func focus(_ context: HookContext?) {
        guard let uuid = ITermSessionID.uuid(from: context?.itermSessionID) else {
            activateITerm()
            return
        }
        let source = """
        tell application id "\(bundleID)"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if (unique id of aSession) is "\(uuid)" then
                            tell aWindow to select
                            tell aTab to select
                            tell aSession to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            activate
            return false
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { activateITerm() }
    }

    /// Returns nil when iTerm2 is not running, because a `tell` would start it.
    static func listTabs() -> [String: ITermTab]? {
        guard isRunning else { return nil }
        // "tab" is an iTerm2 class name, so the separators are made outside the tell block.
        let source = """
        set fieldSep to character id 31
        set lineSep to character id 10
        set output to ""
        tell application id "\(bundleID)"
            set windowIndex to 0
            repeat with aWindow in windows
                set windowIndex to windowIndex + 1
                set tabIndex to 0
                repeat with aTab in tabs of aWindow
                    set tabIndex to tabIndex + 1
                    repeat with aSession in sessions of aTab
                        set output to output & (unique id of aSession) & fieldSep & windowIndex & fieldSep & tabIndex & fieldSep & (name of aSession) & lineSep
                    end repeat
                end repeat
            end repeat
        end tell
        return output
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              error == nil,
              let text = result.stringValue
        else { return nil }
        return ITermListing.parse(text)
    }

    private static func activateITerm() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }
}
