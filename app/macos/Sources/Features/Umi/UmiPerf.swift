import AppKit
import Darwin
import os

/// Performance records in `<state dir>/logs/perf/<day>.jsonl`, kept 30 days like the other day logs.
///
/// - `kind: "hang"`: the main thread did not run for 250 ms or more. A watchdog thread samples the
///   main thread's stack every 50 ms while it is blocked; `stacks` groups identical samples, the
///   commonest first, so the top stack is where the time went. A hang still going after 2 s is
///   written at once with `ongoing: true` (and again every 10 s), so a freeze that ends in a
///   force-quit is still recorded; the final record has the same `id`.
/// - `kind: "slow"`: a named operation (`UmiPerf.measure`) took 50 ms or more on the main thread.
/// - `kind: "resources"`: memory footprint, CPU time and thread count, every 10 minutes.
///
/// The same named operations are os_signpost intervals (subsystem `dev.umi.app`, category `perf`)
/// for Instruments.
final class UmiPerf: @unchecked Sendable {
    static let shared = UmiPerf()

    static let hangThreshold: UInt64 = 250_000_000
    static let slowThreshold: UInt64 = 50_000_000
    static let pollInterval: useconds_t = 50_000
    static let firstOngoingReport: UInt64 = 2_000_000_000
    static let ongoingReportEvery: UInt64 = 10_000_000_000
    static let resourcesEvery: UInt64 = 600_000_000_000
    static let maxFrames = 64
    static let maxSamples = 400

    static let signposts = OSLog(subsystem: "dev.umi.app", category: "perf")

    private let log = UmiDayLog(folder: "perf")
    private var lock = os_unfair_lock()
    private var started = false

    // Set on the main thread by `start()`.
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0

    // Shared between the watchdog and the main thread, under `lock`.
    private var pingSent: UInt64 = 0
    private var pingOutstanding = false
    private var pongAt: UInt64 = 0
    private var appActive = true

    // Watchdog-only state.
    private var hangID: String?
    private var hangStart: UInt64 = 0
    private var nextReport: UInt64 = 0
    private var samples: [[UInt]] = []
    private let frameBuffer = UnsafeMutablePointer<UInt>.allocate(capacity: UmiPerf.maxFrames)

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Start the watchdog. Call once, on the main thread, early in launch.
    @MainActor
    func start() {
        guard !started else { return }
        started = true
        mainThread = mach_thread_self()
        let me = pthread_self()
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(me))
        let thread = Thread { [self] in watch() }
        thread.name = "dev.umi.perf.watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: Named operations

