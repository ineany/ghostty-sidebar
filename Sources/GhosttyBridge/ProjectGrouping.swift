import Foundation

/// Items that belong to one project, in the order they were given.
public struct ProjectGroup<Item>: Identifiable {
    /// The project's folder; nil for items without a folder ("기타").
    public let root: String?
    public var items: [Item]

    public var id: String { root ?? "" }

    /// Last path component, e.g. "wallet"; nil for the "기타" group.
    public var name: String? {
        guard let root else { return nil }
        let last = (root as NSString).lastPathComponent
        return last.isEmpty ? root : last
    }
}

public enum ProjectGrouping {
    /// Groups items by project. Groups keep the order of their first item, so
    /// the caller decides the order by sorting the items first. Items without a
    /// project go into one last group.
    public static func group<Item>(_ items: [Item], root: (Item) -> String?) -> [ProjectGroup<Item>] {
        var groups: [ProjectGroup<Item>] = []
        var index: [String: Int] = [:]
        var others: [Item] = []
        for item in items {
            guard let key = root(item) else { others.append(item); continue }
            if let i = index[key] {
                groups[i].items.append(item)
            } else {
                index[key] = groups.count
                groups.append(ProjectGroup(root: key, items: [item]))
            }
        }
        if !others.isEmpty { groups.append(ProjectGroup(root: nil, items: others)) }
        return groups
    }
}

public enum StableOrder {
    /// Keeps the ids already known in their first-seen order, drops the ones
    /// that are gone and appends new ones in `current` order. Ghostty lists
    /// windows front to back, so without this the project view would reshuffle
    /// every time another window comes to the front.
    public static func update(known: [String], current: [String]) -> [String] {
        let alive = Set(current)
        var result = known.filter { alive.contains($0) }
        var seen = Set(result)
        for id in current where seen.insert(id).inserted { result.append(id) }
        return result
    }
}

/// Finds the project folder for a working directory: the nearest folder that
/// holds `.git` (a directory, or a file in a linked worktree). Without one, the
/// directory itself is the project, so plain folders still group together.
///
/// Only folders under the home folder are searched. Other paths (external
/// disks, network mounts) are their own project without touching the disk,
/// because a stat on a sleeping mount can block the main thread.
///
/// Results are cached because the sidebar asks every second for every tab.
/// Each entry expires after `lifetime`, so a later `git init` is picked up and
/// the lookups do not all happen in the same frame.
public final class ProjectResolver: @unchecked Sendable {
    private let fileExists: (String) -> Bool
    private let lifetime: TimeInterval
    private let now: () -> Date
    private let home: String
    private var cache: [String: (root: String, at: Date)] = [:]
    private let lock = NSLock()

    public init(lifetime: TimeInterval = 60,
                now: @escaping () -> Date = Date.init,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
        self.lifetime = lifetime
        self.now = now
        self.home = home
    }

    /// nil when there is no usable directory.
    public func root(for directory: String?) -> String? {
        guard let directory = Self.normalize(directory) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let time = now()
        if let hit = cache[directory], time.timeIntervalSince(hit.at) <= lifetime { return hit.root }
        let found = Self.gitRoot(of: directory, home: home, fileExists: fileExists) ?? directory
        cache[directory] = (found, time)
        return found
    }

    static func normalize(_ directory: String?) -> String? {
        guard var path = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Walks up from `directory` and stops below the home folder, so a dotfiles
    /// repo in the home folder does not swallow every tab.
    static func gitRoot(of directory: String, home: String, fileExists: (String) -> Bool) -> String? {
        guard directory.hasPrefix(home + "/") else { return nil }
        var current = directory
        while current != home && current.count > home.count {
            if fileExists(current + "/.git") { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }
}
