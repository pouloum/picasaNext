import PicasaCore
import SwiftUI

/// Search bar with token chips, in pure SwiftUI (an AppKit NSTokenField in the toolbar fought SwiftUI
/// layout: lost keystrokes, crashes).
/// - Typing shows matching people / labels / albums as suggestion pills right below the field;
///   Tab or Return accepts the highlighted one, ←/→ change it, a click accepts any.
/// - Chosen terms are coloured chips with a ✕; Delete in an empty field removes the last one.
/// - Text that matches nothing stays plain text and is searched as free text (every word must match).
struct SearchBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    var suggestions: [SearchTerm] {
        let k = Self.fold(model.search.trimmingCharacters(in: .whitespaces))
        guard !k.isEmpty else { return [] }
        var prefix: [SearchTerm] = [], inner: [SearchTerm] = []
        for t in model.vocabulary where !model.tokens.contains(t) {
            let f = Self.fold(t.title)
            if f.hasPrefix(k) { prefix.append(t) } else if f.contains(k) { inner.append(t) }
            if prefix.count >= 8 { break }
        }
        return Array((prefix + inner).prefix(8))
    }

    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    var body: some View {
        let sugg = suggestions
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                ForEach(model.tokens) { t in
                    TokenChip(term: t) { remove(t) }
                }
                TextField(model.tokens.isEmpty ? "Search people, labels, albums, file names…" : "", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { accept(sugg) }
                    .onKeyPress(.tab) { accept(sugg) ? .handled : .ignored }
                    .onKeyPress(.rightArrow) { move(+1, sugg) }
                    .onKeyPress(.leftArrow) { move(-1, sugg) }
                    .onKeyPress(.delete) {
                        guard model.search.isEmpty, let last = model.tokens.last else { return .ignored }
                        remove(last)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard model.isSearching else { return .ignored }
                        model.clearSearch()
                        return .handled
                    }
                if model.isSearching {
                    Button { model.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search (Esc)")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if !sugg.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Tab ⇥").font(.caption2).foregroundStyle(.tertiary)
                        ForEach(Array(sugg.enumerated()), id: \.element) { i, t in
                            SuggestionPill(term: t, highlighted: i == min(highlighted, sugg.count - 1))
                                .onTapGesture { add(t) }
                        }
                    }
                }
            }
        }
        .onChange(of: model.search) { highlighted = 0; Task { await model.reloadGrid() } }
    }

    @discardableResult
    func accept(_ sugg: [SearchTerm]) -> Bool {
        guard !sugg.isEmpty else { return false }
        add(sugg[min(highlighted, sugg.count - 1)])
        return true
    }

    func move(_ d: Int, _ sugg: [SearchTerm]) -> KeyPress.Result {
        guard !sugg.isEmpty else { return .ignored }
        highlighted = (min(highlighted, sugg.count - 1) + d + sugg.count) % sugg.count
        return .handled
    }

    func add(_ t: SearchTerm) {
        if !model.tokens.contains(t) { model.tokens.append(t) }
        model.search = ""
        highlighted = 0
        focused = true
        Task { await model.reloadGrid() }
    }

    func remove(_ t: SearchTerm) {
        model.tokens.removeAll { $0 == t }
        Task { await model.reloadGrid() }
    }
}

extension SearchTerm {
    var icon: String {
        switch self {
        case .person: "person.crop.circle.fill"
        case .label: "tag.fill"
        case .album: "rectangle.stack.fill"
        }
    }
    var tint: Color {
        switch self {
        case .person: .blue
        case .label: .green
        case .album: .purple
        }
    }
}

/// A chosen search term: coloured capsule with an icon and a remove button.
struct TokenChip: View {
    let term: SearchTerm
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: term.icon).font(.caption)
            Text(term.title).font(.callout.weight(.medium)).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.plain).help("Remove")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(Capsule().fill(term.tint.gradient))
    }
}

/// A completion offered for the text being typed.
struct SuggestionPill: View {
    let term: SearchTerm
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: term.icon).font(.caption).foregroundStyle(term.tint)
            Text(term.title).font(.callout).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(highlighted ? term.tint.opacity(0.25) : Color.secondary.opacity(0.12)))
        .overlay(Capsule().stroke(highlighted ? term.tint : .clear, lineWidth: 1.5))
        .contentShape(Capsule())
    }
}
