import Foundation
import PicasaCore

/// Settings ▸ Library ▸ Watch folders: new items found on their own, at launch (what was added while
/// the app was closed) and while it runs (see PicasaCore/AutoScan.swift for the method).
@MainActor
final class AutoScanState {
    var started = false
    var watcher: FolderWatcher?
    var plan = Library.WatchPlan()
    /// All roots when watching started: watching starts again when they change (folder added/removed).
    var roots: Set<String> = []
    /// Waiting for the running job to end.
    var folders = Set<String>(), recursive = Set<String>(), full = Set<String>()
    /// Checkpoint to save once what is waiting has been scanned.
    var eventId: UInt64?
    var periodic: Task<Void, Never>?
    var lastPeriodic = Date()
    var isEmpty: Bool { folders.isEmpty && recursive.isEmpty && full.isEmpty }
}

extension AppModel {
    /// Network shares (no journal) are rescanned this often.
    static let periodicRescan: TimeInterval = 15 * 60

    /// `catchUp`: replay (or rescan) what changed since the last checkpoint — at launch, or when watching
    /// is turned back on. Otherwise (roots added/removed) the new roots were just scanned by that job.
    func startWatching(catchUp: Bool) async {
        stopWatching()
        guard watchFolders else { return }
        let lib = library
        guard let plan = try? await lib.watchPlan(catchUp: catchUp) else { return }
        let st = autoScan
        st.started = true
        st.plan = plan
        st.roots = Set(((try? await lib.roots()) ?? []).map(\.path))
        st.full.formUnion(plan.fullRescan)
        // Nothing to replay from: once the full rescans are done, the checkpoint is "now".
        if plan.sinceWhen == nil { st.eventId = max(st.eventId ?? 0, plan.now) }
        if !plan.watched.isEmpty {
            // From `now` rather than "since now": nothing is missed between the plan and the start.
            let w = FolderWatcher(roots: plan.watched, sinceWhen: plan.sinceWhen ?? plan.now,
                                  ignoring: [Self.libraryURL.path]) { [weak self] batch in
                Task { @MainActor in self?.received(batch) }
            }
            if w.start() {
                st.watcher = w
            } else {
                st.plan.periodic += plan.watched // no stream: followed like a network share
            }
        }
        st.lastPeriodic = Date()
        st.periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                let st = self.autoScan
                if !st.plan.periodic.isEmpty, Date().timeIntervalSince(st.lastPeriodic) >= Self.periodicRescan {
                    st.lastPeriodic = Date()
                    st.full.formUnion(st.plan.periodic.filter { FileManager.default.fileExists(atPath: $0) })
                    self.drainWatch()
                }
            }
        }
        drainWatch()
    }

    func stopWatching() {
        let st = autoScan
        st.watcher?.stop()
        st.watcher = nil
        st.periodic?.cancel()
        st.periodic = nil
        st.started = false
    }

    private func received(_ b: FolderWatcher.Batch) {
        let st = autoScan
        guard st.started else { return }
        if b.reset { st.full.formUnion(st.plan.watched) }
        st.folders.formUnion(b.folders)
        st.recursive.formUnion(b.recursive)
        if b.lastEventId > 0 { st.eventId = b.reset ? b.lastEventId : max(st.eventId ?? 0, b.lastEventId) }
        drainWatch()
    }

    /// Called when a job ends: watching follows the roots, then what waited is scanned.
    func watchAfterJob() async {
        guard watchFolders, autoScan.started else { return }
        let roots = Set(((try? await library.roots()) ?? []).map(\.path))
        if roots != autoScan.roots { await startWatching(catchUp: false) } else { drainWatch() }
    }

    /// Scans what changed, then indexes and analyses what is new — unless another job runs (it waits).
    func drainWatch() {
        let st = autoScan
        guard st.started, job == nil else { return }
        let lib = library
        let volumes = st.plan.volumes
        if st.isEmpty {
            // Only a checkpoint to move (the replay found nothing): no job for that.
            if let id = st.eventId {
                st.eventId = nil
                Task { try? await lib.saveWatchCheckpoint(eventId: id, volumes: volumes) }
            }
            return
        }
        let full = st.full
        let under = { (p: String) in full.contains { p == $0 || p.hasPrefix($0 + "/") } }
        let folders = st.folders.filter { !under($0) }
        let recursive = st.recursive.filter { !under($0) }
        let id = st.eventId
        st.folders = []; st.recursive = []; st.full = []; st.eventId = nil
        runJob("Scanning new items") { lib, report in
            var added = 0
            if !full.isEmpty {
                for r in try await Pipeline.scan(lib, roots: full.sorted().map { URL(fileURLWithPath: $0) }, progress: report) {
                    added += r.result.added + r.result.updated
                }
            }
            if !folders.isEmpty || !recursive.isEmpty {
                let r = try await Scanner(library: lib).scan(folders: folders, recursive: recursive, progress: report)
                added += r.added + r.updated
            }
            if added > 0 { try await Self.index(lib, report) }
            if let id { try await lib.saveWatchCheckpoint(eventId: id, volumes: volumes) }
        }
    }
}
