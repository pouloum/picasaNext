import Foundation
import IOKit
import IOKit.ps

// Adapts index / analyze to the machine and to the disk holding the photos.
//  1. A starting plan from what is detected (cores, memory, file system, SSD / hard disk / network).
//  2. Tuned during the run: the number of parallel files follows the measured photos/s, batches aim
//     at one commit every ~1.5 s, and heat / battery / Low Power Mode put a cap on it.
//  3. The tuned values are saved per volume and profile (settings table) for the next run.

/// Chosen by the user (CLI `--profile`, app menu Processing ▸ Performance Profile); remembered per library.
public enum ThroughputProfile: String, CaseIterable, Sendable {
    /// Detected from the disk of each photo folder.
    case auto
    /// Forced kinds, when the detection is wrong (an SSD in a USB enclosure reported as a hard disk…).
    case ssd, hdd, nas
    /// One or two files at a time: leaves the machine (and the fans) alone.
    case eco

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .ssd: "SSD"
        case .hdd: "Hard disk"
        case .nas: "Network (NAS)"
        case .eco: "Economy"
        }
    }
}

public enum StorageKind: String, Sendable {
    case internalSSD = "internal SSD", externalSSD = "external SSD", hdd = "hard disk", network, unknown
}

/// The volume holding a path, as detected (statfs, URL resource values, IOKit "Medium Type").
public struct VolumeInfo: Sendable, Equatable {
    public var key: String        // volume UUID, or mount point when there is none (network shares)
    public var mountPoint: String
    public var fileSystem: String // apfs, hfs, exfat, smbfs, nfs…
    public var kind: StorageKind

    static let networkFileSystems: Set<String> = ["smbfs", "nfs", "afpfs", "webdav", "cifs", "ftp", "macfuse", "osxfuse"]

    public static func of(_ path: String) -> VolumeInfo { VolumeCache.shared.info(for: path) }

    static func detect(_ path: String) -> VolumeInfo {
        var st = statfs()
        // The path itself may be gone (volume unplugged): use the closest existing parent.
        var p = path
        while statfs(p, &st) != 0 {
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return VolumeInfo(key: path, mountPoint: path, fileSystem: "?", kind: .unknown) }
            p = parent
        }
        let fs = withUnsafeBytes(of: st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let mount = withUnsafeBytes(of: st.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let device = withUnsafeBytes(of: st.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let values = try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeUUIDStringKey])
        let key = values?.volumeUUIDString ?? mount
        if networkFileSystems.contains(fs) || values?.volumeIsLocal == false {
            return VolumeInfo(key: key, mountPoint: mount, fileSystem: fs, kind: .network)
        }
        let kind: StorageKind
        switch isSolidState(device: device) {
        case true?: kind = values?.volumeIsInternal == false ? .externalSSD : .internalSSD
        case false?: kind = .hdd
        // Unknown medium: internal disks of current Macs are SSDs; external ones are treated as hard disks
        // (the cautious choice: 2 parallel reads).
        case nil: kind = values?.volumeIsInternal == true ? .internalSSD : .hdd
        }
        return VolumeInfo(key: key, mountPoint: mount, fileSystem: fs, kind: kind)
    }

    /// IOKit "Device Characteristics" ▸ "Medium Type" of the disk under a BSD device (/dev/disk3s1),
    /// found by walking up from the volume (APFS volume → container → physical disk).
    static func isSolidState(device: String) -> Bool? {
        guard device.hasPrefix("/dev/") else { return nil }
        let bsd = String(device.dropFirst(5))
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let dc = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Device Characteristics" as CFString,
                                                       kCFAllocatorDefault, options) as? [String: Any],
              let medium = dc["Medium Type"] as? String else { return nil }
        return medium == "Solid State"
    }
}

/// Detection is a few system calls per volume: done once per volume and process.
final class VolumeCache: @unchecked Sendable {
    static let shared = VolumeCache()
    private let lock = NSLock()
    private var byMount: [String: VolumeInfo] = [:]

