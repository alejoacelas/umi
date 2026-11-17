// umi-next-attach <session-id>: show a daemon session in this terminal.
//
// Raw mode, then: replay of the current screen, live output, stdin → the
// session, SIGWINCH → resize. Exits with the session's exit code when its
// process exits. Closing or killing this program leaves the session running.
import Darwin
import Foundation
import UmiC

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1, !args[0].hasPrefix("-") else {
    eprint("usage: umi-next-attach <session-id>")
    exit(2)
}

let sock = connectDaemon()
guard sock >= 0 else {
    eprint("umi-next-attach: no daemon at \(Paths.socket)")
    exit(255)
}

var cols: UInt16 = 80, rows: UInt16 = 24
let isTTY = isatty(0) != 0
if isTTY { var c: UInt16 = 0, r: UInt16 = 0; if umi_get_winsize(0, &c, &r) == 0, c > 0, r > 0 { cols = c; rows = r } }

writeAll(sock, encodeJSON(["op": "attach", "id": args[0], "cols": Int(cols), "rows": Int(rows)]))
var reader = FrameReader()
guard let (t, payload) = readFrame(sock, &reader), t == .json, let resp = decodeJSON(payload) else {
    eprint("umi-next-attach: daemon closed the connection")
    exit(255)
}
guard resp["ok"] as? Bool == true else {
    eprint("umi-next-attach: \(resp["error"] as? String ?? "attach failed")")
    exit(1)
}

if isTTY { umi_tty_raw(0) }
func finish(_ code: Int32) -> Never {
    if isTTY { umi_tty_restore(0) }
    exit(code)
}

var winch: [Int32] = [0, 0]
pipe(&winch)
_ = fcntl(winch[0], F_SETFL, O_NONBLOCK); _ = fcntl(winch[1], F_SETFL, O_NONBLOCK)
umi_install_sigwinch(winch[1])
signal(SIGPIPE, SIG_IGN)

var buf = [UInt8](repeating: 0, count: 1 << 16)
var stdinOpen = true

func handleFrames() {
    while let (type, payload) = reader.next() {
        switch type {
        case .output:
            if !writeAll(1, payload) { finish(0) }  // our terminal is gone
        case .exit:
            finish(payload.count >= 4 ? Int32(bitPattern: readBE32(payload[...], 0)) : 0)
        default:
            break
        }
    }
}
handleFrames()  // the replay may have arrived with the attach reply

while true {
    var fds = [pollfd(fd: sock, events: Int16(POLLIN), revents: 0),
               pollfd(fd: winch[0], events: Int16(POLLIN), revents: 0),
               pollfd(fd: stdinOpen ? 0 : -1, events: Int16(POLLIN), revents: 0)]
    if poll(&fds, 3, -1) < 0 { if errno == EINTR { continue }; finish(255) }

    if fds[0].revents != 0 {
        let n = buf.withUnsafeMutableBytes { read(sock, $0.baseAddress!, $0.count) }
        if n <= 0 && !(n < 0 && errno == EINTR) {
            if isTTY { umi_tty_restore(0) }
            eprint("\r\numi-next-attach: lost the daemon")
            exit(255)
        }
        if n > 0 {
            buf.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            handleFrames()
        }
    }
    if fds[1].revents != 0 {
        var b = [UInt8](repeating: 0, count: 64)
        while read(winch[0], &b, 64) > 0 {}
        var c: UInt16 = 0, r: UInt16 = 0
        if umi_get_winsize(0, &c, &r) == 0, c > 0, r > 0 {
            writeAll(sock, encodeFrame(.resize, be16(c) + be16(r)))
        }
    }
    if fds[2].revents != 0 {
        let n = buf.withUnsafeMutableBytes { read(0, $0.baseAddress!, $0.count) }
        if n > 0 {
            if !writeAll(sock, encodeFrame(.input, Array(buf[0..<n]))) { finish(255) }
        } else if !(n < 0 && (errno == EINTR || errno == EAGAIN)) {
            // Our terminal closed: detach, leaving the session running.
            finish(0)
        }
    }
}
