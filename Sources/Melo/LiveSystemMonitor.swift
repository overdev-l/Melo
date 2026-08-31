import Darwin
import Foundation

struct MetricPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let value: Double

    var id: Date { date }
}

struct LiveMetricHistory: Equatable, Sendable {
    private(set) var cpu: [MetricPoint] = []
    private(set) var memory: [MetricPoint] = []
    private(set) var networkReceive: [MetricPoint] = []
    private(set) var networkSend: [MetricPoint] = []

    mutating func append(_ snapshot: LiveSystemSnapshot, limit: Int = 60) {
        cpu.append(MetricPoint(date: snapshot.date, value: snapshot.cpuUsage))
        memory.append(MetricPoint(date: snapshot.date, value: snapshot.memoryUsedPercent))
        networkReceive.append(MetricPoint(date: snapshot.date, value: snapshot.networkReceiveBytesPerSecond))
        networkSend.append(MetricPoint(date: snapshot.date, value: snapshot.networkSendBytesPerSecond))
        cpu = Array(cpu.suffix(limit))
        memory = Array(memory.suffix(limit))
        networkReceive = Array(networkReceive.suffix(limit))
        networkSend = Array(networkSend.suffix(limit))
    }
}

struct LiveSystemSnapshot: Equatable, Sendable {
    let date: Date
    let cpuUsage: Double
    let perCoreUsage: [Double]
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let memoryUsedPercent: Double
    let networkReceiveBytesPerSecond: Double
    let networkSendBytesPerSecond: Double
    let processes: [LiveProcess]
}

struct LiveProcess: Identifiable, Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
    let executablePath: String?
    let cpu: Double
    let memoryBytes: UInt64
    let isOwnedByCurrentUser: Bool
    let identity: ProcessIdentity

    var id: Int32 { pid }
    var canTerminate: Bool {
        isOwnedByCurrentUser && pid > 1 && pid != getpid()
    }
}

struct ProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let startTimeMicroseconds: UInt64

    static func current(pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard result == size else { return nil }
        let seconds = info.pbi_start_tvsec
        let microseconds = info.pbi_start_tvusec
        guard seconds <= UInt64.max / 1_000_000 else { return nil }
        return ProcessIdentity(
            pid: pid,
            startTimeMicroseconds: seconds * 1_000_000 + microseconds
        )
    }
}

enum ProcessTerminationOutcome: Equatable, Sendable {
    case terminatedGracefully
    case forceKilled
}

enum ProcessTerminationError: LocalizedError, Equatable {
    case protectedProcess
    case staleIdentity
    case signalFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .protectedProcess:
            "系统或其他用户的进程不能由 Melo 终止。"
        case .staleIdentity:
            "进程身份已经变化，已取消终止以避免影响新的进程。"
        case .signalFailed(let code):
            String(cString: strerror(code))
        }
    }
}

struct ProcessTerminationService: Sendable {
    func terminate(
        _ process: LiveProcess,
        gracePeriod: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> ProcessTerminationOutcome {
        guard process.canTerminate else { throw ProcessTerminationError.protectedProcess }
        guard ProcessIdentity.current(pid: process.pid) == process.identity else {
            throw ProcessTerminationError.staleIdentity
        }
        guard Darwin.kill(process.pid, SIGTERM) == 0 else {
            throw ProcessTerminationError.signalFailed(errno)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: gracePeriod)
        while clock.now < deadline {
            if ProcessIdentity.current(pid: process.pid) != process.identity {
                return .terminatedGracefully
            }
            try await Task.sleep(for: pollInterval)
        }
        guard ProcessIdentity.current(pid: process.pid) == process.identity else {
            return .terminatedGracefully
        }
        guard Darwin.kill(process.pid, SIGKILL) == 0 else {
            throw ProcessTerminationError.signalFailed(errno)
        }
        return .forceKilled
    }
}

actor NativeSystemSampler {
    private struct CPUTicks: Sendable {
        let active: UInt64
        let total: UInt64
    }

    private struct NetworkCounters: Sendable {
        let received: UInt64
        let sent: UInt64
    }

    private var previousCPUTicks: [CPUTicks]?
    private var previousNetworkCounters: NetworkCounters?
    private var previousProcessTimes: [Int32: UInt64] = [:]
    private var previousDate: Date?

    func sample() -> LiveSystemSnapshot {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(previousDate ?? now), 0.001)
        let perCoreTicks = readCPUTicks()
        let perCoreUsage = calculateCPUUsage(current: perCoreTicks)
        let cpuUsage = perCoreUsage.isEmpty
            ? 0
            : perCoreUsage.reduce(0, +) / Double(perCoreUsage.count)
        let memory = readMemory()
        let networkCounters = readNetworkCounters()
        let network = calculateNetworkRates(current: networkCounters, elapsed: elapsed)
        let processes = readProcesses(elapsed: elapsed)

        previousCPUTicks = perCoreTicks
        previousNetworkCounters = networkCounters
        previousDate = now

        return LiveSystemSnapshot(
            date: now,
            cpuUsage: cpuUsage,
            perCoreUsage: perCoreUsage,
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            memoryUsedPercent: memory.percent,
            networkReceiveBytesPerSecond: network.received,
            networkSendBytesPerSecond: network.sent,
            processes: processes
        )
    }

