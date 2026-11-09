import AppKit
import Common

// The saved world is written as JSON (see `SavedWorld` below).
extension Layout: Codable {}

extension Orientation: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
            case "h": self = .h
            case "v": self = .v
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown orientation \(raw)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .h ? "h" : "v")
    }
}

#if AEROSPACE_EMBEDDED

    /// The world kept on disk so a new engine puts every window back on its workspace.
    ///
    /// Without it an engine that starts while apps are already open (Space Cube relaunched, the
    /// engine restarted after a crash) knows nothing of where the windows were, and gives them
    /// all to the workspace each monitor starts on: the first one, `0`.
    ///
    /// The world is written after each refresh session that changed it and read once at startup
    /// into the closed windows cache, which then restores each window as it is detected again.
    /// Window ids last only as long as the window, so the world is read only within the same boot,
    /// and a window counts only while the process that owned it is still running.
    struct SavedWorld: Codable, Equatable {
        var bootTime: Int
        var focusedWorkspace: String
        var world: FrozenWorld
        /// Window id to the pid of the app that owned it.
        var owners: [UInt32: Int32]
        var cornerParkings: [UInt32: SavedCornerParking]
    }

    struct SavedCornerParking: Codable, Equatable {
        let position: CGPoint
        let floatingSize: CGSize?
    }

    extension SavedWorld {
        /// The saved world with only the windows `isAlive` keeps, or nil when none are left.
        /// A gone window must go from the trees too: restoring a tree stops at the first window it
        /// cannot find, which would leave every window after it where startup put it.
        func keeping(_ isAlive: (_ windowId: UInt32, _ pid: Int32) -> Bool) -> SavedWorld? {
            let alive = owners.filter { isAlive($0.key, $0.value) }
            let ids = Set(alive.keys)
            let windowIds = world.windowIds.intersection(ids)
            if windowIds.isEmpty { return nil }
            var result = self
            result.owners = alive
            result.cornerParkings = cornerParkings.filter { ids.contains($0.key) }
            result.world = FrozenWorld(
                workspaces: world.workspaces.map { $0.keeping(ids) },
                monitors: world.monitors,
                windowIds: windowIds,
            )
            return result
        }
    }

    extension FrozenWorkspace {
        fileprivate func keeping(_ ids: Set<UInt32>) -> FrozenWorkspace {
            FrozenWorkspace(
                name: name,
                monitor: monitor,
                rootTilingNode: rootTilingNode.keeping(ids) ?? rootTilingNode.emptied,
                floatingWindows: floatingWindows.filter { ids.contains($0.id) },
                macosUnconventionalWindows: macosUnconventionalWindows.filter { ids.contains($0.id) },
            )
        }

        init(name: String, monitor: FrozenMonitor, rootTilingNode: FrozenContainer, floatingWindows: [FrozenWindow], macosUnconventionalWindows: [FrozenWindow]) {
            self.name = name
            self.monitor = monitor
            self.rootTilingNode = rootTilingNode
            self.floatingWindows = floatingWindows
            self.macosUnconventionalWindows = macosUnconventionalWindows
        }
    }

    extension FrozenContainer {
        /// The container without the windows outside `ids`, or nil when nothing is left in it.
        fileprivate func keeping(_ ids: Set<UInt32>) -> FrozenContainer? {
            let kept: [FrozenTreeNode] = children.compactMap {
                switch $0 {
                    case .window(let w): ids.contains(w.id) ? $0 : nil
                    case .container(let c): c.keeping(ids).map(FrozenTreeNode.container)
                }
            }
            return kept.isEmpty ? nil : FrozenContainer(children: kept, layout: layout, orientation: orientation, weight: weight)
        }

        fileprivate var emptied: FrozenContainer {
            FrozenContainer(children: [], layout: layout, orientation: orientation, weight: weight)
        }

        init(children: [FrozenTreeNode], layout: Layout, orientation: Orientation, weight: CGFloat) {
            self.children = children
            self.layout = layout
            self.orientation = orientation
            self.weight = weight
        }
    }

    // MARK: On disk

    private let savedWorldUrl = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Space Cube/engine-world.json")

    @MainActor private var lastSavedWorld: SavedWorld? = nil
    @MainActor private var pendingCornerParkings: [UInt32: (pid: Int32, parking: SavedCornerParking)] = [:]

    /// Writes the world when it changed since the last write. An empty world is not written: it is
    /// what the lock screen looks like, and the windows come back once the screen is unlocked.
    @MainActor func saveWorldIfChanged() {
        let windows = MacWindow.allWindows
        if windows.isEmpty { return }
        let allWs = Workspace.all
        let saved = SavedWorld(
            bootTime: bootTime(),
            focusedWorkspace: focus.workspace.name,
            world: FrozenWorld(
                workspaces: allWs.map { FrozenWorkspace($0) },
                monitors: monitors.map(FrozenMonitor.init),
                windowIds: allWs.flatMap { collectAllWindowIdsRecursive($0) }.toSet(),
            ),
            owners: Dictionary(windows.map { ($0.windowId, $0.macApp.pid) }, uniquingKeysWith: { a, _ in a }),
            cornerParkings: Dictionary(windows.compactMap { w in w.cornerParking.map { (w.windowId, $0) } }, uniquingKeysWith: { a, _ in a }),
        )
        if saved == lastSavedWorld { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(saved)
            try FileManager.default.createDirectory(at: savedWorldUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: savedWorldUrl, options: .atomic)
            lastSavedWorld = saved
        } catch {
            eprint("Could not save the window layout: \(error)")
        }
    }

    /// Reads the world an earlier engine of this boot saved and hands it to the closed windows
    /// cache. Returns the workspace that had focus, to start on it.
    @MainActor func loadSavedWorld() -> String? {
        guard let data = try? Data(contentsOf: savedWorldUrl) else { return nil }
        guard let saved = try? JSONDecoder().decode(SavedWorld.self, from: data) else {
            eprint("Could not read the saved window layout at \(savedWorldUrl.path)")
            return nil
        }
        guard saved.bootTime == bootTime() else { return nil }
        guard let alive = saved.keeping({ _, pid in kill(pid, 0) == 0 }) else { return nil }
        loadClosedWindowsCache(alive.world)
        pendingCornerParkings = [:]
        for (id, parking) in alive.cornerParkings {
            if let pid = alive.owners[id] { pendingCornerParkings[id] = (pid, parking) }
        }
        lastSavedWorld = alive
        eprint("Restoring \(alive.world.windowIds.count) windows to their workspaces")
        return alive.focusedWorkspace
    }

    /// Where a window detected again had been parked, once, if the same app still owns it.
    @MainActor func takeSavedCornerParking(windowId: UInt32, pid: Int32) -> SavedCornerParking? {
        guard let pending = pendingCornerParkings.removeValue(forKey: windowId), pending.pid == pid else { return nil }
        return pending.parking
    }

    private func bootTime() -> Int {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard unsafe sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return 0 }
        return time.tv_sec
    }
#endif
