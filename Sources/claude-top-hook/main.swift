import ClaudeTopCore
import Darwin
import Foundation

// Claude Code runs this for each hook event. It must never block Claude, never
// write to stdout (Claude Code parses stdout), and always exit 0 (other codes
// show a hook error in the transcript).

let startMs = Int64(Date().timeIntervalSince1970 * 1000)
let debug = ProcessInfo.processInfo.environment["CLAUDE_TOP_DEBUG"] != nil

signal(SIGPIPE, SIG_IGN)

// Stdin can stay open if Claude Code misbehaves. Do not wait for it forever.
DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
    log("watchdog: gave up after 2 s")
    exit(0)
}

func log(_ message: String) {
    guard debug else { return }
    let directory = Paths.logsDirectory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("hook.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: file)
    }
}

func readStdin(limit: Int) -> Data {
    var data = Data()
    let handle = FileHandle.standardInput
    while data.count < limit {
        let chunk = handle.readData(ofLength: min(65_536, limit - data.count))
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return (info.kp_eproc.e_ppid, name)
}

let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "-sh", "-bash", "-zsh"]

/// Claude Code runs hooks through a shell, so the direct parent exits with the hook.
func claudePID() -> pid_t? {
    var pid = getppid()
    for _ in 0..<6 {
        guard let info = processInfo(pid) else { return nil }
        if !shells.contains(info.name) { return pid }
        guard info.ppid > 1 else { return nil }
        pid = info.ppid
    }
    return nil
}

func send(_ data: Data, to path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        log("connect failed: \(String(cString: strerror(errno)))")
        return false
    }

    return data.withUnsafeBytes { raw -> Bool in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written <= 0 {
                log("write failed: \(String(cString: strerror(errno)))")
                return false
            }
            offset += written
        }
        return true
    }
}

let input = readStdin(limit: 1_048_576)
guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
    log("stdin is not a JSON object (\(input.count) bytes)")
    exit(0)
}

let environment = ProcessInfo.processInfo.environment
var context: [String: Any] = ["ppid": Int(getppid())]
if let pid = claudePID() { context["claude_pid"] = Int(pid) }
if let value = environment["TERM_PROGRAM"] { context["term_program"] = value }
if let value = environment["ITERM_SESSION_ID"] { context["iterm_session_id"] = value }
if let value = environment["__CFBundleIdentifier"] { context["bundle_id"] = value }

let envelope: [String: Any] = [
    "v": 1,
    "ts_ms": startMs,
    "payload": payload,
    "context": context,
]

guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { exit(0) }
let sent = send(data, to: Paths.socketPath)
log("\(payload["hook_event_name"] ?? "?") sent=\(sent) bytes=\(data.count)")
exit(0)
