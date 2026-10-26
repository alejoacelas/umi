import Darwin
import Foundation

/// A WebSocket client over a Unix domain socket: what `codex app-server --listen unix://PATH`
/// speaks (one JSON-RPC message per text frame). Codex's own interface attaches to the same
/// socket (`codex resume THREAD --remote unix://PATH`), so a session's server can be driven by
/// Umi and shown live at once (AG-6, AG-9).
///
/// Only what that needs: the upgrade handshake, masked text frames out, text/continuation,
/// ping/pong and close frames in. Reads happen on a thread of their own; `onMessage` gets
/// every complete message in order, `onClose` once at the end.
final class UmiUnixWebSocket: @unchecked Sendable {
    private let fd: Int32
    /// Frames are written in order on the socket's own queue, never the caller's: a server that
    /// stops reading blocks only this writer (and too much waiting closes the connection).
    private let writeQueue = DispatchQueue(label: "dev.umi.codex.websocket.write")
    private var fdClosed = false          // touched only on writeQueue
    private var pendingBytes = 0          // under stateLock
    private static let maxPendingBytes = 32 * 1024 * 1024
    private var closed = false
    private let stateLock = NSLock()
    private let onMessage: (Data) -> Void
    private let onClose: () -> Void

    struct ConnectError: Error, CustomStringConvertible { let description: String }

    /// Connect, retrying while the server creates its socket, and upgrade. Blocks the caller.
    init(path: String, timeout: TimeInterval, onMessage: @escaping (Data) -> Void, onClose: @escaping () -> Void) throws {
        self.onMessage = onMessage
        self.onClose = onClose
        let deadline = Date().addingTimeInterval(timeout)
        var descriptor: Int32 = -1
        while true {
            descriptor = Self.connect(path)
            if descriptor >= 0 { break }
            if Date() > deadline { throw ConnectError(description: "couldn't connect to \(path)") }
            usleep(50_000)
        }
        fd = descriptor
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var key = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&key, key.count)
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(Data(key).base64EncodedString())\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard Self.writeAll(fd, Data(request.utf8)) else {
            Darwin.close(fd)
            throw ConnectError(description: "couldn't write the WebSocket handshake")
        }
        // The answer's headers, then frames (which may already be in the same read).
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        let end = Data("\r\n\r\n".utf8)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.range(of: end) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                Darwin.close(fd)
                throw ConnectError(description: "the server closed the connection during the handshake")
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let headerEnd = buffer.range(of: end)!
        let status = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        guard status.hasPrefix("HTTP/1.1 101") else {
            Darwin.close(fd)
            throw ConnectError(description: "the server refused the WebSocket upgrade: \(status.prefix(80))")
        }
        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rest = Data(buffer[headerEnd.upperBound...])
        let thread = Thread { [self] in readLoop(initial: rest) }
        thread.name = "umi-codex-websocket"
        thread.start()
    }

    private static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    // MARK: Sending

    /// Send one text message. False once the connection is gone.
    @discardableResult
    func send(_ payload: Data) -> Bool {
        frame(opcode: 0x1, payload)
    }

    private func frame(opcode: UInt8, _ payload: Data) -> Bool {
        var header = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 {
            header.append(0x80 | UInt8(n))
        } else if n < 65536 {
            header.append(0x80 | 126)
            header.append(UInt8(n >> 8)); header.append(UInt8(n & 0xff))
        } else {
            header.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xff)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&mask, 4)
        header.append(contentsOf: mask)
        var masked = Data(count: n)
        payload.withUnsafeBytes { src in
            masked.withUnsafeMutableBytes { dst in
                let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                for i in 0..<n { d[i] = s[i] ^ mask[i & 3] }
            }
        }
        let bytes = header + masked
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return false
        }
        pendingBytes += bytes.count
        let overflow = pendingBytes > Self.maxPendingBytes
        stateLock.unlock()
        if overflow {
            // The server has stopped reading: give up on it rather than queue without end.
            close()
            return false
        }
        let fd = self.fd
        writeQueue.async { [weak self] in
            guard let self, !self.fdClosed else { return }
            let ok = Self.writeAll(fd, bytes)
            self.stateLock.lock()
            self.pendingBytes -= bytes.count
            self.stateLock.unlock()
            if !ok { self.close() }
        }
        return true
    }

    func close() {
        stateLock.lock()
        let was = closed
        closed = true
        stateLock.unlock()
        if !was { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: Reading

    private func readLoop(initial: Data) {
        var buffer = initial
        var message = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        func need(_ count: Int) -> Bool {
            while buffer.count < count {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                buffer.append(contentsOf: chunk[0..<n])
            }
            return true
        }
        loop: while true {
            guard need(2) else { break }
            let b0 = buffer[buffer.startIndex], b1 = buffer[buffer.startIndex + 1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0f
            let masked = b1 & 0x80 != 0
            var length = UInt64(b1 & 0x7f)
            var offset = 2
            if length == 126 {
                guard need(4) else { break }
                length = UInt64(buffer[buffer.startIndex + 2]) << 8 | UInt64(buffer[buffer.startIndex + 3])
                offset = 4
            } else if length == 127 {
                guard need(10) else { break }
                length = 0
                for i in 0..<8 { length = length << 8 | UInt64(buffer[buffer.startIndex + 2 + i]) }
                offset = 10
            }
            let maskLength = masked ? 4 : 0
            let total = offset + maskLength + Int(length)
            guard need(total) else { break }
            var payload = Data(buffer[(buffer.startIndex + offset + maskLength)..<(buffer.startIndex + total)])
            if masked {
                let key = Array(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + 4)])
                payload = Data(payload.enumerated().map { $0.element ^ key[$0.offset & 3] })
            }
            buffer.removeFirst(total)
            switch opcode {
            case 0x0, 0x1, 0x2:
                message.append(payload)
                if fin {
                    onMessage(message)
                    message = Data()
                }
            case 0x8:
                _ = frame(opcode: 0x8, Data())
                break loop
            case 0x9:
                _ = frame(opcode: 0xA, payload)
            default:
                break
            }
        }
        stateLock.lock()
        closed = true
        stateLock.unlock()
        // A writer blocked on a full buffer is woken by the shutdown; the descriptor is closed
        // after whatever it was doing, on its queue.
        let descriptor = fd
        shutdown(descriptor, SHUT_RDWR)
        writeQueue.async { [self] in
            fdClosed = true
            Darwin.close(descriptor)
        }
        onClose()
    }
}