    private func readCPUTicks() -> [CPUTicks] {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let values = UnsafeBufferPointer(start: info, count: Int(infoCount))
        return (0..<Int(processorCount)).map { index in
            let offset = index * Int(CPU_STATE_MAX)
            let user = UInt64(max(values[offset + Int(CPU_STATE_USER)], 0))
            let system = UInt64(max(values[offset + Int(CPU_STATE_SYSTEM)], 0))
            let nice = UInt64(max(values[offset + Int(CPU_STATE_NICE)], 0))
            let idle = UInt64(max(values[offset + Int(CPU_STATE_IDLE)], 0))
            return CPUTicks(active: user + system + nice, total: user + system + nice + idle)
        }
    }

    private func calculateCPUUsage(current: [CPUTicks]) -> [Double] {
        guard let previousCPUTicks, previousCPUTicks.count == current.count else {
            return Array(repeating: 0, count: current.count)
        }
        return zip(current, previousCPUTicks).map { current, previous in
            let activeDelta = current.active >= previous.active ? current.active - previous.active : 0
            let totalDelta = current.total >= previous.total ? current.total - previous.total : 0
            guard totalDelta > 0 else { return 0 }
            return min(max(Double(activeDelta) / Double(totalDelta) * 100, 0), 100)
        }
    }

    private func readMemory() -> (used: UInt64, total: UInt64, percent: Double) {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Foundation.ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total, 0) }

        let page = UInt64(pageSize)
        let active = UInt64(statistics.active_count) * page
        let wired = UInt64(statistics.wire_count) * page
        let compressed = UInt64(statistics.compressor_page_count) * page
        let used = min(active + wired + compressed, total)
        let percent = total > 0 ? Double(used) / Double(total) * 100 : 0
        return (used, total, percent)
    }

    private func readNetworkCounters() -> NetworkCounters {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else {
            return NetworkCounters(received: 0, sent: 0)
        }
        defer { freeifaddrs(firstAddress) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let address = current {
            let interface = address.pointee
            if let socketAddress = interface.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_LINK),
               let dataPointer = interface.ifa_data {
                let name = String(cString: interface.ifa_name)
                let flags = Int32(interface.ifa_flags)
                let isUp = flags & IFF_UP != 0
                let isLoopback = flags & IFF_LOOPBACK != 0
                if isUp, !isLoopback, name.hasPrefix("en") {
                    let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                    received += UInt64(data.ifi_ibytes)
                    sent += UInt64(data.ifi_obytes)
                }
            }
            current = interface.ifa_next
        }
        return NetworkCounters(received: received, sent: sent)
    }

    private func calculateNetworkRates(
        current: NetworkCounters,
        elapsed: TimeInterval
    ) -> (received: Double, sent: Double) {
        guard let previousNetworkCounters else { return (0, 0) }
        let receivedDelta = current.received >= previousNetworkCounters.received
            ? current.received - previousNetworkCounters.received
            : 0
        let sentDelta = current.sent >= previousNetworkCounters.sent
            ? current.sent - previousNetworkCounters.sent
            : 0
        return (Double(receivedDelta) / elapsed, Double(sentDelta) / elapsed)
    }

    private func readProcesses(elapsed: TimeInterval) -> [LiveProcess] {
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 256)
        var pids = [pid_t](repeating: 0, count: estimatedCount + 64)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.stride, pids.count)
        let currentUID = geteuid()
        var nextTimes: [Int32: UInt64] = [:]
        var processes: [LiveProcess] = []

        for pid in pids.prefix(count) where pid > 0 {
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            let taskResult = withUnsafeMutablePointer(to: &task) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskSize)
            }
            guard taskResult == taskSize else { continue }

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let bsdResult = withUnsafeMutablePointer(to: &bsd) {
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, bsdSize)
            }
            guard bsdResult == bsdSize else { continue }

            let totalTime = UInt64(task.pti_total_user) + UInt64(task.pti_total_system)
            nextTimes[pid] = totalTime
            let previousTime = previousProcessTimes[pid] ?? totalTime
            let timeDelta = totalTime >= previousTime ? totalTime - previousTime : 0
            let cpu = min(max(Double(timeDelta) / 1_000_000_000 / elapsed * 100, 0), 10_000)
            let memory = UInt64(task.pti_resident_size)
            guard cpu >= 0.1 || memory >= 16 * 1_024 * 1_024 else { continue }

            let name = processName(pid: pid)
            processes.append(
                LiveProcess(
                    pid: pid,
                    parentPID: Int32(bitPattern: bsd.pbi_ppid),
                    name: name.isEmpty ? "PID \(pid)" : name,
                    executablePath: processPath(pid: pid),
                    cpu: cpu,
                    memoryBytes: memory,
                    isOwnedByCurrentUser: bsd.pbi_uid == currentUID,
                    identity: ProcessIdentity(
                        pid: pid,
                        startTimeMicroseconds: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
                    )
                )
            )
        }

        previousProcessTimes = nextTimes
        return processes
            .sorted {
                if $0.cpu == $1.cpu { return $0.memoryBytes > $1.memoryBytes }
                return $0.cpu > $1.cpu
            }
            .prefix(40)
            .map { $0 }
    }

    private func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    private func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
