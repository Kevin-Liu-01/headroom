import Darwin
import Foundation

/// Reads system memory numbers from sysctl and Mach, and per-process numbers from libproc.
public enum SystemProbe {
    public static let gib = 1_073_741_824.0

    public static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return Int(Int32(truncatingIfNeeded: value))
        default: return Int(value)
        }
    }

    public static func totalBytes() -> UInt64 {
        UInt64(sysctlInt("hw.memsize") ?? 0)
    }

    /// kern.memorystatus_level: percent of memory the kernel counts as available.
    public static func freeLevel() -> Int {
        sysctlInt("kern.memorystatus_level") ?? 100
    }

    public static func pressure() -> Pressure {
        Pressure(sysctlLevel: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1)
    }

    public static func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private static let hostPort = mach_host_self()

    public static func compressedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(stats.compressor_page_count) * UInt64(vm_kernel_page_size)
    }

    public static func systemStats() -> SystemStats {
        let total = Double(totalBytes()) / gib
        let level = freeLevel()
        let sw = swap()
        return SystemStats(
            totalGB: Format.round2(total),
            freePercent: level,
            freeGB: Format.round2(total * Double(level) / 100),
            swapUsedGB: Format.round2(Double(sw.used) / gib),
            swapTotalGB: Format.round2(Double(sw.total) / gib),
            compressedGB: Format.round2(Double(compressedBytes()) / gib),
            pressure: pressure())
    }

    // MARK: libproc

    public static func allPids() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got))).filter { $0 > 0 }
    }

    public struct BSDInfo {
        public var ppid: Int32
        public var name: String
        public var startTime: Double
        public var stopped: Bool
        public var uid: UInt32
    }

    public static func bsdInfo(_ pid: Int32) -> BSDInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
            let s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return s
        }
        let comm = withUnsafeBytes(of: info.pbi_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return BSDInfo(
            ppid: Int32(bitPattern: info.pbi_ppid),
            name: name.isEmpty ? comm : name,
            startTime: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000,
            stopped: info.pbi_status == 4, // SSTOP
            uid: info.pbi_uid)
    }

    public static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Physical footprint in bytes from proc_pid_rusage (RUSAGE_INFO_V4), or nil when not readable.
    public static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard r == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// CPU time (user plus system) in seconds from proc_pid_rusage.
    public static func cpuSeconds(_ pid: Int32) -> Double? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard r == 0 else { return nil }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return ticks * Double(tb.numer) / Double(tb.denom) / 1_000_000_000
    }

    public static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return s.isEmpty ? nil : s
    }

    /// The argument vector from KERN_PROCARGS2. Only readable for the person's own processes.
    public static func args(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        size = min(size, 256 * 1024)
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        // Skip the executable path and the padding after it.
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var out: [String] = []
        while i < size, out.count < Int(argc), out.count < 64 {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            let s = String(decoding: buf[start..<i], as: UTF8.self)
            out.append(s.count > 300 ? String(s.prefix(300)) : s)
            i += 1
        }
        return out
    }
}
