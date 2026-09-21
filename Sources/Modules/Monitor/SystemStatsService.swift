import Foundation
import Darwin

struct SystemSnapshot {
    var cpuUsage: Double = 0          // 0...1 across all cores
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var netBytesInPerSec: Double = 0
    var netBytesOutPerSec: Double = 0
}

/// Polls CPU, memory, disk and network counters on a timer.
/// CPU/network figures are deltas between successive samples.
@MainActor
final class SystemStatsService: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()

    private var timer: Timer?
    private var lastCPU: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    func start(interval: TimeInterval = 1.0) {
        sample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        var snap = SystemSnapshot()
        snap.cpuUsage = readCPU()
        (snap.memoryUsed, snap.memoryTotal) = readMemory()
        (snap.diskUsed, snap.diskTotal) = readDisk()
        (snap.netBytesInPerSec, snap.netBytesOutPerSec) = readNetwork()
        snapshot = snap
    }

    private func readCPU() -> Double {
        var numCPUs = natural_t(0)
        var cpuInfo: processor_info_array_t?
        var numCPUInfo = mach_msg_type_number_t(0)
        let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                      &numCPUs, &cpuInfo, &numCPUInfo)
        guard err == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        var user: UInt64 = 0, sys: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            user += UInt64(info[base + Int(CPU_STATE_USER)])
            sys += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
            nice += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        let prev = lastCPU
        lastCPU = (user, sys, idle, nice)
        guard let p = prev else { return 0 }
        let dUser = user - p.user, dSys = sys - p.sys, dIdle = idle - p.idle, dNice = nice - p.nice
        let total = dUser + dSys + dIdle + dNice
        return total == 0 ? 0 : Double(total - dIdle) / Double(total)
    }

    private func readMemory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let err = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard err == KERN_SUCCESS else { return (0, 0) }
        let page = UInt64(getpagesize())
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    private func readDisk() -> (used: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return (0, 0) }
        return (UInt64(total) - UInt64(free), UInt64(total))
    }

    private func readNetwork() -> (inPerSec: Double, outPerSec: Double) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(first) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = ptr.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        defer { lastNet = (rx, tx, now) }
        guard let p = lastNet else { return (0, 0) }
        let dt = now.timeIntervalSince(p.at)
        guard dt > 0 else { return (0, 0) }
        return (Double(rx - p.rx) / dt, Double(tx - p.tx) / dt)
    }
}
