#if AEROSPACE_EMBEDDED
    import AppKit
    import Common

    /// Moves windows to their laid-out frames in eased steps rather than at once, so a layout
    /// change (a layout or resize key, a window opening or closing, one floating or tiling
    /// again) shows the windows travelling to their new places instead of jumping there.
    ///
    /// A layout pass holds its frames (`begin`, `hold`, `finish`). At the end of the pass the
    /// windows sent to the same frame as last time are set at once, as before (most passes
    /// change nothing: every refresh lays out again). The others start a motion from where
    /// they are, driven by one timer on the main actor that sets each window's frame through
    /// the accessibility API a step at a time. The apps draw every step themselves, as they do
    /// when a window is resized by hand, so nothing is pictured and nothing can mismatch.
    ///
    /// Not every change moves: nothing moves while a mouse button is down (the windows follow
    /// the pointer), at startup, from a window's parking place in a corner (the host turns a
    /// cube for that) or when a small new window arrives or has just gone again (popups some
    /// apps open as windows: making room for each of them would read as flicker).
    @MainActor
    enum WindowMotion {
        /// How long a motion takes: the same for a layout or resize key and for the windows
        /// making room for one that comes or filling in after one that goes.
        /// Read each time, so `defaults write dev.kenfos.space-cube.engine motionDuration -float 0.5`
        /// changes it live, no restart needed.
        static var duration: CFTimeInterval {
            let set = UserDefaults.standard.double(forKey: "motionDuration")
            return set > 0 ? set : 0.28
        }
        /// DEBUG: `defaults write dev.kenfos.space-cube.engine motionLog -bool true` logs each pass
        /// and each step to the engine's log.
        static let logging = UserDefaults.standard.bool(forKey: "motionLog")
        /// Steps per second, at most: an app that takes longer over a step skips to the next.
        private static let frameInterval: CFTimeInterval = 1.0 / 60
        /// A new window smaller than this part of the screen is a popup or a panel.
        private static let smallWindowShare: CGFloat = 1.0 / 12
        /// A small new window gone again this soon after it arrived was a popup.
        private static let popupLifetime: CFTimeInterval = 3

        private struct Held: Sendable {
            let windowId: UInt32
            let target: Rect
            let isNew: Bool
        }

        private struct Motion {
            let window: MacWindow
            let from: Rect
            let to: Rect
            let start: CFTimeInterval
            let duration: CFTimeInterval
            var steps = 0
        }

        private static var collecting = false
        private static var held: [Held] = []
        /// Where each window was last sent: the same frame again is set at once.
        private static var lastTargets: [UInt32: Rect] = [:]
        /// Where each window is on its way to, while its frame is still being read.
        private static var pendingTargets: [UInt32: Rect] = [:]
        private static var motions: [UInt32: Motion] = [:]
        private static var timer: Timer?
        /// When each small new window (a popup, a panel) arrived, for a few seconds: the layout
        /// snapping back once it is gone again is as instant as its arrival was.
        private static var smallArrivals: [UInt32: CFTimeInterval] = [:]

        static func begin() {
            collecting = true
            held = []
        }

        /// Keeps the frame for the end of the pass. False when no pass is collecting: set it now.
        static func hold(_ window: MacWindow, _ topLeft: CGPoint, _ size: CGSize) -> Bool {
            guard collecting else { return false }
            let target = Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height)
            held.append(Held(windowId: window.windowId, target: target, isNew: lastTargets[window.windowId] == nil))
            return true
        }

        /// Sets the frames that are no change at once, and starts the rest on their way.
        static func finish() {
            collecting = false
            let batch = held
            held = []
            let now = CACurrentMediaTime()
            smallArrivals = smallArrivals.filter { now - $0.value < popupLifetime }
            var changed: [Held] = []
            for item in batch {
                let id = item.windowId
                if let motion = motions[id], motion.to.isClose(to: item.target) { continue }  // on its way there
                if let pending = pendingTargets[id], pending.isClose(to: item.target) { continue }
                if motions[id] == nil, let last = lastTargets[id], last.isClose(to: item.target) {
                    MacWindow.allWindowsMap[id]?.macApp.setAxFrame(id, item.target.topLeftCorner, item.target.size)
                    continue
                }
                changed.append(item)
            }
            guard !changed.isEmpty else { return }

            // The layout snapping back once a small window that just appeared is gone again.
            let popupGone = smallArrivals.keys.contains { MacWindow.allWindowsMap[$0] == nil }
            if popupGone { smallArrivals = smallArrivals.filter { MacWindow.allWindowsMap[$0.key] != nil } }

            if isLeftMouseButtonDown || isStartup || popupGone {
                if logging {
                    let why = isLeftMouseButtonDown ? "the mouse is down" : isStartup ? "startup" : "a popup went"
                    log("pass: \(changed.count) new frame(s) set at once, \(why)")
                }
                for item in changed { set(item) }
                return
            }
            for item in changed { pendingTargets[item.windowId] = item.target }
            // Where the windows are now is read on their apps' threads: not under the layout
            // pass, which a later refresh may cancel.
            Task.startUnstructured { @MainActor in
                await start(changed)
            }
        }

        /// Starts the motions of `items`, from where their windows are now.
        private static func start(_ items: [Held]) async {
            // All the apps at once: each read waits on its app's thread.
            let reads = items.map { item in
                let id = item.windowId
                return Task { @MainActor () -> Rect? in
                    guard let window = MacWindow.allWindowsMap[id] else { return nil }
                    return try? await window.getAxRect(.cancellable)
                }
            }
            var frames: [UInt32: Rect] = [:]
            for (item, read) in zip(items, reads) {
                if let frame = await read.value { frames[item.windowId] = frame }
            }
            // A pass that came meanwhile may have sent a window somewhere else, or it is gone.
            let current = items.filter { item in
                pendingTargets[item.windowId].map { $0.isClose(to: item.target) } ?? false && MacWindow.allWindowsMap[item.windowId] != nil
            }
            for item in current { pendingTargets.removeValue(forKey: item.windowId) }

            // A small new window: a popup or a panel. The pass moves at once, it and the room
            // the others make for it.
            let popup = current.first { item in
                guard item.isNew, let from = frames[item.windowId], let window = MacWindow.allWindowsMap[item.windowId] else { return false }
                let visible = (window.nodeMonitor ?? mainMonitor).visibleRect
                return from.width * from.height < visible.width * visible.height * smallWindowShare
            }
            if let popup {
                let now = CACurrentMediaTime()
                for item in current where item.isNew { smallArrivals[item.windowId] = now }
                if logging {
                    let from = frames[popup.windowId]
                    log("pass: \(current.count) set at once, a small new window (\(Int(from?.width ?? 0))x\(Int(from?.height ?? 0)))")
                }
                for item in current { set(item) }
                return
            }

            let now = CACurrentMediaTime()
            var moving = 0
            for item in current {
                let id = item.windowId
                guard let window = MacWindow.allWindowsMap[id] else { continue }
                let monitor = (window.nodeMonitor ?? mainMonitor).rect
                guard let from = frames[id], !from.isClose(to: item.target), from.showsOn(monitor) else {
                    // Already there, or not on this screen now: parked in a corner, on another
                    // monitor, or unknown.
                    set(item)
                    continue
                }
                motions[id] = Motion(window: window, from: from, to: item.target, start: now, duration: duration)
                lastTargets[id] = item.target
                moving += 1
            }
            if logging { log("pass: \(moving) of \(current.count) on their way, \(Int(duration * 1000)) ms") }
            if moving > 0, timer == nil {
                let timer = Timer(timeInterval: frameInterval, repeats: true) { _ in
                    MainActor.assumeIsolated { tick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                tick()
            }
        }

        private static func tick() {
            let now = CACurrentMediaTime()
            // One job per app and step: an app's windows share one thread, and each on its own
            // would leave the others' steps waiting until they are dropped.
            var steps: [pid_t: (app: MacApp, steps: [MotionStep])] = [:]
            for (id, var motion) in motions {
                let t = min(1, (now - motion.start) / motion.duration)
                if t >= 1 {
                    motions.removeValue(forKey: id)
                    motion.window.macApp.setAxFrame(id, motion.to.topLeftCorner, motion.to.size)
                    if logging { log("window \(id): arrived after \(motion.steps) steps") }
                    continue
                }
                let frame = motion.from.moved(towards: motion.to, by: ease(t))
                motion.steps += 1
                motions[id] = motion
                let app = motion.window.macApp
                steps[app.pid, default: (app, [])].steps
                    .append(MotionStep(windowId: id, topLeft: frame.topLeftCorner, size: frame.size, number: motion.steps))
            }
            for (_, group) in steps {
                group.app.setAxFramesStep(group.steps, log: logging)
            }
            if motions.isEmpty {
                timer?.invalidate()
                timer = nil
            }
        }

        /// A direct frame set (parking the window, a mouse move): whatever motion it had ends.
        static func cancel(_ windowId: UInt32) {
            motions.removeValue(forKey: windowId)
            pendingTargets.removeValue(forKey: windowId)
        }

        /// The window is gone.
        static func forget(_ windowId: UInt32) {
            cancel(windowId)
            lastTargets.removeValue(forKey: windowId)
        }

        /// The engine is stopping: the windows are put back at once.
        static func cancelAll() {
            motions = [:]
            pendingTargets = [:]
            timer?.invalidate()
            timer = nil
        }

        private static func set(_ item: Held) {
            let id = item.windowId
            motions.removeValue(forKey: id)
            pendingTargets.removeValue(forKey: id)
            lastTargets[id] = item.target
            MacWindow.allWindowsMap[id]?.macApp.setAxFrame(id, item.target.topLeftCorner, item.target.size)
        }

        /// Gentle at both ends, with the motion spread over the whole time.
        private static func ease(_ t: Double) -> Double {
            t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data("motion: \(message)\n".utf8))
        }
    }

    /// Where a window goes when it leaves the tiles to float: the middle of its screen, with
    /// room above and below so a window floated from a full-height tile touches neither the
    /// menu bar nor the Dock. AeroSpace itself leaves a floating window where it was.
    enum FloatingPlacement {
        /// The room kept free above and below, as a share of the visible height.
        static let verticalPadding: CGFloat = 0.06

        /// `size`, shortened when it would reach into the padding.
        static func size(_ size: CGSize, in visible: Rect) -> CGSize {
            let padding = (visible.height * verticalPadding).rounded()
            return CGSize(width: size.width, height: min(size.height, visible.height - 2 * padding))
        }

        /// The top-left corner that centers a window of `size`. A window too large for the
        /// area keeps to its top or left edge, so its title bar stays reachable.
        static func topLeft(of size: CGSize, in visible: Rect) -> CGPoint {
            CGPoint(
                x: visible.topLeftX + max(((visible.width - size.width) / 2).rounded(), 0),
                y: visible.topLeftY + max(((visible.height - size.height) / 2).rounded(), 0),
            )
        }
    }

    extension Rect {
        fileprivate func isClose(to other: Rect) -> Bool {
            abs(topLeftX - other.topLeftX) < 1 && abs(topLeftY - other.topLeftY) < 1
                && abs(width - other.width) < 1 && abs(height - other.height) < 1
        }

        /// Whether more than a sliver of the frame is on `monitor`. AeroSpace parks the windows
        /// of other workspaces with a point of each on screen.
        fileprivate func showsOn(_ monitor: Rect) -> Bool {
            let visibleWidth = min(maxX, monitor.maxX) - max(minX, monitor.minX)
            let visibleHeight = min(maxY, monitor.maxY) - max(minY, monitor.minY)
            return visibleWidth >= 8 && visibleHeight >= 8
        }

        /// The frame `part` of the way from this one to `other`, on whole points.
        fileprivate func moved(towards other: Rect, by part: Double) -> Rect {
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * part).rounded() }
            return Rect(
                topLeftX: mix(topLeftX, other.topLeftX), topLeftY: mix(topLeftY, other.topLeftY),
                width: mix(width, other.width), height: mix(height, other.height),
            )
        }
    }
#endif
