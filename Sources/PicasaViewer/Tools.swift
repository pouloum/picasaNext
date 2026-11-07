import AppKit
import PicasaCore
import SwiftUI

// What picasa-cli does, from the menus: the sheets they open (File ▸ Export, Processing ▸ …) and the
// Settings window. Everything goes through PicasaCore (Pipeline, Library), like the CLI.

/// The sheet asked for by a menu (`AppModel.sheet`).
struct ToolSheet: View {
    let sheet: AppModel.Sheet
    var body: some View {
        switch sheet {
        case .export: ExportSheet()
        case .mergeNames: MergeNamesSheet()
        case .plan: PlanSheet()
        case .redoAnalysis: RedoAnalysisSheet()
        case .redoThumbnails: RedoThumbnailsSheet()
        }
    }
}

// MARK: - Export (picasa-cli export)

/// File ▸ Export Edits to Photo Folders…: a dry run first, showing what would be written; the files
/// are only written after that, on the user's word.
struct ExportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: Pipeline.ExportFormat = .picasa
    @State private var folder: String?
    @State private var preview: Pipeline.ExportReport?
    @State private var written: Pipeline.ExportReport?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Edits to Photo Folders").font(.title3.bold())
            Text("Writes the library's stars, captions, people, pets, keywords and albums next to the photos. "
                 + "Nothing else in PicasaNext ever writes in your photo folders.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("Format", selection: $format) {
                    Text("Picasa (.picasa.ini in each folder)").tag(Pipeline.ExportFormat.picasa)
                    Text("XMP sidecars (one .xmp per photo)").tag(Pipeline.ExportFormat.xmp)
                    Text("Both").tag(Pipeline.ExportFormat.all)
                }
                LabeledContent("Folders") {
                    HStack {
                        Text(folder ?? "The whole library").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if folder != nil { Button("Whole Library") { folder = nil } }
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(working || written != nil)
            .onChange(of: format) { preview = nil }
            .onChange(of: folder) { preview = nil }

            Text(formatNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let r = written ?? preview {
                VStack(alignment: .leading, spacing: 6) {
                    Label(written != nil ? "Written" : "Preview (nothing written yet)",
                          systemImage: written != nil ? "checkmark.circle.fill" : "eye")
                        .font(.headline).foregroundStyle(written != nil ? .green : .primary)
                    Text(r.description).font(.callout.monospaced()).textSelection(.enabled)
                    if !r.failed.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(Array(r.failed.prefix(200).enumerated()), id: \.offset) { _, f in
                                    Text("\(f.path): \(f.error)").font(.caption.monospaced()).foregroundStyle(.red)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if working { ProgressView().controlSize(.small); Text(model.jobDetail ?? "").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if written != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    if let p = preview {
                        Button(writeTitle(p)) { run(dryRun: false) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(working || toWrite(p) == 0)
                    } else {
                        Button("Preview") { run(dryRun: true) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(working || model.job != nil)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    var formatNote: String {
        switch format {
        case .picasa: "Each folder's previous .picasa.ini is kept as .picasa.ini.bak; rotations, filters and unknown keys are kept."
        case .xmp: "IMG_0001.xmp next to IMG_0001.jpg: rating, caption, keywords, people and pets as named regions. Sidecars made by other programs are left alone."
        case .all: "Both: .picasa.ini per folder (previous one kept as .bak) and one .xmp sidecar per photo (other programs' sidecars left alone)."
        }
    }

    func toWrite(_ r: Pipeline.ExportReport) -> Int { (r.ini?.changed ?? 0) + (r.xmp?.changed ?? 0) }

    func writeTitle(_ r: Pipeline.ExportReport) -> String {
        let n = toWrite(r)
        return n == 0 ? "Nothing to Write" : "Write \(n) File\(n > 1 ? "s" : "")"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Export only the photos under this folder."
        if panel.runModal() == .OK, let u = panel.url { folder = u.standardizedFileURL.path }
    }

    func run(dryRun: Bool) {
        let (f, only) = (format, folder)
        working = true
        Task {
            let r = await model.runJobAwaiting(dryRun ? "Export preview" : "Exporting") { lib, report in
                try await Pipeline.export(lib, format: f, dryRun: dryRun, only: only, progress: report)
            }
            working = false
            if dryRun { preview = r } else { written = r }
        }
    }
}

// MARK: - Duplicate names (picasa-cli merge-duplicates)

/// Processing ▸ Merge Duplicate Names…: people and pets with the same name, the one kept first.
struct MergeNamesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [(kind: IdentityKind, groups: [[PersonSummary]])]?

    var count: Int { groups?.reduce(0) { $0 + $1.groups.count } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Duplicate Names").font(.title3.bold())
            Text("People (and pets) with the same name — case, accents and spaces ignored — for example one person imported from several Picasa contacts. Each group is merged into the one with the most photos.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let groups {
                if count == 0 {
                    Label("No duplicate names.", systemImage: "checkmark.circle").padding(.vertical, 20)
                } else {
                    List {
                        ForEach(groups.filter { !$0.groups.isEmpty }, id: \.kind) { k in
                            Section(k.kind == .face ? "People" : "Pets") {
                                ForEach(k.groups, id: \.first!.id) { g in
                                    HStack {
                                        Text(g[0].name).bold()
                                        Spacer()
                                        Text(g.map { "#\($0.id) (\($0.faces))" }.joined(separator: " + ") + "  →  #\(g[0].id)")
                                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 380)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            }
            HStack {
                Spacer()
                Button(count == 0 ? "Close" : "Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if count > 0 {
                    Button("Merge \(count) Group\(count > 1 ? "s" : "")") {
                        if let groups { model.mergeDuplicateNames(groups) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            do { groups = try await Pipeline.duplicateNames(model.library) } catch { model.error = "\(error)"; groups = [] }
        }
    }
}

// MARK: - Performance plan (picasa-cli profile)

/// Processing ▸ Show Performance Plan…: the disk of each root and how each stage will run.
struct PlanSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plans: [Pipeline.RootPlan]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance Plan").font(.title3.bold())
            Picker("Profile", selection: $model.throughputProfile) {
                ForEach(ThroughputProfile.allCases, id: \.self) { Text(PicasaNextApp.profileLabel($0)).tag($0) }
            }
            .frame(maxWidth: 360)
            Text("Machine: \(Pipeline.machineSummary)").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plans ?? [], id: \.path) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(r.path, systemImage: r.volume.kind == .network ? "network" : "externaldrive")
                                .font(.headline).lineLimit(1).truncationMode(.middle)
                            Text("\(r.volume.kind.rawValue) · \(r.volume.fileSystem) · mounted at \(r.volume.mountPoint)")
                                .font(.caption).foregroundStyle(.secondary)
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                                ForEach(r.stages, id: \.stage) { s in
                                    GridRow {
                                        Text(s.stage.rawValue.capitalized).foregroundStyle(.secondary)
                                        Text(s.plan.summary)
                                        Text(s.lastRun.map { "last run: \($0.concurrency) parallel, batches of \($0.batch)" } ?? "")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .font(.callout)
                        }
                    }
                    if plans?.isEmpty == true { Text("No folders in the library yet.").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: 360)
            HStack {
                Button("Forget Tuned Values") { model.forgetTuning(); Task { await load() } }
                    .help("The next run starts again from the values of the profile")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
        .task(id: model.throughputProfile) { await load() }
    }

    func load() async {
        try? await Task.sleep(for: .milliseconds(100)) // after a profile / tuning change is saved
        plans = (try? await Pipeline.plans(model.library, profile: model.throughputProfile)) ?? []
    }
}

// MARK: - Redo (picasa-cli analyze --redo, index --redo-thumbs)

struct RedoAnalysisSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redo Analysis").font(.title3.bold())
            Text("Every image is analyzed again: faces, labels, animals, scores and similar-photo prints. This reads every photo and can take hours on a large library.")
                .fixedSize(horizontal: false, vertical: true)
            Text("What you decided on faces and animals is kept: names, ignored faces, confirmed and rejected suggestions.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Also drop those manual decisions", isOn: $includeManual)
            if includeManual {
                Label("Every name given to a face or an animal, every ignore, confirmation and rejection will be lost.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(includeManual ? "Redo and Drop Decisions" : "Redo Analysis", role: includeManual ? .destructive : nil) {
                    model.analyzePending(redo: true, includeManual: includeManual)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct RedoThumbnailsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Regenerate All Thumbnails").font(.title3.bold())
            Text("Every thumbnail is made again from the photos (with the sizes in Settings ▸ Processing). This reads every photo; until each one is redone, the old thumbnail is shown.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Regenerate") { model.indexPending(redoThumbs: true); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Settings (saved in the library, shared with picasa-cli)

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings().tabItem { Label("Library", systemImage: "folder") }
            ProcessingSettings().tabItem { Label("Processing", systemImage: "gearshape.2") }
            PlacesSettings().tabItem { Label("Places", systemImage: "mappin.and.ellipse") }
        }
        .frame(width: 600)
    }
}

/// Roots (remove-root) and exclusions (scan --exclude, excludes, unexclude).
struct LibrarySettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var roots: [(path: String, mounted: Bool)] = []
    @State private var excludes: [String] = []
    @State private var newExclude = ""
    @State private var removing: String?

    var body: some View {
        Form {
            Section {
                if roots.isEmpty { Text("No folders yet: File ▸ Add Folder to Library…").foregroundStyle(.secondary) }
                ForEach(roots, id: \.path) { r in
                    HStack {
                        Image(systemName: r.mounted ? "externaldrive.fill" : "externaldrive.badge.xmark")
                            .foregroundStyle(r.mounted ? Color.secondary : Color.red)
                        Text(r.path).lineLimit(1).truncationMode(.middle)
                            .help(r.mounted ? r.path : "\(r.path) — not available (disk not mounted?)")
                        Spacer()
                        Button("Remove…") { removing = r.path }.disabled(model.job != nil)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Folder…") { model.addFolder() }
                    Button("Rescan") { model.rescan() }.disabled(model.job != nil)
                }
            } header: { Text("Folders") } footer: {
                Text("Removing a folder only forgets it and its index here; the photos are not touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Watch folders for new items", isOn: $model.watchFolders)
            } footer: {
                Text("New photos and videos are found on their own: those added while PicasaNext was closed at launch, "
                     + "then as they arrive. Network shares are rescanned every 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(excludes, id: \.self) { e in
                    HStack {
                        Image(systemName: e.hasPrefix("/") ? "folder" : "textformat").foregroundStyle(.secondary)
                        Text(e).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { unexclude(e) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop excluding (rescan to index it again)")
                    }
                }
                HStack {
                    TextField("Folder name, or absolute path", text: $newExclude).onSubmit(addExclude)
                    Button("Choose…") { chooseExclude() }
                    Button("Add", action: addExclude).disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("Excluded folders") } footer: {
                Text("A name is skipped anywhere (e.g. Backups); a path only there. Always skipped: "
                     + Library.defaultExcludedNames.sorted().joined(separator: ", ")
                     + ". Applies on the next scan; after removing one, rescan to index that folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .task(id: model.revision) { await load() }
        .confirmationDialog("Remove this folder from the library?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { path in
            Button("Remove from Library", role: .destructive) { model.removeRoot(path) }
        } message: { path in
            Text("\(path)\n\nIts photos, people, labels and edits made here are dropped from the index. The photos themselves are not touched; add the folder again to index it anew.")
        }
    }

    func load() async {
        roots = ((try? await model.library.roots()) ?? []).map { ($0.path, FileManager.default.fileExists(atPath: $0.path)) }
        excludes = (try? await model.library.excludes()) ?? []
    }

    func addExclude() {
        let p = Library.excludePattern(newExclude)
        guard !p.isEmpty else { return }
        newExclude = ""
        Task { do { try await model.library.addExclude(p) } catch { model.error = "\(error)" }; await load() }
    }

    func unexclude(_ e: String) {
        Task { _ = try? await model.library.removeExclude(e); await load() }
    }

    func chooseExclude() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Exclude"
        if panel.runModal() == .OK, let u = panel.url { newExclude = u.standardizedFileURL.path; addExclude() }
    }
}

/// Index sizes (index --min-size / --thumb-size), similar threshold (similar --threshold), profile.
struct ProcessingSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var minSize = Library.defaultMinSize
    @State private var thumbSize = Library.defaultThumbSize
    @State private var threshold = Double(Library.defaultSimilarThreshold)
    @State private var savedThreshold = Double(Library.defaultSimilarThreshold)
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Performance profile", selection: $model.throughputProfile) {
                    ForEach(ThroughputProfile.allCases, id: \.self) { Text(PicasaNextApp.profileLabel($0)).tag($0) }
                }
                HStack {
                    Spacer()
                    Button("Show Plan…") { model.sheet = .plan }
                    Button("Forget Tuned Values") { model.forgetTuning() }
                }
            } header: { Text("Indexing and analysis") }

            Section {
                sizeField("Minimum size (px)", value: $minSize, help: "Images whose longest side is smaller are ignored (icons, web graphics). 0: keep all.")
                sizeField("Without camera EXIF (px)", value: $thumbSize, help: "Images without camera EXIF smaller than this are ignored (other apps' thumbnails). 0: keep all.")
            } header: { Text("Small images") } footer: {
                Text("Applies to items indexed from now on; Processing ▸ Regenerate All Thumbnails… to apply everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Similarity threshold") {
                    HStack {
                        Slider(value: $threshold, in: 0.90...0.995, step: 0.005)
                        Text(String(format: "%.3f", threshold)).monospacedDigit().frame(width: 46)
                    }
                }
                HStack {
                    Button("Default (\(String(format: "%.2f", Library.defaultSimilarThreshold)))") { threshold = Double(Library.defaultSimilarThreshold) }
                    Spacer()
                    Button(threshold == savedThreshold ? "Rebuild Groups" : "Save and Rebuild Groups") { saveThreshold() }
                        .disabled(model.job != nil)
                }
            } header: { Text("Similar photos") } footer: {
                Text("Higher: only near-identical photos are grouped; lower: looser groups. Used by Similar, Bursts and Duplicates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            if let s = try? await model.library.indexSizes() { (minSize, thumbSize) = s }
            if let t = try? await model.library.similarThreshold() { threshold = Double(t); savedThreshold = threshold }
            loaded = true
        }
        .onChange(of: minSize) { saveSizes() }
        .onChange(of: thumbSize) { saveSizes() }
    }

    func sizeField(_ title: String, value: Binding<Int>, help: String) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("", value: value, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                Stepper("", value: value, in: 0...4096, step: 32).labelsHidden()
            }
        }
        .help(help)
    }

    func saveSizes() {
        guard loaded else { return }
        let (m, t, lib) = (minSize, thumbSize, model.library)
        Task { try? await lib.setIndexSizes(minSize: m, thumbSize: t) }
    }

    func saveThreshold() {
        let t = Float(threshold)
        savedThreshold = threshold
        Task {
            do { try await model.library.setSimilarThreshold(t) } catch { model.error = "\(error)"; return }
            model.findSimilar()
        }
    }
}

/// Geocode limit (geocode --limit).
struct PlacesSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var limited = false
    @State private var limit = 500
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Limit places named per run", isOn: $limited)
                if limited {
                    LabeledContent("At most") {
                        HStack {
                            TextField("", value: $limit, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                            Stepper("", value: $limit, in: 1...100_000, step: 100).labelsHidden()
                            Text("places")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Name Places Now") { model.geocode() }.disabled(model.job != nil)
                }
            } header: { Text("Naming places") } footer: {
                Text("Place names (town, region, country) come from Apple's geocoder: network needed, one request per ~2 km area, throttled by Apple, so a first run is slow. It resumes where it stopped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            if let l = try? await model.library.geocodeLimit() { limited = true; limit = l }
            loaded = true
        }
        .onChange(of: limited) { save() }
        .onChange(of: limit) { save() }
    }

    func save() {
        guard loaded else { return }
        let (n, lib) = (limited ? max(1, limit) : nil, model.library)
        Task { try? await lib.setGeocodeLimit(n) }
    }
}
