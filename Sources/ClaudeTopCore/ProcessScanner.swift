import Darwin
import Foundation

public struct ClaudeProcess: Equatable, Sendable {
    public var pid: Int32
    public var cwd: String?
    public var itermSessionID: String?

    public init(pid: Int32, cwd: String?, itermSessionID: String?) {
        self.pid = pid
        self.cwd = cwd
        self.itermSessionID = itermSessionID
    }
}

/// Finds running Claude Code processes, so that a session shows in the list
/// before its first hook event (for example after the app restarts).
public enum ProcessScanner {
    public static let processName = "claude"

    public static func claudeProcesses() -> [ClaudeProcess] {
        processIDs(named: processName).map { pid in
            ClaudeProcess(
                pid: pid,
                cwd: workingDirectory(of: pid),
                itermSessionID: environment(of: pid)["ITERM_SESSION_ID"]
            )
        }
    }

    public static func processIDs(named name: String) -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The process list can grow between the two calls.
        size += 16 * MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return processes.prefix(count).compactMap { process in
            let comm = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return comm == name ? process.kp_proc.p_pid : nil
        }
    }

    public static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// Reads KERN_PROCARGS2: argc, the executable path, argv, then the environment.
    public static func environment(of pid: Int32) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ buffer: [UInt8]) -> [String: String] {
        guard buffer.count > 4 else { return [:] }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4
        func skipNulls() { while index < buffer.count, buffer[index] == 0 { index += 1 } }
        func nextString() -> String? {
            guard index < buffer.count else { return nil }
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        _ = nextString()
        skipNulls()
        for _ in 0..<argc {
            _ = nextString()
            index += 1
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            index += 1
            if let equals = entry.firstIndex(of: "=") {
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
        }
        return environment
    }
}