    func info(for path: String) -> VolumeInfo {
        // Cheap lookup first: the mount point from statfs, without the IOKit walk.
        var st = statfs()
        var mount = ""
        if statfs(path, &st) == 0 || statfs((path as NSString).deletingLastPathComponent, &st) == 0 {
            mount = withUnsafeBytes(of: st.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        lock.lock(); defer { lock.unlock() }
        if !mount.isEmpty, let v = byMount[mount] { return v }
        let v = VolumeInfo.detect(path)
        if !mount.isEmpty { byMount[mount] = v }
        return v
    }
}

/// The machine: cores, memory, and what limits it right now (heat, battery, Low Power Mode).
public struct HostInfo: Sendable {
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var memoryGB: Double

    public init(performanceCores: Int, efficiencyCores: Int, memoryGB: Double) {
        (self.performanceCores, self.efficiencyCores, self.memoryGB) = (performanceCores, efficiencyCores, memoryGB)
    }

    public static let current: HostInfo = {
        func sysctlInt(_ name: String) -> Int? {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        }
        let all = ProcessInfo.processInfo.activeProcessorCount
        let perf = sysctlInt("hw.perflevel0.physicalcpu") ?? all // Intel: no levels, every core counts
        let eff = sysctlInt("hw.perflevel1.physicalcpu") ?? max(0, all - perf)
        return HostInfo(performanceCores: max(1, perf), efficiencyCores: eff,
                        memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
    }()

    public var cores: Int { performanceCores + efficiencyCores }

    /// Parallel files allowed right now: heat first, then battery and Low Power Mode.
    public static func currentCap(_ maximum: Int) -> Int {
        var cap = maximum
        switch ProcessInfo.processInfo.thermalState {
        case .critical: cap = 1
        case .serious: cap = min(cap, 2)
        case .fair: cap = min(cap, max(2, maximum * 3 / 4))
        default: break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled || onBattery { cap = min(cap, max(1, maximum / 2)) }
        return max(1, cap)
    }

    public static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    public var summary: String {
        let c = efficiencyCores > 0 ? "\(performanceCores)P+\(efficiencyCores)E cores" : "\(performanceCores) cores"
        return "\(c), \(Int(memoryGB.rounded())) GB"
    }
}

/// What a run does with its files: reading metadata, making thumbnails, or the Vision analysis
/// (each tuned and saved on its own: their costs per file differ).
public enum ThroughputStage: String, Sendable { case metadata, thumbnails, analysis }

/// Starting point and bounds for one volume, profile and stage.
public struct ThroughputPlan: Sendable, Equatable {
    public var concurrency: Int
    public var minConcurrency: Int
    public var maxConcurrency: Int
    public var batch: Int
    /// Tune the concurrency from the measured throughput (off for Economy).
    public var adaptive: Bool
    /// Hard disk: files of a batch read in path order (fewer head moves).
    public var sortByPath: Bool

    public init(concurrency: Int, minConcurrency: Int, maxConcurrency: Int, batch: Int, adaptive: Bool, sortByPath: Bool) {
        (self.concurrency, self.minConcurrency, self.maxConcurrency) = (concurrency, minConcurrency, maxConcurrency)
        (self.batch, self.adaptive, self.sortByPath) = (batch, adaptive, sortByPath)
    }

    /// Disk kind → parallel reads, then the CPU / Neural Engine / memory limits of the analysis.
    public static func make(profile: ThroughputProfile, volume: StorageKind, stage: ThroughputStage, host: HostInfo = .current) -> ThroughputPlan {
        let kind: StorageKind = switch profile {
        case .auto: volume == .unknown ? .hdd : volume
        case .ssd: volume == .externalSSD ? .externalSSD : .internalSSD
        case .hdd: .hdd
        case .nas: .network
        case .eco: volume
        }
        // Reads: what the disk sustains.
        var (start, low, high, sort) = switch kind {
        case .internalSSD: (host.performanceCores, 2, max(2, host.cores), false)
        case .externalSSD: (4, 2, 8, false)
        case .hdd, .unknown: (2, 1, 2, true)
        case .network: (4, 2, 8, false)
        }
        if stage == .analysis {
            // Vision runs on the Neural Engine / GPU: more tasks than about half the performance cores
            // only queue there. Each task holds a 1600 px image plus the models (~300 MB to be safe).
            let cpu = max(1, host.performanceCores / 2)
            let memory = max(1, Int(host.memoryGB * 1024 / 300))
            high = max(1, min(high, host.performanceCores, memory))
            start = min(start, cpu, high)
            low = min(low, start)
        } else {
            high = min(high, max(2, host.cores))
        }
        if profile == .eco {
            return ThroughputPlan(concurrency: 1, minConcurrency: 1, maxConcurrency: min(2, high), batch: 4, adaptive: false, sortByPath: sort)
        }
        start = max(low, min(start, high))
        return ThroughputPlan(concurrency: start, minConcurrency: low, maxConcurrency: high, batch: max(8, start * 2),
                              adaptive: low < high, sortByPath: sort)
    }
}

/// Hill climbing on photos/s: one more parallel file while it helps (+5 %), one less when it hurts
/// (−5 %), and batches sized for one commit every `targetSeconds`. Measured over at least
/// `windowSeconds` of work (one batch is too noisy: a video or a RAW among JPEGs).
public struct AdaptiveTuner: Sendable {
    public private(set) var plan: ThroughputPlan
    public private(set) var concurrency: Int
    public private(set) var batch: Int
    public var targetSeconds = 1.5
    public var windowSeconds = 4.0
    public static let maxBatch = 64

    private var window: (items: Int, seconds: Double) = (0, 0)
    private var lastRate: Double?
    private var step = 1

    public init(plan: ThroughputPlan, saved: (concurrency: Int, batch: Int)? = nil) {
        self.plan = plan
        concurrency = min(plan.maxConcurrency, max(plan.minConcurrency, saved?.concurrency ?? plan.concurrency))
        batch = min(Self.maxBatch, max(concurrency, saved?.batch ?? plan.batch))
    }

    /// The concurrency to use for the next batch: the tuned one, under the heat / power cap.
    public var effectiveConcurrency: Int { min(concurrency, HostInfo.currentCap(plan.maxConcurrency)) }

    /// After a batch: `items` files done in `seconds` (wall time, commit included).
    public mutating func record(items: Int, seconds: Double) {
        guard items > 0, seconds > 0 else { return }
        // Batch: aim at one commit every targetSeconds, half-way each time (smooth), never fewer
        // files than run in parallel (workers would idle).
        let ideal = Double(items) * targetSeconds / seconds
        batch = min(Self.maxBatch, max(concurrency, Int(((Double(batch) + ideal) / 2).rounded())))
        guard plan.adaptive else { return }
        window.items += items
        window.seconds += seconds
        guard window.seconds >= windowSeconds else { return }
        let rate = Double(window.items) / window.seconds
        window = (0, 0)
        if let last = lastRate {
            if rate < last * 0.95 { step = -step }      // worse: go back the other way
            else if rate <= last * 1.05 {               // flat: the cheaper setting is as good
                step = -1
            }
        }
        lastRate = rate
        concurrency = min(plan.maxConcurrency, max(plan.minConcurrency, concurrency + step))
    }
}

/// One run's tuning: a tuner per volume (photos of a NAS and of the internal disk do not share
/// numbers), saved at the end for the next run.
public final class ThroughputSession: @unchecked Sendable {
    let library: Library
    let stage: ThroughputStage
    let profile: ThroughputProfile
    private var tuners: [String: AdaptiveTuner] = [:]
    private var current: String?
    private var started = Date()
    private var lastSave = Date()
    /// Called once per volume when its plan is made (the CLI prints it).
    public var onPlan: (@Sendable (String) -> Void)?

    public init(library: Library, stage: ThroughputStage, profile: ThroughputProfile) {
        self.library = library
        self.stage = stage
        self.profile = profile
    }

    /// Files to fetch for the next batch (the current volume's tuner).
    public var batch: Int { current.flatMap { tuners[$0]?.batch } ?? 8 }

    /// Before processing a batch: picks the tuner of the batch's volume (the first file's) and
    /// returns the concurrency to run it with, and the files in the order to read them.
    public func begin<T>(_ work: [T], path: (T) -> String) async -> (concurrency: Int, work: [T]) {
        guard let first = work.first else { return (1, work) }
        // Saved along the way too, so a run stopped by an unplugged disk keeps what it learnt.
        if Date().timeIntervalSince(lastSave) > 30 { await save() }
        let volume = VolumeInfo.of(path(first))
        if tuners[volume.key] == nil {
            let plan = ThroughputPlan.make(profile: profile, volume: volume.kind, stage: stage)
            let saved = try? await library.savedTuning(stage: stage, profile: profile, volume: volume.key)
            let tuner = AdaptiveTuner(plan: plan, saved: saved)
            tuners[volume.key] = tuner
            onPlan?("\(stage.rawValue): \(volume.mountPoint) \(volume.fileSystem) \(volume.kind.rawValue) [\(profile.rawValue)] → "
                    + "\(tuner.concurrency) parallel (\(plan.minConcurrency)–\(plan.maxConcurrency))\(plan.adaptive ? ", tuned" : ""), "
                    + "batches of \(tuner.batch)\(saved != nil ? " (from last run)" : "")\(plan.sortByPath ? ", path order" : "")")
        }
        current = volume.key
        started = Date()
        let t = tuners[volume.key]!
        let ordered = t.plan.sortByPath ? work.sorted { path($0) < path($1) } : work
        return (t.effectiveConcurrency, ordered)
    }

    /// After the batch is processed and stored.
    public func end(items: Int) {
        guard let key = current else { return }
        tuners[key]?.record(items: items, seconds: Date().timeIntervalSince(started))
    }

    /// Remembers the tuned values for the next run.
    public func save() async {
        lastSave = Date()
        for (key, t) in tuners {
            try? await library.saveTuning(stage: stage, profile: profile, volume: key, concurrency: t.concurrency, batch: t.batch)
        }
    }
}

extension Library {
    /// The profile chosen in the app or with `picasa-cli profile NAME` (Automatic by default).
    public func throughputProfile() throws -> ThroughputProfile {
        try setting("throughput.profile").flatMap(ThroughputProfile.init) ?? .auto
    }

    public func setThroughputProfile(_ p: ThroughputProfile) throws {
        try setSetting("throughput.profile", p.rawValue)
    }

    /// Values tuned by the last run on this volume (nil: none yet).
    public func tuning(stage: ThroughputStage, profile: ThroughputProfile, volume: String) throws -> (concurrency: Int, batch: Int)? {
        try savedTuning(stage: stage, profile: profile, volume: volume)
    }

    func savedTuning(stage: ThroughputStage, profile: ThroughputProfile, volume: String) throws -> (concurrency: Int, batch: Int)? {
        guard let v = try setting("throughput.\(stage.rawValue).\(profile.rawValue).\(volume)") else { return nil }
        let p = v.split(separator: ",").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }

    func saveTuning(stage: ThroughputStage, profile: ThroughputProfile, volume: String, concurrency: Int, batch: Int) throws {
        try setSetting("throughput.\(stage.rawValue).\(profile.rawValue).\(volume)", "\(concurrency),\(batch)")
    }

    /// Forgets the tuned values (after a hardware change, or to measure again from the defaults).
    public func resetTuning() throws -> Int {
        try db.run("DELETE FROM settings WHERE key LIKE 'throughput.metadata.%' OR key LIKE 'throughput.thumbnails.%' OR key LIKE 'throughput.analysis.%'")
        return db.changes
    }
}
