import AppKit
import PicasaCore
import SwiftUI

/// Sidebar ▸ Folders: one card per root folder added to the library (File ▸ Add Folder, or
/// `picasa-cli scan`), with its photos and videos, its last scan, and the work in progress on it —
/// a job of the app (stage and file from its progress reports) or of picasa-cli in a terminal
/// (seen through the pending counts, refreshed when the library changes).
/// Layout and style follow the Folders page of DirStat: a header bar, then a grid of cards.
struct RootsView: View {
    @EnvironmentObject private var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)]

    var body: some View {
        let cards = model.rootCards
        VStack(spacing: 0) {
            header(cards)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if cards.isEmpty {
                        Label("No folder in the library yet: add one with File ▸ Add Folder to Library… (⌘O).", systemImage: "folder.badge.plus")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Library Folders").font(.headline)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(cards) { RootCardView(card: $0, active: model.activeRootId == $0.id) }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.loadRootCards() }
    }

    private func header(_ cards: [RootCard]) -> some View {
        let photos = cards.reduce(0) { $0 + $1.stats.photos }
        let videos = cards.reduce(0) { $0 + $1.stats.videos }
        let away = cards.filter { !$0.available }.count
        let pending = cards.reduce(0) { $0 + $1.stats.pending }
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Folders")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text("Each folder added to the library, what it holds and the work left on it")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 16) {
                    note("\(cards.count) folder\(cards.count == 1 ? "" : "s") · \(photos.formatted()) photos · \(videos.formatted()) videos", "folder")
                    if away > 0 { note("\(away) not connected: their photos stay in the library", "bolt.horizontal.circle", tint: .orange) }
                    if pending > 0 { note("\(pending.formatted()) steps to do", "hourglass", tint: .orange) }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { model.rescan() } label: { Label("Rescan All", systemImage: "arrow.clockwise") }
                    .disabled(model.job != nil || cards.isEmpty)
                Button { model.addFolder() } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func note(_ text: String, _ icon: String, tint: Color? = nil) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .monospacedDigit()
            .lineLimit(1)
    }
}

private struct RootCardView: View {
    @EnvironmentObject private var model: AppModel
    let card: RootCard
    /// A job of the app is working in this folder now.
    let active: Bool

    private var s: Library.RootStats { card.stats }

    private var systemImage: String {
        switch card.volume {
        case .network: "network"
        case .externalSSD, .hdd: card.stats.path.hasPrefix("/Volumes/") ? "externaldrive" : "internaldrive"
        case .internalSSD, .unknown: "internaldrive"
        }
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(card.available ? Color.accentColor : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.name).font(.headline).lineLimit(1)
                        Text(s.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if active {
                        Text("Processing").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    } else if !card.available {
                        Label("Not connected", systemImage: "bolt.horizontal.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("\(s.photos.formatted()) photo\(s.photos == 1 ? "" : "s") · \(s.videos.formatted()) video\(s.videos == 1 ? "" : "s")")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                progress
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Label(s.lastScan.map { "Scanned \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not scanned yet", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: active ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Show the photos and videos of this folder and its subfolders")
        .contextMenu {
            Button("Show Photos") { open() }
            Button("Scan Again") { model.rescan(root: s.path) }
                .disabled(!card.available || model.job != nil)
            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.path) }
                .disabled(!card.available)
        }
    }

    private func open() { model.selection = .filter(.root(s.id), card.name) }

    /// Files counted by a stage: metadata reads every file, the other stages skip ignored small images.
    private var files: Int { s.photos + s.videos + s.copies }

    /// The stage running here (from the app's job), or the work left (also when picasa-cli runs it).
    /// Always two lines high, like DirStat's capacity bar, so the cards line up.
    @ViewBuilder private var progress: some View {
        if active, let stage = model.jobStage {
            let left: Int? = switch stage {
            case "metadata": s.pendingMeta
            case "thumbnails": s.pendingThumbs
            case "analysis": max(s.pendingAnalysis, s.pendingFaces)
            default: nil
            }
            if let left, files > 0 {
                ProgressView(value: Double(max(0, files - left)), total: Double(max(files, 1)))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("\(stage.capitalized) · \(model.jobDone.formatted()) done\(model.jobCurrent.map { " · \(($0 as NSString).lastPathComponent)" } ?? "")")
                .font(.caption).foregroundStyle(Color.accentColor).monospacedDigit().lineLimit(1).truncationMode(.middle)
                .help(model.jobCurrent ?? "")
        } else if s.pending > 0 {
            let done = files > 0 ? Double(max(0, files * 4 - s.pendingMeta - s.pendingThumbs - s.pendingAnalysis - s.pendingFaces)) / Double(files * 4) : 0
            ProgressView(value: min(1, done))
                .tint(.orange)
                .help("Share of the indexing and analysis done in this folder")
            Text(todo)
                .font(.caption).foregroundStyle(.orange).monospacedDigit().lineLimit(1).truncationMode(.tail)
                .help(model.externalActivity ? "Being processed by another program (picasa-cli)" : "Processed on the next run (Processing menu, or picasa-cli index / analyze)")
        } else {
            ProgressView(value: 0).hidden()
            Label(files > 0 ? "Indexed and analysed" : (card.available ? "No photos found" : "Its volume is not mounted"),
                  systemImage: files > 0 ? "checkmark.circle" : "info.circle")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var todo: String {
        var parts: [String] = []
        if s.pendingMeta > 0 { parts.append("\(s.pendingMeta.formatted()) metadata") }
        if s.pendingThumbs > 0 { parts.append("\(s.pendingThumbs.formatted()) thumbnails") }
        if s.pendingAnalysis > 0 { parts.append("\(s.pendingAnalysis.formatted()) analysis") }
        if s.pendingFaces > 0 { parts.append("\(s.pendingFaces.formatted()) faces") }
        return (model.externalActivity ? "Processing: " : "To do: ") + parts.joined(separator: " · ")
    }

    private var details: String {
        var parts = ["\(s.folders.formatted()) folder\(s.folders == 1 ? "" : "s")",
                     ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file),
                     card.volume.rawValue]
        if s.copies > 0 { parts.append("\(s.copies.formatted()) copies hidden") }
        if s.ignored > 0 { parts.append("\(s.ignored.formatted()) small ignored") }
        return parts.joined(separator: " · ")
    }
}
