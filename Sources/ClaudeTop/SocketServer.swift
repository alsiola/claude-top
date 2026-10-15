import ClaudeTopCore
import Darwin
import Foundation

struct SocketError: Error, CustomStringConvertible {
    let description: String
}

final class SocketServer {
    private let queue = DispatchQueue(label: "claude-top.socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var path = ""
    private let onMessage: @Sendable (Data) -> Void

    init(onMessage: @escaping @Sendable (Data) -> Void) {
        self.onMessage = onMessage
    }

    func start(path: String) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(directory, 0o700)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(description: "socket(): \(String(cString: strerror(errno)))") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw SocketError(description: "The socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SocketError(description: "bind(\(path)): \(message)")
        }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw SocketError(description: "listen(): \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if !path.isEmpty { unlink(path) }
    }

    private func acceptAll() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            let onMessage = self.onMessage
            DispatchQueue.global(qos: .userInitiated).async {
                if let data = Self.readAll(client), !data.isEmpty {
                    onMessage(data)
                }
            }
        }
    }

    private static func readAll(_ fd: Int32) -> Data? {
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 2_097_152 {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
