import Foundation
import Combine
import Darwin
import IOKit.ps

@MainActor
class SystemMonitor: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memory: Double = 0
    @Published var battery: Double = -1   // -1 = no battery (desktop)
    @Published var isCharging: Bool = false
    @Published var netUp: Double = 0      // bytes/s
    @Published var netDown: Double = 0

    private var timer: Timer?

    // CPU delta tracking
    private var prevCPUInfo: processor_info_array_t?
    private var prevNumCPUInfo: mach_msg_type_number_t = 0

    // Network delta tracking
    private var prevNetStats: (up: UInt64, down: UInt64) = (0, 0)
    private var prevNetTime = Date()

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    private func update() {
        cpu    = readCPU()
        memory = readMemory()
        let (lvl, chg) = readBattery()
        battery    = lvl
        isCharging = chg
        let (up, down) = readNet()
        netUp   = up
        netDown = down
    }

    // MARK: CPU — delta between measurements for accuracy

    private func readCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t!
        var numInfo: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                   &numCPUs, &cpuInfo, &numInfo) == KERN_SUCCESS else { return 0 }

        var usedDelta = 0.0, totalDelta = 0.0

        if let prev = prevCPUInfo {
            for i in 0..<Int(numCPUs) {
                let o = Int(CPU_STATE_MAX) * i
                func cur(_ s: Int32) -> Double { Double(cpuInfo[o + Int(s)]) }
                func prv(_ s: Int32) -> Double { Double(prev[o + Int(s)]) }
                let dUser   = cur(CPU_STATE_USER)   - prv(CPU_STATE_USER)
                let dSys    = cur(CPU_STATE_SYSTEM) - prv(CPU_STATE_SYSTEM)
                let dIdle   = cur(CPU_STATE_IDLE)   - prv(CPU_STATE_IDLE)
                let dNice   = cur(CPU_STATE_NICE)   - prv(CPU_STATE_NICE)
                usedDelta  += dUser + dSys + dNice
                totalDelta += dUser + dSys + dIdle + dNice
            }
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: prev)),
                          vm_size_t(Int(prevNumCPUInfo) * MemoryLayout<integer_t>.stride))
        }

        prevCPUInfo    = cpuInfo
        prevNumCPUInfo = numInfo
        return totalDelta > 0 ? usedDelta / totalDelta : 0
    }

    // MARK: Memory

    private func readMemory() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let ok = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return 0 }

        let pg = UInt64(vm_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.inactive_count)
                  + UInt64(stats.wire_count)) * pg

        var total: UInt64 = 0
        var sz = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &sz, nil, 0)
        return total > 0 ? Double(used) / Double(total) : 0
    }

    // MARK: Battery

    private func readBattery() -> (Double, Bool) {
        let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snap).takeRetainedValue() as! [CFTypeRef]
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, src)?
                    .takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let cap = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
            let chg = desc[kIOPSIsChargingKey] as? Bool ?? false
            return (cap < 0 ? -1 : Double(cap) / 100.0, chg)
        }
        return (-1, false)
    }

    // MARK: Network (bytes/s via sysctl)

    private func readNet() -> (up: Double, down: Double) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var totalUp: UInt64 = 0, totalDown: UInt64 = 0
        var ptr = 0
        while ptr + MemoryLayout<if_msghdr2>.size <= len {
            let header = buf.withUnsafeBytes { $0.load(fromByteOffset: ptr, as: if_msghdr2.self) }
            if header.ifm_type == RTM_IFINFO2 {
                totalUp   += header.ifm_data.ifi_obytes
                totalDown += header.ifm_data.ifi_ibytes
            }
            let msglen = Int(header.ifm_msglen)
            guard msglen > 0 else { break }
            ptr += msglen
        }

        let now = Date()
        let dt = now.timeIntervalSince(prevNetTime)
        let up   = dt > 0 ? Double(totalUp   > prevNetStats.up   ? totalUp   - prevNetStats.up   : 0) / dt : 0
        let down = dt > 0 ? Double(totalDown > prevNetStats.down ? totalDown - prevNetStats.down : 0) / dt : 0
        prevNetStats = (totalUp, totalDown)
        prevNetTime  = now
        return (up, down)
    }
}
