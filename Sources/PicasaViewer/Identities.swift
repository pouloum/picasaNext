import AppKit
import PicasaCore
import SwiftUI

extension IdentityKind {
    var title: String { self == .face ? "People" : "Animals" }
    var ownerWord: String { self == .face ? "person" : "pet" }
    var itemWord: String { self == .face ? "face" : "animal" }
    var placeholder: String { self == .face ? "person.fill" : "pawprint.fill" }
}

/// People and Animals: the same screen for both (IdentityKind).
///
/// Top bar: Groups (cards) or Photos (grid), a year, and what to show — named, to identify,
/// ignored. Unidentified groups are hidden by default (a badge says how many are waiting).
/// As in Picasa, cards can be dragged onto each other: a person onto a person merges them, a group
/// onto a person names it, a group onto a group combines them before naming.
struct IdentitiesView: View {
    @EnvironmentObject private var model: AppModel
    let kind: IdentityKind

    @AppStorage private var photosMode: Bool
    @AppStorage private var showNamed: Bool
    @AppStorage private var showUnnamed: Bool
    @AppStorage private var showIgnored: Bool
    @AppStorage("grid.showFrames") private var showFrames = true
    @AppStorage("grid.frameOnly") private var frameOnly = false
    @State private var year = 0 // 0 = all years

    @State private var owners: [PersonSummary] = []
    @State private var clusters: [FaceCluster] = []
    @State private var ignoredClusters: [FaceCluster] = []
    @State private var counts = (named: 0, unnamed: 0, ignored: 0)
    @State private var photoIds: [Int64] = []
    @State private var photoSections: [GridSection] = []
    @State private var loaded = false

    @State private var selectedId: Int64?
    @State private var sheet: ClusterTarget?
    @State private var merging: (source: PersonSummary, target: PersonSummary)?
    @State private var renaming: PersonSummary?
    @State private var newName = ""
    @State private var dropTarget: String?
    // Multiple selection: ⇧-click (range), ⌘-click (toggle) or a box dragged on the background; on
    // release (of the modifier, or of the box) a small popup at the mouse offers the actions.
    @State private var picked: Set<String> = []
    @State private var anchorKey: String?
    @State private var lastClick: CGPoint = .zero
    @State private var pendingActions = false
    @State private var actionsAt: CGPoint?
    @State private var band: CGRect?
    @State private var bandBase: Set<String> = []
    @State private var frames: [String: CGRect] = [:]
    @State private var flagsMonitor: Any?
    @State private var duplicates: [[PersonSummary]] = []
    @State private var reviewingDuplicates = false

    init(kind: IdentityKind) {
        self.kind = kind
        let k = kind.rawValue
        _photosMode = AppStorage(wrappedValue: false, "\(k).photosMode")
        _showNamed = AppStorage(wrappedValue: true, "\(k).showNamed")
        _showUnnamed = AppStorage(wrappedValue: false, "\(k).showUnnamed")
        _showIgnored = AppStorage(wrappedValue: false, "\(k).showIgnored")
    }

    struct LoadKey: Hashable { var revision, year: Int; var named, unnamed, ignored, photos: Bool }

    var body: some View {
        // The load task sits outside the branches: counts (photos, to confirm) stay current while a
        // person's page is open, and are right when coming back to the cards.
        Group { page }
            .task(id: LoadKey(revision: model.revision, year: year, named: showNamed, unnamed: showUnnamed, ignored: showIgnored, photos: photosMode)) {
                await load()
            }
            .onChange(of: model.openOwner) { _, req in openRequested(req) }
            .onAppear { openRequested(model.openOwner) }
    }

    /// A link (info panel) asked for this person / pet.
    func openRequested(_ req: AppModel.OwnerRequest?) {
        guard let req, req.kind == kind else { return }
        selectedId = req.id
        model.openOwner = nil
    }