    /// Time `body`; record it when it ran on the main thread for 50 ms or more.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ detail: @autoclosure () -> String? = nil, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: signposts)
        os_signpost(.begin, log: signposts, name: name, signpostID: id)
        let start = now()
        defer {
            let elapsed = now() - start
            os_signpost(.end, log: signposts, name: name, signpostID: id)
            if elapsed >= slowThreshold, Thread.isMainThread { shared.recordSlow("\(name)", detail(), elapsed) }
        }
        return try body()
    }

    /// The same for async work on the main actor: only the total time is known, so it is recorded
    /// as `async: true` (the main thread may have run other work while it waited).
    @MainActor
    static func measureAsync<T>(_ name: StaticString, _ detail: @autoclosure () -> String? = nil, _ body: () async throws -> T) async rethrows -> T {
        let id = OSSignpostID(log: signposts)
        os_signpost(.begin, log: signposts, name: name, signpostID: id)
        let start = now()
        defer {
            let elapsed = now() - start
            os_signpost(.end, log: signposts, name: name, signpostID: id)
            if elapsed >= slowThreshold { shared.recordSlow("\(name)", detail(), elapsed, async: true) }
        }
        return try await body()
    }

    func recordSlow(_ name: String, _ detail: String?, _ elapsed: UInt64, async: Bool = false) {
        var record: [String: Any] = ["kind": "slow", "name": name, "duration_ms": Self.ms(elapsed),
                                     "time": Self.timestamp(Date())]
        if let detail { record["detail"] = detail }
        if async { record["async"] = true }
        log.append(record, at: Date())
    }

    // MARK: Watchdog

    private func watch() {
        var nextResources = Self.now() + 60_000_000_000
        while true {
            usleep(Self.pollInterval)
            let t = Self.now()

            os_unfair_lock_lock(&lock)
            let outstanding = pingOutstanding
            let sent = pingSent
            let pong = pongAt
            let active = appActive
            if !outstanding {
                pingOutstanding = true
                pingSent = t
            }
            os_unfair_lock_unlock(&lock)

            if !outstanding {
                if hangID != nil { finishHang(end: pong, active: active) }
                DispatchQueue.main.async { [self] in
                    let isActive = NSApp?.isActive ?? true
                    os_unfair_lock_lock(&lock)
                    pingOutstanding = false
                    pongAt = Self.now()
                    appActive = isActive
                    os_unfair_lock_unlock(&lock)
                }
            } else if t - sent >= Self.hangThreshold {
                if hangID == nil {
                    hangID = UUID().uuidString.lowercased()
                    hangStart = sent
                    nextReport = sent + Self.firstOngoingReport
                    samples.removeAll(keepingCapacity: true)
                }
                if samples.count < Self.maxSamples, let stack = sampleMainStack() { samples.append(stack) }
                if t >= nextReport {
                    writeHang(duration: t - hangStart, ongoing: true, active: active)
                    nextReport = t + Self.ongoingReportEvery
                }
            }

            if t >= nextResources {
                writeResources()
                nextResources = t + Self.resourcesEvery
            }
        }
    }

    private func finishHang(end: UInt64, active: Bool) {
        writeHang(duration: end > hangStart ? end - hangStart : 0, ongoing: false, active: active)
        hangID = nil
        samples.removeAll(keepingCapacity: true)
    }

    private func writeHang(duration: UInt64, ongoing: Bool, active: Bool) {
        guard let id = hangID else { return }
        var groups: [[UInt]: Int] = [:]
        for stack in samples { groups[stack, default: 0] += 1 }
        let top = groups.sorted { $0.value > $1.value }.prefix(3)
        var record: [String: Any] = [
            "kind": "hang", "id": id, "duration_ms": Self.ms(duration), "time": Self.timestamp(Date()),
            "samples": samples.count, "app_active": active,
            "stacks": top.map { ["count": $0.value, "frames": $0.key.map(Self.symbolicate)] },
        ]
        if ongoing { record["ongoing"] = true }
        log.append(record, at: Date())
    }

    /// The main thread's return addresses, by walking its frame pointers while it is suspended.
    /// Nothing between suspend and resume may allocate or take a lock: the main thread could hold it.
    private func sampleMainStack() -> [UInt]? {
        guard mainThread != 0, thread_suspend(mainThread) == KERN_SUCCESS else { return nil }
        var count = 0
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        if got == KERN_SUCCESS {
            let mask: UInt = 0x0000_000F_FFFF_FFFF
            frameBuffer[count] = UInt(state.__pc) & mask; count += 1
            frameBuffer[count] = UInt(state.__lr) & mask; count += 1
            var fp = UInt(state.__fp)
            while count < Self.maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp & 7 == 0 {
                guard let frame = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = frame[0]
                let ret = frame[1] & mask
                if ret == 0 { break }
                frameBuffer[count] = ret; count += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        guard count > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: frameBuffer, count: count))
    }

    // MARK: Symbols

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let demangle: Demangle? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: Demangle.self)
    }()

    /// "image: symbol + offset", or "image + offset" when the address has no symbol
    /// (`atos -o <image> -l <load address>` can resolve those offline).
    static func symbolicate(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        guard let sname = info.dli_sname else { return String(format: "%@ + 0x%lx", image, address - base) }
        var name = String(cString: sname)
        if let demangle, let out = demangle(sname, strlen(sname), nil, nil, 0) {
            name = String(cString: out)
            free(out)
        }
        if name.count > 300 { name = String(name.prefix(300)) + "…" }
        return "\(image): \(name) + \(address - UInt(bitPattern: info.dli_saddr))"
    }

    // MARK: Resources

    private func writeResources() {
        var record: [String: Any] = ["kind": "resources", "time": Self.timestamp(Date())]
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS { record["footprint_mb"] = Double(info.phys_footprint) / 1_048_576 }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            record["cpu_seconds"] = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads {
            record["threads"] = Int(threadCount)
            for i in 0..<Int(threadCount) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride))
        }
        record["uptime_minutes"] = Double(Self.now()) / 60_000_000_000
        log.append(record, at: Date())
    }

    // MARK: Formatting

    static func ms(_ ns: UInt64) -> Int { Int(ns / 1_000_000) }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let formatterLock = NSLock()
    static func timestamp(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return isoFormatter.string(from: date)
    }
}
