// Shared by umi-next-daemon, umi-next-attach and umi-next-ctl: paths, the
// socket framing and small POSIX helpers. See PROTOCOL.md.
import Darwin
import Foundation
import UmiC

enum Paths {
    static var stateDir: String {
        if let d = ProcessInfo.processInfo.environment["UMI_NEXT_STATE_DIR"], !d.isEmpty {
            return d
        }
        return NSHomeDirectory() + "/Library/Application Support/Umi-next"
    }
    static var socket: String { stateDir + "/daemon.sock" }
    static var lock: String { stateDir + "/daemon.lock" }
    static var log: String { stateDir + "/daemon.log" }
}

/// Frame types. Every frame is: type (1 byte), payload length (u32 big
/// endian), payload.
enum Frame: UInt8 {
    case json = 0x4A    // 'J' request or response
    case input = 0x49   // 'I' attach → daemon: bytes for the session's pty
    case output = 0x4F  // 'O' daemon → attach: bytes for the client's terminal
    case resize = 0x57  // 'W' attach → daemon: cols u16, rows u16 (big endian)
    case exit = 0x58    // 'X' daemon → attach: exit code i32 (big endian)
}

func encodeFrame(_ type: Frame, _ payload: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(payload.count + 5)
    out.append(type.rawValue)
    let n = UInt32(payload.count)
    out.append(UInt8(n >> 24)); out.append(UInt8((n >> 16) & 0xff))
    out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff))
    out.append(contentsOf: payload)
    return out
}

func encodeJSON(_ obj: [String: Any]) -> [UInt8] {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    return encodeFrame(.json, [UInt8](data))
}

func decodeJSON(_ payload: [UInt8]) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any]
}

func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
}
func readBE16(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt16 {
    UInt16(b[b.startIndex + i]) << 8 | UInt16(b[b.startIndex + i + 1])
}
func readBE32(_ b: ArraySlice<UInt8>, _ i: Int) -> UInt32 {
    let s = b.startIndex + i
    return UInt32(b[s]) << 24 | UInt32(b[s + 1]) << 16 | UInt32(b[s + 2]) << 8 | UInt32(b[s + 3])
}

/// Accumulates bytes and yields complete frames.
struct FrameReader {
    var buf = [UInt8]()
    var start = 0

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        buf.append(contentsOf: bytes)
    }

    mutating func next() -> (Frame?, [UInt8])? {
        let avail = buf.count - start
        guard avail >= 5 else { compact(); return nil }
        let len = Int(readBE32(buf[start...], 1))
        guard avail >= 5 + len else { compact(); return nil }
        let type = Frame(rawValue: buf[start])
        let payload = Array(buf[(start + 5)..<(start + 5 + len)])
        start += 5 + len
        return (type, payload)
    }

    private mutating func compact() {
        if start > 0 {
            buf.removeFirst(start)
            start = 0
        }
    }
}

/// sockaddr_un for a path; nil if the path is too long.
func withUnixAddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < cap else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// Connect to the daemon's socket; -1 if nobody listens.
func connectDaemon() -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    let rc = withUnixAddr(Paths.socket) { connect(fd, $0, $1) } ?? -1
    if rc != 0 { close(fd); return -1 }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// Write everything (blocking fd). False on error.
@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
        if n < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                poll(&p, 1, 1000)
                continue
            }
            return false
        }
        off += n
    }
    return true
}

/// Read frames from a blocking fd until one complete frame arrives.
func readFrame(_ fd: Int32, _ reader: inout FrameReader) -> (Frame?, [UInt8])? {
    var tmp = [UInt8](repeating: 0, count: 65536)
    while true {
        if let f = reader.next() { return f }
        let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return nil }
        tmp.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
    }
}

func eprint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Screen text, styles, cursor and modes of a terminal, as reported by
/// `screen --json` and `render --json`.
func vtState(_ t: GhosttyTerminal) -> [String: Any] {
    var len = 0
    let p = umi_vt_plain(t, &len)
    let text = p.map { String(cString: $0) } ?? ""
    free(p)
    let sp = umi_vt_styles(t, &len)
    let styles = sp.map { String(cString: $0) } ?? ""
    free(sp)
    var i = UmiVtInfo()
    umi_vt_info(t, &i)
    return ["text": text, "styles": styles,
            "cursor": ["x": Int(i.cursor_x), "y": Int(i.cursor_y), "visible": i.cursor_visible],
            "cols": Int(i.cols), "rows": Int(i.rows), "alternate": i.alternate,
            "kitty_flags": Int(i.kitty_flags), "mouse_tracking": i.mouse_tracking,
            "bracketed_paste": i.bracketed_paste, "app_cursor_keys": i.app_cursor_keys]
}