    @ViewBuilder var page: some View {
        if let p = owners.first(where: { $0.id == selectedId }) {
            OwnerDetail(kind: kind, owner: p, back: { selectedId = nil },
                        rename: { newName = p.name; renaming = p })
                .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    renameAlert
                } message: { Text("Using the name of another \(kind.ownerWord) merges them.") }
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .sheet(item: $sheet) { t in ClusterSheet(kind: kind, cluster: t.cluster, ignoredGroup: t.ignored).environmentObject(model) }
            .alert("Merge “\(merging?.source.name ?? "")” into “\(merging?.target.name ?? "")”?",
                   isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
                Button("Merge") {
                    if let m = merging { Task { await model.merge(kind, m.source, into: m.target) } }
                    merging = nil
                }
                Button("Cancel", role: .cancel) { merging = nil }
            } message: {
                Text("All \(kind.itemWord)s of \(merging?.source.name ?? "") (\(merging?.source.faces ?? 0)) will be named \(merging?.target.name ?? "").")
            }
            .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                renameAlert
            } message: { Text("Using the name of another \(kind.ownerWord) merges them.") }
        }
    }

    @ViewBuilder var renameAlert: some View {
        TextField("Name", text: $newName)
        Button("Rename") {
            if let p = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                let n = newName
                Task { await model.rename(kind, p, to: n) }
            }
            renaming = nil
        }
        Button("Cancel", role: .cancel) { renaming = nil }
    }

    // MARK: Filter bar

    var filterBar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $photosMode) {
                Label("Groups", systemImage: "circle.grid.2x2").tag(false)
                Label("Photos", systemImage: "photo.on.rectangle").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Groups: one card per \(kind.ownerWord) or group. Photos: every matching photo, by year.")

            Picker("", selection: $year) {
                Text("All years").tag(0)
                Divider()
                ForEach(model.years.filter { $0.year > 0 }, id: \.year) { y in Text(String(y.year)).tag(y.year) }
            }
            .labelsHidden().fixedSize()

            Divider().frame(height: 18)
            Toggle(isOn: $showNamed) { Text("Named") + Text(" \(counts.named)").foregroundStyle(.secondary) }
            Toggle(isOn: $showUnnamed) { Text("To identify") + Text(" \(counts.unnamed)").foregroundStyle(.secondary) }
                .help("Unnamed \(kind.itemWord)s, grouped by similarity. Hidden by default.")
            Toggle(isOn: $showIgnored) { Text("Ignored") + Text(" \(counts.ignored)").foregroundStyle(.secondary) }
                .help("\(kind.itemWord.capitalized)s you chose to ignore: never suggested, restorable from here.")
            Spacer()
            if photosMode { FramesToggle() }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder var content: some View {
        if !loaded {
            ProgressView()
        } else if counts.named + counts.unnamed + counts.ignored == 0 {
            ContentUnavailableView(kind == .face ? "No faces yet" : "No animals yet", systemImage: kind.placeholder,
                                   description: Text(kind == .face
                                       ? "Run the analysis (Processing ▸ Analyze Pending Images), import Picasa data, or name faces in the viewer."
                                       : "Run the analysis (Processing ▸ Analyze Pending Images): cats and dogs are detected, then you name them here."))
        } else if photosMode {
            if photoIds.isEmpty { emptySelection } else {
                YearGrid(ids: photoIds, sections: photoSections, resetKey: [kind.rawValue, String(year), "\(showNamed)\(showUnnamed)\(showIgnored)"],
                         frames: showFrames ? .identities(model.library, kind, named: showNamed, unnamed: showUnnamed, ignored: showIgnored, crop: frameOnly) : nil,
                         onRightClick: { ids, view in
                             Popup.show(PhotoRegionsActions(kind: kind, mediaIds: ids, named: showNamed, unnamed: showUnnamed, ignored: showIgnored),
                                        model: model, at: view)
                         })
            }
        } else if visibleGroups == 0 {
            emptySelection
        } else {
            groups
        }
    }

    var visibleGroups: Int {
        (showNamed ? owners.count : 0) + (showUnnamed ? clusters.count : 0) + (showIgnored ? ignoredClusters.count : 0)
    }

    /// Nothing under the current filters: offer the hidden part that has something.
    @ViewBuilder var emptySelection: some View {
        if !showUnnamed && counts.unnamed > 0 {
            ContentUnavailableView {
                Label(counts.named == 0 ? "No \(kind.ownerWord) named yet" : "Nothing here", systemImage: kind.placeholder)
            } description: {
                Text("\(counts.unnamed) \(kind.itemWord)\(counts.unnamed > 1 ? "s are" : " is") waiting to be identified.")
            } actions: {
                Button("Show them") { showUnnamed = true }
            }
        } else {
            ContentUnavailableView("Nothing to show", systemImage: kind.placeholder,
                                   description: Text("Nothing matches these filters\(year == 0 ? "" : " in \(year)")."))
        }
    }

    /// Cards in display order, for ⇧-click ranges.
    var orderedKeys: [String] {
        (showNamed ? owners.map { "owner:\($0.id)" } : []) + (showUnnamed ? clusters.map { "cluster:\($0.id)" } : [])
            + (showIgnored ? ignoredClusters.map { "ignored:\($0.id)" } : [])
    }

    func click(_ key: String, at p: CGPoint, open: () -> Void) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        lastClick = p
        if flags.contains(.shift), let a = anchorKey, let i = orderedKeys.firstIndex(of: a), let j = orderedKeys.firstIndex(of: key) {
            let range = Set(orderedKeys[min(i, j)...max(i, j)])
            picked = flags.contains(.command) ? picked.union(range) : range
            pendingActions = true
        } else if flags.contains(.command) || flags.contains(.shift) {
            if picked.contains(key) { picked.remove(key) } else { picked.insert(key) }
            anchorKey = key
            pendingActions = true
        } else if !picked.isEmpty {
            picked = []; anchorKey = key // a plain click leaves the selection
        } else {
            anchorKey = key
            open()
        }
    }

    /// Modifier released after ⇧/⌘-clicks: show the actions for the selection.
    func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !f.contains(.shift) && !f.contains(.command) && pendingActions {
                pendingActions = false
                if !picked.isEmpty { actionsAt = lastClick }
            }
            return e
        }
    }

    var bandGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("cards"))
            .onChanged { v in
                if band == nil {
                    bandBase = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) ? picked : []
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                band = r
                picked = bandBase.union(frames.filter { $0.value.intersects(r) }.map(\.key))
            }
            .onEnded { v in
                band = nil
                lastClick = v.location
                if !picked.isEmpty { actionsAt = v.location }
            }
    }

    var groups: some View {
        ScrollView {
          VStack(spacing: 0) {
            if !duplicates.isEmpty && showNamed {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.badge.gearshape").foregroundStyle(.orange)
                    Text("\(duplicates.count) name\(duplicates.count > 1 ? "s are" : " is") used by several \(kind == .face ? "people" : "pets") (\(duplicates.map(\.count).reduce(0, +)) in all) — probably the same \(kind.ownerWord) imported several times.")
                        .font(.callout)
                    Spacer()
                    Button("Review…") { reviewingDuplicates = true }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top])
            }
            if showNamed && !owners.isEmpty {
                header(kind == .face ? "People" : "Pets", hint: "Drag one onto another to merge them · ⇧/⌘-click or drag a box around several to act on them together")
                cardGrid {
                    ForEach(owners) { p in
                        card(key: "owner:\(p.id)", regionId: p.coverFaceId, title: p.name,
                             subtitle: "\(p.faces) photo\(p.faces > 1 ? "s" : "")" + (p.suggestions > 0 ? " · \(p.suggestions) to confirm" : ""))
                            .onTapGesture(coordinateSpace: .named("cards")) { pt in click("owner:\(p.id)", at: pt) { selectedId = p.id } }
                            .contextMenu {
                                Button("Open") { selectedId = p.id }
                                Button("Rename…") { newName = p.name; renaming = p }
                                if p.suggestions > 0 {
                                    Button("Confirm \(p.suggestions) suggestions") { Task { await model.confirmAll(kind, p) } }
                                }
                            }
                    }
                }
            }
            if showUnnamed && !clusters.isEmpty {
                header("To identify", hint: "Click a group to name it, drag it onto a \(kind.ownerWord), or right-click to ignore it")
                cardGrid {
                    ForEach(clusters) { c in
                        card(key: "cluster:\(c.id)", regionId: c.coverFaceId, title: "Unnamed",
                             subtitle: "\(c.faceIds.count) \(kind.itemWord)\(c.faceIds.count > 1 ? "s" : "")")
                            .onTapGesture(coordinateSpace: .named("cards")) { p in click("cluster:\(c.id)", at: p) { sheet = ClusterTarget(cluster: c, ignored: false) } }
                            .contextMenu {
                                Button("Name…") { sheet = ClusterTarget(cluster: c, ignored: false) }
                                Button("Ignore \(c.faceIds.count == 1 ? "this \(kind.itemWord)" : "these \(c.faceIds.count) \(kind.itemWord)s")") {
                                    Task { await model.setIgnored(kind, c.faceIds, true) }
                                }
                            }
                    }
                }
            }
            if showIgnored && !ignoredClusters.isEmpty {
                header("Ignored", hint: "Never suggested nor grouped with the unnamed. Right-click to restore")
                cardGrid {
                    ForEach(ignoredClusters) { c in
                        card(key: "ignored:\(c.id)", regionId: c.coverFaceId, title: "Ignored",
                             subtitle: "\(c.faceIds.count) \(kind.itemWord)\(c.faceIds.count > 1 ? "s" : "")")
                            .opacity(0.6)
                            .onTapGesture(coordinateSpace: .named("cards")) { p in click("ignored:\(c.id)", at: p) { sheet = ClusterTarget(cluster: c, ignored: true) } }
                            .contextMenu {
                                Button("Restore") { Task { await model.setIgnored(kind, c.faceIds, false) } }
                                Button("Name…") { sheet = ClusterTarget(cluster: c, ignored: true) }
                            }
                    }
                }
            }
          }
          .padding(.bottom, 20)
          .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
          .background(Color.clear.contentShape(Rectangle()).gesture(bandGesture))
          .overlay(alignment: .topLeading) {
              if let r = band {
                  Rectangle().fill(Color.accentColor.opacity(0.12)).overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                      .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
              }
          }
          .coordinateSpace(.named("cards"))
          .onPreferenceChange(CardFrames.self) { frames = $0 }
          .sheet(isPresented: $reviewingDuplicates) {
              DuplicatesSheet(kind: kind, groups: duplicates).environmentObject(model)
          }
          .popover(isPresented: Binding(get: { actionsAt != nil }, set: { if !$0 { actionsAt = nil } }),
                   attachmentAnchor: .rect(.rect(CGRect(origin: actionsAt ?? .zero, size: CGSize(width: 1, height: 1)))),
                   arrowEdge: .bottom) {
              SelectionActions(kind: kind, owners: owners.filter { picked.contains("owner:\($0.id)") },
                               unnamed: clusters.filter { picked.contains("cluster:\($0.id)") }.flatMap(\.faceIds),
                               ignored: ignoredClusters.filter { picked.contains("ignored:\($0.id)") }.flatMap(\.faceIds)) {
                  actionsAt = nil; picked = []
              } cancel: { actionsAt = nil }
              .environmentObject(model)
          }
        }
        .onAppear(perform: installFlagsMonitor)
        .onDisappear { if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil } }
        .onExitCommand { picked = []; actionsAt = nil }
    }

    func cardGrid<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 16, content: content).padding(.horizontal)
    }

    func header(_ t: String, hint: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(t).font(.headline)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top]).padding(.bottom, 12)
    }

    func card(key: String, regionId: Int64?, title: String, subtitle: String) -> some View {
        let on = picked.contains(key)
        return VStack {
            RegionThumb(kind: kind, regionId: regionId).frame(width: 120, height: 120).clipShape(Circle())
                .overlay(Circle().stroke(Color.accentColor, lineWidth: dropTarget == key ? 4 : on ? 3 : 0))
                .overlay(alignment: .bottomTrailing) {
                    if on {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, Color.accentColor)
                    }
                }
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .background(GeometryReader { g in Color.clear.preference(key: CardFrames.self, value: [key: g.frame(in: .named("cards"))]) })
        .scaleEffect(dropTarget == key ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: dropTarget == key)
        .draggable("\(kind.rawValue):\(key)") {
            RegionThumb(kind: kind, regionId: regionId).frame(width: 80, height: 80).clipShape(Circle()).environmentObject(model)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let source = items.first, source != "\(kind.rawValue):\(key)" else { return false }
            return drop(source, on: key)
        } isTargeted: { on in
            if on { dropTarget = key } else if dropTarget == key { dropTarget = nil }
        }
    }

    /// Resolves "owner:ID" / "cluster:ID" / "ignored:ID" keys and applies the drop.
    func drop(_ source: String, on target: String) -> Bool {
        let prefix = kind.rawValue + ":"
        guard source.hasPrefix(prefix) else { return false } // a face dropped on Animals, or the reverse
        let src = String(source.dropFirst(prefix.count))
        func owner(_ k: String) -> PersonSummary? {
            guard k.hasPrefix("owner:"), let id = Int64(k.dropFirst(6)) else { return nil }
            return owners.first { $0.id == id }
        }
        func group(_ k: String) -> FaceCluster? {
            for p in ["cluster:", "ignored:"] where k.hasPrefix(p) {
                guard let id = Int64(k.dropFirst(p.count)) else { return nil }
                return (clusters + ignoredClusters).first { $0.id == id }
            }
            return nil
        }
        switch (owner(src), group(src), owner(target), group(target)) {
        case let (s?, _, t?, _):
            merging = (s, t)
        case let (_, c?, t?, _), let (t?, _, _, c?):
            Task { await model.assign(kind, c.faceIds, to: t) }
        case let (_, a?, _, b?):
            sheet = ClusterTarget(cluster: FaceCluster(coverFaceId: b.coverFaceId, faceIds: b.faceIds + a.faceIds), ignored: false)
        default:
            return false
        }
        return true
    }

    func load() async {
        let lib = model.library
        if kind == .pet { await model.ensurePetPrints() }
        let y: Int? = year == 0 ? nil : year
        // Everything is read first, then shown at once — and not at all if a newer load started
        // meanwhile (edits come in bursts: an older, slower load must not overwrite fresh counts).
        let c = (try? await lib.identityCounts(kind, year: y)) ?? (0, 0, 0)
        let o = (try? await lib.owners(kind, year: y)) ?? []
        // Same-name people are looked for over all years: reuse the list when it is that one.
        let d = y == nil ? Library.duplicateGroups(o) : ((try? await lib.duplicateOwners(kind)) ?? [])
        guard !Task.isCancelled else { return }
        counts = c; duplicates = d; owners = o
        if photosMode {
            let rows = (try? await lib.mediaIdsAndYears(.identities(kind, named: showNamed, unnamed: showUnnamed, ignored: showIgnored, year: y))) ?? []
            guard !Task.isCancelled else { return }
            photoIds = rows.map(\.id)
            photoSections = GridSection.byYear(rows.map(\.year))
        } else {
            // Clustering is the expensive part: the model keeps the groups (across visits of the page)
            // until the items change.
            let cl = showUnnamed ? await model.clusters(kind, ignored: false, year: y) : []
            let ig = showIgnored ? await model.clusters(kind, ignored: true, year: y) : []
            guard !Task.isCancelled else { return }
            clusters = cl; ignoredClusters = ig
        }
        loaded = true
    }
}

