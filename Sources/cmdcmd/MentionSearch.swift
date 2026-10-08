import Foundation

/// File index over the workspace root for @-mentions. Enumerated lazily on a
/// background queue, cached for a minute, fuzzy-matched on keystroke.
@MainActor
final class MentionSearch: ObservableObject {
    @Published var results: [(url: URL, rel: String)] = []

    private struct Item { let url: URL; let rel: String; let name: String }
    private var index: [Item] = []
    private var indexedAt: Date = .distantPast
    private var indexedRoot: URL?
    private var indexing = false

    /// Directories that are never worth indexing.
    private let skipDirs: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "DerivedData",
        ".next", "dist", "build", "target", ".venv", "venv", "__pycache__",
        "Library", ".Trash", ".npm", ".cache", ".cargo", ".rustup",
        "go", "Pods", ".idea", ".vscode", ".swiftpm", "Public", "Applications",
    ]

    func query(_ q: String, root: URL) {
        if indexedRoot != root || Date().timeIntervalSince(indexedAt) > 60 {
            rebuild(root)
        }
        let needle = q.lowercased()
        if needle.isEmpty {
            results = Array(index.prefix(8)).map { ($0.url, $0.rel) }
            return
        }
        // basename hit beats path hit; shorter path beats longer.
        let scored: [(Int, Item)] = index.compactMap { item in
            if item.name.lowercased().hasPrefix(needle) { return (0, item) }
            if item.name.lowercased().contains(needle) { return (1, item) }
            if item.rel.lowercased().contains(needle) { return (2 + item.rel.count, item) }
            return nil
        }
        results = scored.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1.rel < $1.1.rel
        }.prefix(8).map { ($0.1.url, $0.1.rel) }
    }

    private func rebuild(_ root: URL) {
        guard !indexing else { return }
        indexing = true
        let skip = skipDirs
        Task.detached(priority: .utility) { [weak self] in
            var items: [Item] = []
            let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            let base = root.path + "/"
            loop: while let url = en?.nextObject() as? URL {
                let name = url.lastPathComponent
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if vals?.isDirectory == true {
                    if skip.contains(name) { en?.skipDescendants() }
                    continue
                }
                let rel = url.path.hasPrefix(base)
                    ? String(url.path.dropFirst(base.count)) : url.path
                items.append(Item(url: url, rel: rel, name: name))
                if items.count >= 40_000 { break loop }
            }
            let rootNow = root
            await MainActor.run { [weak self] in
                guard let self, self.indexing else { return }
                self.index = items
                self.indexedAt = Date()
                self.indexedRoot = rootNow
                self.indexing = false
            }
        }
    }
}