struct ClusterTarget: Identifiable {
    var id: Int64 { cluster.id }
    let cluster: FaceCluster
    let ignored: Bool
}

/// A named person / pet: confirmed photos and suggestions, by year.
struct OwnerDetail: View {
    @EnvironmentObject private var model: AppModel
    let kind: IdentityKind
    let owner: PersonSummary
    var back: () -> Void
    var rename: () -> Void
    @State private var confirmed: [(id: Int64, year: Int)] = []
    @State private var suggested: [(id: Int64, year: Int)] = []
    @State private var showSuggested = false
    @State private var selection: [Int] = []
    /// Bumped after confirming / rejecting: the grid goes back to the top, where the next
    /// suggestions (recomputed from what was just confirmed) are.
    @State private var acted = 0
    @AppStorage("grid.showFrames") private var showFrames = true
    @AppStorage("grid.frameOnly") private var frameOnly = false
    @State private var moving = false
    @State private var rejectingAll = false
    @State private var moveName = ""
    @State private var known: [String] = []

    var body: some View {
        let rows = showSuggested ? suggested : confirmed
        let ids = rows.map(\.id)
        let chosen = selection.compactMap { $0 < ids.count ? ids[$0] : nil }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: back) { Label(kind.title, systemImage: "chevron.left") }
                Text(owner.name).font(.title2.bold())
                Button(action: rename) { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Rename (an existing name merges)")
                Spacer()
                Picker("", selection: $showSuggested) {
                    Text("Confirmed (\(confirmed.count))").tag(false)
                    Text("Suggested (\(suggested.count))").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                FramesToggle()
            }
            .padding(10)
            if showSuggested && !suggested.isEmpty {
                HStack(spacing: 10) {
                    Text(chosen.isEmpty ? "Select photos (⌘/⇧-click) to confirm or reject" : "\(chosen.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await act(confirm: true, chosen) } } label: { Label("Confirm", systemImage: "checkmark") }
                        .disabled(chosen.isEmpty)
                    Button { Task { await act(confirm: false, chosen) } } label: { Label("Reject", systemImage: "xmark") }
                        .disabled(chosen.isEmpty)
                    Spacer()
                    Button("Reject all \(suggested.count)") { rejectingAll = true }
                        .confirmationDialog("Reject all \(suggested.count) suggestions for \(owner.name)?", isPresented: $rejectingAll) {
                            Button("Reject all", role: .destructive) { Task { await act(confirm: false, suggested.map(\.id)); acted += 1 } }
                        } message: { Text("They will not be suggested as \(owner.name) again (and their look-alikes neither).") }
                    Button("Confirm all \(suggested.count)") { Task { await model.confirmAll(kind, owner); await reload(); acted += 1 } }
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if !showSuggested && !confirmed.isEmpty {
                // Correcting confirmed photos: take them away from this person, or give them to someone else.
                HStack(spacing: 10) {
                    Text(chosen.isEmpty ? "Select photos (⌘/⇧-click) to correct them" : "\(chosen.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await unassign(chosen) } } label: { Label("Not \(owner.name)", systemImage: "person.crop.circle.badge.xmark") }
                        .disabled(chosen.isEmpty)
                        .help("These are not \(owner.name): they become unnamed again and will not be suggested as \(owner.name)")
                    Button { moveName = ""; moving = true } label: { Label("Move to…", systemImage: "arrow.right.circle") }
                        .disabled(chosen.isEmpty)
                        .popover(isPresented: $moving, arrowEdge: .bottom) { moveForm(chosen) }
                    Button { Task { await setCover(chosen.first!) } } label: { Label("Set as cover", systemImage: "person.crop.square.badge.camera") }
                        .disabled(chosen.count != 1)
                        .help("Show this photo's \(kind.itemWord) on \(owner.name)'s card (default: the best-looking photo)")
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
            }
            if ids.isEmpty {
                ContentUnavailableView(showSuggested ? "No suggestions" : "No confirmed photos", systemImage: "person.crop.square",
                                       description: Text(showSuggested ? "Run the analysis to get suggestions for \(owner.name)." : "Name \(kind.itemWord)s of \(owner.name) to see them here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                YearGrid(ids: ids, sections: GridSection.byYear(rows.map(\.year)), resetKey: [owner.id, showSuggested ? 1 : 0, Int64(acted)],
                         onSelect: { selection = $0 }, frames: showFrames ? .identities(model.library, kind, owner: owner.id, crop: frameOnly) : nil,
                         onRightClick: { ids, view in Popup.show(PhotoRegionsActions(kind: kind, mediaIds: ids, owner: owner), model: model, at: view) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: [owner.id, Int64(model.revision)]) { await reload() }
        .onChange(of: showSuggested) { selection = [] }
    }

    func moveForm(_ chosen: [Int64]) -> some View {
        let q = moveName.trimmingCharacters(in: .whitespaces)
        let matches = Array(known.filter { $0 != owner.name && (q.isEmpty || $0.localizedCaseInsensitiveContains(q)) }.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Move \(chosen.count) photo\(chosen.count > 1 ? "s" : "") to").font(.headline)
            TextField("Name", text: $moveName).textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { Task { await move(chosen, to: moveName) } }
                .onKeyPress(.tab) { if let m = matches.first { moveName = m; return .handled }; return .ignored }
            ForEach(matches, id: \.self) { m in
                Button { Task { await move(chosen, to: m) } } label: { Label(m, systemImage: kind == .face ? "person" : "pawprint") }.buttonStyle(.plain)
            }
        }
        .padding(14)
        .task { known = ((try? await model.library.owners(kind)) ?? []).map(\.name) }
    }

    func setCover(_ mediaId: Int64) async {
        let (k, o) = (kind, owner.id)
        let ids = (try? await model.library.regionIds(k, owner: o, mediaIds: [mediaId])) ?? []
        try? await model.library.setCover(k, owner: o, region: ids.first)
        await model.refreshAll()
    }

    func unassign(_ mediaIds: [Int64]) async {
        let (k, o) = (kind, owner.id)
        await model.identityEdit(kind) { lib in
            _ = try await lib.unassign(k, try await lib.regionIds(k, owner: o, mediaIds: mediaIds))
        }
        selection = []
        await reload()
    }

    func move(_ mediaIds: [Int64], to name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        moving = false
        let (k, o) = (kind, owner.id)
        await model.identityEdit(kind) { lib in
            let ids = try await lib.regionIds(k, owner: o, mediaIds: mediaIds)
            _ = try await lib.unassign(k, ids)   // remembered as "not \(owner)"
            _ = try await lib.nameItems(k, ids, name: n)
        }
        selection = []
        await reload()
    }

    func reload() async {
        let lib = model.library
        confirmed = (try? await lib.mediaIdsAndYears(kind == .face ? .person(owner.id) : .pet(owner.id))) ?? []
        suggested = (try? await lib.mediaIdsAndYears(kind == .face ? .personSuggestions(owner.id) : .petSuggestions(owner.id))) ?? []
    }

    func act(confirm: Bool, _ mediaIds: [Int64]) async {
        let (k, o) = (kind, owner.id)
        await model.identityEdit(kind) { lib in
            if confirm { _ = try await lib.confirm(k, owner: o, mediaIds: mediaIds) } else { _ = try await lib.reject(k, owner: o, mediaIds: mediaIds) }
        }
        selection = []
        await reload()
        acted += 1
    }
}

/// Name a group of similar unnamed faces / animals, or ignore them; click one to leave it out.
struct ClusterSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: IdentityKind
    let cluster: FaceCluster
    var ignoredGroup = false
    @State private var excluded: Set<Int64> = []
    @State private var name = ""
    @State private var known: [String] = []

    var chosen: [Int64] { cluster.faceIds.filter { !excluded.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ignoredGroup ? "Ignored \(kind.itemWord)s" : (kind == .face ? "Who is this?" : "Which pet is this?")).font(.title2.bold())
            Text("Click a \(kind.itemWord) to leave it out.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(cluster.faceIds, id: \.self) { f in
                        RegionThumb(kind: kind, regionId: f).frame(width: 84, height: 84).clipShape(Circle())
                            .opacity(excluded.contains(f) ? 0.25 : 1)
                            .overlay(alignment: .bottomTrailing) {
                                if excluded.contains(f) { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                            }
                            .onTapGesture { if excluded.contains(f) { excluded.remove(f) } else { excluded.insert(f) } }
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 420)
            HStack {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                    .frame(minWidth: 220)
                if !known.isEmpty {
                    Menu("Existing") { ForEach(known, id: \.self) { n in Button(n) { name = n } } }.fixedSize()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if ignoredGroup {
                    Button("Restore \(chosen.count)") { let ids = chosen; dismiss(); Task { await model.setIgnored(kind, ids, false) } }
                        .disabled(chosen.isEmpty)
                } else {
                    Button("Ignore \(chosen.count)") { let ids = chosen; dismiss(); Task { await model.setIgnored(kind, ids, true) } }
                        .disabled(chosen.isEmpty)
                        .help("Never suggest these \(kind.itemWord)s again (they go to Ignored)")
                }
                Button("Name \(chosen.count)", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { known = ((try? await model.library.owners(kind)) ?? []).map(\.name).sorted() }
    }

    func save() {
        let ids = chosen, n = name
        guard !n.trimmingCharacters(in: .whitespaces).isEmpty, !ids.isEmpty else { return }
        dismiss()
        Task { await model.name(kind, ids, as: n) }
    }
}

/// Crop of a face or an animal, cached on disk next to the thumbnails.
struct RegionThumb: View {
    @EnvironmentObject private var model: AppModel
    let kind: IdentityKind
    let regionId: Int64?
    @State private var image: NSImage?
    @State private var shown: Int64?

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: kind.placeholder).font(.largeTitle).foregroundStyle(.secondary) }
        }
        .task(id: [regionId ?? 0, Int64(model.revision)]) {
            // Reused for another face (a card whose cover changed): reload then.
            if shown != regionId { image = nil; shown = regionId }
            guard image == nil, let regionId, let f = try? await model.library.region(kind, id: regionId) else { return }
            let margin = kind == .face ? 1.4 : 1.1
            // 1. Crop already cached on disk (local, next to the thumbnails). Pets use negative ids.
            let store = model.thumbs.store
            let cached = store.faceURL(id: kind == .face ? f.id : -f.id, x: f.x, y: f.y, w: f.w)
            // Crops are cut from the unturned picture, then shown turned like the photo.
            let q = model.thumbs.rotation(f.mediaId)
            @MainActor func show(_ c: CGImage) { let t = Turn.image(c, q); image = NSImage(cgImage: t, size: NSSize(width: t.width, height: t.height)) }
            if let cg = await Task.detached(priority: .userInitiated, operation: { store.loadImage(cached) }).value {
                show(cg); return
            }
            // 2. Crop of the 320 px thumbnail: enough unless the region is tiny in the photo.
            if let thumb = await model.thumbs.loadRaw(f.mediaId), let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let c = Self.crop(cg, f, margin: margin) {
                show(c)
                if max(f.w * Double(cg.width), f.h * Double(cg.height)) >= 64 { store.store(c, at: cached); return }
            }
            // 3. Tiny: read the original once (a few at a time, the disk may be remote) and cache the crop.
            guard let item = try? await model.library.items(ids: [f.mediaId]).first else { return }
            let url = item.url
            let big = await OriginalReads.shared.run { ThumbnailStore.imageThumbnail(url, maxPixel: 2048) }
            guard !Task.isCancelled, let big, let c = Self.crop(big, f, margin: margin) else { return }
            let small = Self.downscale(c, to: 256)
            store.store(small, at: cached)
            show(small)
        }
    }

    /// Square crop around the region, `margin` × its size.
    static func crop(_ cg: CGImage, _ f: FaceRecord, margin: Double) -> CGImage? {
        let W = Double(cg.width), H = Double(cg.height)
        let side = max(f.w * W, f.h * H) * margin
        let r = CGRect(x: (f.x + f.w / 2) * W - side / 2, y: (f.y + f.h / 2) * H - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        return cg.cropping(to: r)
    }

    static func downscale(_ cg: CGImage, to side: Int) -> CGImage {
        guard max(cg.width, cg.height) > side,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage() ?? cg
    }
}

/// Naming a face or an animal right on the photo (viewer): type a name (existing ones are proposed
/// as you type, Tab or ↓ to pick), confirm or reject a suggestion, or ignore it.
struct RegionEditor: View {
    @EnvironmentObject private var model: AppModel
    let kind: IdentityKind
    let region: FaceRecord
    var done: () -> Void
    @State private var name = ""
    @State private var known: [String] = []
    @FocusState private var focused: Bool

    var named: Bool { region.personId != nil }
    var suggested: Bool { !named && region.suggestedPersonId != nil }
    var matches: [String] {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(known.prefix(6)) }
        return Array(known.filter { $0.localizedCaseInsensitiveContains(q) && $0.caseInsensitiveCompare(q) != .orderedSame }
            .sorted { ($0.lowercased().hasPrefix(q.lowercased()) ? 0 : 1) < ($1.lowercased().hasPrefix(q.lowercased()) ? 0 : 1) }
            .prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if suggested, let s = region.personName {
                Text("Is this \(s)?").font(.headline)
                HStack {
                    Button("Yes") { act { try await $0.assign(kind, [region.id], to: region.suggestedPersonId!) } }
                        .keyboardShortcut(.defaultAction)
                    Button("No") { act { _ = try await $0.reject(kind, owner: region.suggestedPersonId!, mediaIds: [region.mediaId]) } }
                }
                Divider()
                Text("Or another name").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(named ? "Rename" : (kind == .face ? "Who is this?" : "Which pet is this?")).font(.headline)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .focused($focused)
                .onSubmit(save)
                .onKeyPress(.tab) { if let m = matches.first { name = m; return .handled }; return .ignored }
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches, id: \.self) { m in
                        Button { name = m; save() } label: {
                            Label(m, systemImage: kind == .face ? "person" : "pawprint").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain).padding(.vertical, 2)
                    }
                }
            }
            HStack {
                if !named {
                    Button(role: .destructive) { act { _ = try await $0.setIgnored(kind, [region.id], true) } } label: {
                        Label("Ignore", systemImage: "eye.slash")
                    }
                    .help("Never suggest this \(kind.itemWord) again (it goes to Ignored)")
                } else if let current = region.personName {
                    Button(role: .destructive) { act { _ = try await $0.unassign(kind, [region.id]) } } label: {
                        Label("Not \(current)", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .help("Wrongly named: this \(kind.itemWord) becomes unnamed again and is not suggested as \(current)")
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(suggested ? nil : .defaultAction)
            }
        }
        .padding(14)
        .onAppear { model.typing = true }
        .onDisappear { model.typing = false }
        .task {
            if named { name = region.personName ?? "" }
            known = ((try? await model.library.owners(kind)) ?? []).map(\.name)
            focused = !suggested
        }
    }

    func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let (k, id) = (kind, region.id)
        let renamed = named && region.personName?.caseInsensitiveCompare(n) != .orderedSame
        done()
        // Renaming a named face: the old name is remembered as wrong for it.
        Task { await model.identityEdit(k) { lib in
            if renamed { _ = try await lib.unassign(k, [id]) }
            _ = try await lib.nameItems(k, [id], name: n)
        } }
    }

    func act(_ body: @escaping @Sendable (Library) async throws -> Void) {
        done()
        Task { await model.identityEdit(kind, body) }
    }
}

struct CardFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Actions on several cards at once (popup at the mouse after a ⇧/⌘ selection or a box):
/// name them all as one person / pet (selected people are merged into it), ignore or restore.
struct SelectionActions: View {
    @EnvironmentObject private var model: AppModel
    let kind: IdentityKind
    let owners: [PersonSummary]
    let unnamed: [Int64]
    let ignored: [Int64]
    var done: () -> Void
    var cancel: () -> Void
    @State private var name = ""
    @State private var known: [String] = []
    @FocusState private var focused: Bool

    var summary: String {
        var parts: [String] = []
        if !owners.isEmpty { parts.append("\(owners.count) \(kind.ownerWord)\(owners.count > 1 ? "s" : "")") }
        if !unnamed.isEmpty { parts.append("\(unnamed.count) unnamed \(kind.itemWord)\(unnamed.count > 1 ? "s" : "")") }
        if !ignored.isEmpty { parts.append("\(ignored.count) ignored") }
        return parts.joined(separator: " · ")
    }

    var matches: [String] {
        let q = name.trimmingCharacters(in: .whitespaces)
        let pool = known.filter { n in !owners.contains { $0.name == n } }
        guard !q.isEmpty else { return Array(pool.prefix(5)) }
        return Array(pool.filter { $0.localizedCaseInsensitiveContains(q) && $0.caseInsensitiveCompare(q) != .orderedSame }.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary).font(.headline)
            HStack {
                TextField(owners.count > 1 && unnamed.isEmpty ? "Merge into…" : "Name as…", text: $name)
                    .textFieldStyle(.roundedBorder).frame(width: 220).focused($focused)
                    .onSubmit(apply)
                    .onKeyPress(.tab) { if let m = matches.first { name = m; return .handled }; return .ignored }
                Button("OK", action: apply).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches, id: \.self) { m in
                        Button { name = m; apply() } label: {
                            Label(m, systemImage: kind == .face ? "person" : "pawprint").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).padding(.vertical, 1)
                    }
                }
            }
            Divider()
            HStack {
                if !unnamed.isEmpty {
                    Button(role: .destructive) { run { _ = try await $0.setIgnored(kind, unnamed, true) } } label: {
                        Label("Ignore \(unnamed.count)", systemImage: "eye.slash")
                    }
                }
                if !ignored.isEmpty {
                    Button { run { _ = try await $0.setIgnored(kind, ignored, false) } } label: {
                        Label("Restore \(ignored.count)", systemImage: "arrow.uturn.backward")
                    }
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(minWidth: 320)
        .task {
            known = ((try? await model.library.owners(kind)) ?? []).map(\.name)
            focused = true
        }
    }

    /// One name for everything selected: the unnamed / ignored items are named, the selected
    /// people / pets are merged into that name (an existing one, or the first selected, renamed).
    func apply() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let (k, items, sel) = (kind, unnamed + ignored, owners)
        run { lib in
            var target = try await lib.owners(k).first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.id
            if target == nil, !items.isEmpty { target = try await lib.nameItems(k, items, name: n) }
            else if let t = target, !items.isEmpty { try await lib.assign(k, items, to: t) }
            if target == nil, let first = sel.first { try await lib.renameOwner(k, first.id, to: n); target = first.id }
            guard let t = target else { return }
            for o in sel where o.id != t { try await lib.merge(k, o.id, into: t) }
        }
    }

    func run(_ body: @escaping @Sendable (Library) async throws -> Void) {
        done()
        Task { await model.identityEdit(kind, body) }
    }
}

extension GridFrames {
    /// Frames for People / Animals grids. The target (the person / pet shown, or the categories
    /// ticked in the filter bar) is drawn in colour, solid once a person confirmed it, dashed while
    /// it is only a suggestion or unnamed; the other faces / animals of the photo are thin and faint.
    static func identities(_ lib: Library, _ k: IdentityKind, owner: Int64? = nil,
                           named: Bool = true, unnamed: Bool = true, ignored: Bool = false, crop: Bool = false) -> GridFrames {
        let color: NSColor = k == .face ? .systemGreen : .systemOrange
        let id = "\(k.rawValue):\(owner.map(String.init) ?? "all"):\(named)\(unnamed)\(ignored)"
        return GridFrames(id: id, load: { mediaId in
            let regions = (try? await lib.regions(k, mediaId: mediaId)) ?? []
            return regions.compactMap { r -> GridFrame? in
                func f(_ c: NSColor, dashed: Bool, width: CGFloat = 2, target: Bool = false) -> GridFrame {
                    GridFrame(x: r.x, y: r.y, w: r.w, h: r.h, color: c, dashed: dashed, width: width, target: target, regionId: r.id, kind: k)
                }
                if let o = owner {
                    if r.personId == o { return f(color, dashed: false, width: 2.5, target: true) }
                    if r.personId == nil && r.suggestedPersonId == o { return f(color, dashed: true, width: 2.5, target: true) }
                    return r.ignored ? nil : f(.white.withAlphaComponent(0.55), dashed: r.personId == nil, width: 1)
                }
                if r.ignored { return ignored ? f(.systemGray, dashed: true, width: 1.5, target: true) : nil }
                if r.personId != nil { return named ? f(color, dashed: false, target: true) : f(.white.withAlphaComponent(0.55), dashed: false, width: 1) }
                return unnamed ? f(.white, dashed: true, target: true) : f(.white.withAlphaComponent(0.55), dashed: true, width: 1)
            }
        }, crop: crop)
    }
}

extension GridFrames {
    /// Frame colour of Last indexed ▸ Faces / Animals: full colour when a person made or confirmed
    /// the region, a lighter tint of it when it is the detector's alone.
    static func detectionColor(_ k: IdentityKind, human: Bool) -> NSColor {
        let c: NSColor = k == .face ? .systemGreen : .systemOrange
        return human ? c : (c.blended(withFraction: 0.45, of: .white) ?? c)
    }

    /// Frames for Last indexed ▸ Faces / Animals: every region of the photo, solid and thicker when a
    /// person drew, tagged or confirmed it, dashed and lighter when only the detector found it;
    /// ignored ones thin and grey.
    static func detections(_ lib: Library, _ k: IdentityKind, crop: Bool = false) -> GridFrames {
        GridFrames(id: "detections:\(k.rawValue)", load: { mediaId in
            let regions = (try? await lib.regions(k, mediaId: mediaId)) ?? []
            return regions.map { r in
                let (color, dashed, width): (NSColor, Bool, CGFloat) = r.ignored
                    ? (.systemGray, true, 1)
                    : (detectionColor(k, human: r.human), !r.human, r.human ? 2.5 : 1.5)
                return GridFrame(x: r.x, y: r.y, w: r.w, h: r.h, color: color, dashed: dashed, width: width,
                                 target: !r.ignored, regionId: r.id, kind: k)
            }
        }, crop: crop)
    }
}

/// "Frames" and "Frame only" toggles shared by the photo grids of People, Animals and Labels (remembered).
struct FramesToggle: View {
    @AppStorage("grid.showFrames") var on = true
    @AppStorage("grid.frameOnly") var only = false
    var help = "Show face / animal frames on the thumbnails: coloured for the one shown here, solid when confirmed, dashed when not yet"
    var body: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $on) { Label("Frames", systemImage: "person.crop.square") }
                .toggleStyle(.button).help(help)
            Toggle(isOn: $only) { Label("Frame only", systemImage: "viewfinder") }
                .toggleStyle(.button)
                .help("Zoom each thumbnail on its face / animal: bigger, easier to decide")
                .onChange(of: only) { if only { on = true } }
        }
    }
}

/// Preview of the people sharing a name before merging them: one row per name, each merged into
/// the one with the most photos; untick a row to leave it alone.
struct DuplicatesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: IdentityKind
    let groups: [[PersonSummary]]
    @State private var skipped: Set<Int64> = []

    var chosen: [[PersonSummary]] { groups.filter { !skipped.contains($0[0].id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(kind == .face ? "people" : "pets") with the same name").font(.title2.bold())
            Text("Each row becomes one \(kind.ownerWord): the others are merged into the first (the one with the most photos). Their faces, suggestions and rejections move over; Picasa contact ids keep pointing to the merged one.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.first!.id) { g in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { !skipped.contains(g[0].id) },
                                                     set: { if $0 { skipped.remove(g[0].id) } else { skipped.insert(g[0].id) } }))
                                .labelsHidden()
                            ForEach(Array(g.enumerated()), id: \.element.id) { i, p in
                                VStack(spacing: 2) {
                                    RegionThumb(kind: kind, regionId: p.coverFaceId).frame(width: 46, height: 46).clipShape(Circle())
                                        .overlay(Circle().stroke(i == 0 ? Color.accentColor : .clear, lineWidth: 2))
                                    Text("\(p.faces)").font(.caption2).foregroundStyle(.secondary)
                                }
                                if i == 0 { Image(systemName: "arrow.left").foregroundStyle(.secondary) }
                            }
                            Text(g[0].name).font(.headline)
                            Spacer()
                        }
                        .opacity(skipped.contains(g[0].id) ? 0.4 : 1)
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 460)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Merge \(chosen.count) name\(chosen.count > 1 ? "s" : "")") {
                    let (k, g) = (kind, chosen)
                    dismiss()
                    model.mergeDuplicates(k, g)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

/// Shooting details read from the file's EXIF / TIFF / GPS metadata (only what is present).
enum ExifDetails {
    static func read(_ url: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        var out: [(String, String)] = []
        // Finite values only: malformed EXIF (e.g. ExposureTime = 0, NaN) would otherwise trap on Int(...) conversions.
        func num(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        func int(_ d: Double) -> Int? { abs(d) < 1e15 ? Int(d) : nil }
        if let make = tiff[kCGImagePropertyTIFFMake] as? String, let model = tiff[kCGImagePropertyTIFFModel] as? String {
            out.append(("Camera", model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"))
        }
        if let lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String) { out.append(("Lens", lens)) }
        var exposure: [String] = []
        if let t = num(exif[kCGImagePropertyExifExposureTime]), t > 0 {
            if t >= 1 { exposure.append(String(format: "%.1f s", t)) } else if let d = int((1 / t).rounded()) { exposure.append("1/\(d) s") }
        }
        if let f = num(exif[kCGImagePropertyExifFNumber]) { exposure.append(String(format: "ƒ/%.1f", f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { exposure.append("ISO \(iso)") }
        if let b = num(exif[kCGImagePropertyExifExposureBiasValue]), b != 0 { exposure.append(String(format: "%+.1f EV", b)) }
        if !exposure.isEmpty { out.append(("Exposure", exposure.joined(separator: " · "))) }
        if let fl = num(exif[kCGImagePropertyExifFocalLength]) {
            let eq = num(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).map { String(format: " (%.0f mm eq.)", $0) } ?? ""
            out.append(("Focal length", String(format: "%.1f mm", fl) + eq))
        }
        if let flash = num(exif[kCGImagePropertyExifFlash]).flatMap(int) { out.append(("Flash", flash & 1 == 1 ? "Fired" : "No flash")) }
        if let wb = num(exif[kCGImagePropertyExifWhiteBalance]) { out.append(("White balance", wb == 0 ? "Auto" : "Manual")) }
        let modes = [0: "Unknown", 1: "Average", 2: "Center-weighted", 3: "Spot", 4: "Multi-spot", 5: "Pattern", 6: "Partial"]
        if let m = num(exif[kCGImagePropertyExifMeteringMode]).flatMap(int), let s = modes[m] { out.append(("Metering", s)) }
        if let alt = num(gps[kCGImagePropertyGPSAltitude]) { out.append(("Altitude", String(format: "%.0f m", alt))) }
        if let sw = tiff[kCGImagePropertyTIFFSoftware] as? String { out.append(("Software", sw)) }
        if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String { out.append(("Original date", d)) }
        if let cs = p[kCGImagePropertyProfileName] as? String { out.append(("Colour profile", cs)) }
        if let dpi = num(p[kCGImagePropertyDPIWidth]).flatMap(int), dpi != 72 { out.append(("Resolution", "\(dpi) dpi")) }
        return out
    }
}

/// Shows a SwiftUI view in a popover anchored on an AppKit view (a grid cell), closed on click outside.
@MainActor enum Popup {
    static var current: NSPopover?
    static func show<V: View>(_ content: V, model: AppModel, at view: NSView) {
        current?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: content.environmentObject(model))
        pop.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        current = pop
    }
    static func close() { current?.close(); current = nil }
}

/// Right-click on photos selected in a People / Animals grid: acts on the face / animal of each
/// photo that the grid is about (the person's, or the largest one in the categories shown).
struct PhotoRegionsActions: View {
    @EnvironmentObject private var model: AppModel
    let kind: IdentityKind
    let mediaIds: [Int64]
    /// A person's / pet's page: their face in each photo (confirmed or suggested).
    var owner: PersonSummary? = nil
    var named = true, unnamed = true, ignored = false
    @State private var targets: [FaceRecord] = []
    @State private var loaded = false
    @State private var name = ""
    @State private var known: [String] = []
    @FocusState private var focused: Bool

    var namedT: [FaceRecord] { targets.filter { $0.personId != nil && !$0.ignored } }
    var suggestedT: [FaceRecord] { targets.filter { $0.personId == nil && !$0.ignored && $0.suggestedPersonId != nil } }
    var unnamedT: [FaceRecord] { targets.filter { $0.personId == nil && !$0.ignored } }
    var ignoredT: [FaceRecord] { targets.filter(\.ignored) }

    var matches: [String] {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(known.prefix(5)) }
        return Array(known.filter { $0.localizedCaseInsensitiveContains(q) && $0.caseInsensitiveCompare(q) != .orderedSame }.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(mediaIds.count) photo\(mediaIds.count > 1 ? "s" : "") selected").font(.headline)
            if !loaded {
                ProgressView().controlSize(.small)
            } else if targets.isEmpty {
                Text("No \(kind.itemWord) to act on in these photos.").foregroundStyle(.secondary)
            } else {
                Text([namedT.isEmpty ? nil : "\(namedT.count) named", unnamedT.isEmpty ? nil : "\(unnamedT.count) unnamed",
                      ignoredT.isEmpty ? nil : "\(ignoredT.count) ignored"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(owner == nil ? "Name as…" : "Move to…", text: $name)
                        .textFieldStyle(.roundedBorder).frame(width: 220).focused($focused)
                        .onSubmit(nameAll)
                        .onKeyPress(.tab) { if let m = matches.first { name = m; return .handled }; return .ignored }
                    Button("OK", action: nameAll).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches, id: \.self) { m in
                            Button { name = m; nameAll() } label: { Label(m, systemImage: kind == .face ? "person" : "pawprint") }.buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                HStack {
                    if let o = owner {
                        let sug = suggestedT.filter { $0.suggestedPersonId == o.id }
                        if !sug.isEmpty {
                            Button { run { _ = try await $0.assign(kind, sug.map(\.id), to: o.id) } } label: { Label("Confirm \(sug.count)", systemImage: "checkmark") }
                            Button { run { lib in for f in sug { _ = try await lib.reject(kind, owner: o.id, mediaIds: [f.mediaId]) } } } label: {
                                Label("Reject \(sug.count)", systemImage: "xmark")
                            }
                        }
                        let mine = namedT.filter { $0.personId == o.id }
                        if !mine.isEmpty {
                            Button(role: .destructive) { run { _ = try await $0.unassign(kind, mine.map(\.id)) } } label: {
                                Label("Not \(o.name) (\(mine.count))", systemImage: "person.crop.circle.badge.xmark")
                            }
                        }
                    } else {
                        if !unnamedT.isEmpty {
                            Button(role: .destructive) { run { _ = try await $0.setIgnored(kind, unnamedT.map(\.id), true) } } label: {
                                Label("Ignore \(unnamedT.count)", systemImage: "eye.slash")
                            }
                        }
                        if !ignoredT.isEmpty {
                            Button { run { _ = try await $0.setIgnored(kind, ignoredT.map(\.id), false) } } label: {
                                Label("Restore \(ignoredT.count)", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                    Spacer()
                    Button("Cancel") { Popup.close() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 340)
        .onAppear { model.typing = true }
        .onDisappear { model.typing = false }
        .task {
            known = ((try? await model.library.owners(kind)) ?? []).map(\.name)
            await pickTargets()
            focused = true
        }
    }

    /// One face / animal per photo: the owner's (confirmed or suggested), or the largest one in the
    /// categories shown.
    func pickTargets() async {
        var out: [FaceRecord] = []
        for m in mediaIds.prefix(500) {
            let rs = (try? await model.library.regions(kind, mediaId: m)) ?? []
            let candidates = rs.filter { r in
                if let o = owner { return r.personId == o.id || (r.personId == nil && !r.ignored && r.suggestedPersonId == o.id) }
                if r.ignored { return ignored }
                return r.personId != nil ? named : unnamed
            }
            if let best = candidates.max(by: { $0.w * $0.h < $1.w * $1.h }) { out.append(best) }
        }
        targets = out
        loaded = true
    }

    /// One name for all: named ones that had another name are taken from it first (remembered as wrong).
    func nameAll() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let (k, all) = (kind, targets)
        run { lib in
            let renamed = all.filter { $0.personId != nil }.map(\.id)
            if !renamed.isEmpty { _ = try await lib.unassign(k, renamed) }
            _ = try await lib.nameItems(k, all.map(\.id), name: n)
        }
    }

    func run(_ body: @escaping @Sendable (Library) async throws -> Void) {
        Popup.close()
        Task { await model.identityEdit(kind, body) }
    }
}
