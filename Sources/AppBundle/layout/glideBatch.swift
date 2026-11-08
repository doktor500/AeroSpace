#if AEROSPACE_EMBEDDED
    import AppKit
    import Darwin

    /// The host app (Space Cube) glides the windows to where a layout pass puts them. A pass
    /// holds back its frames, tells the host which windows go where, waits a moment for it to
    /// picture the screen, and only then moves them. Passes that move nothing new (most of
    /// them: every refresh lays out again) tell nothing and wait for nothing.
    @MainActor
    enum GlideBatch {
        private static var collecting = false
        private static var held: [(window: MacWindow, topLeft: CGPoint?, size: CGSize?)] = []
        /// Where each window was last sent, to tell a new place from the same one again.
        private static var lastTargets: [UInt32: CGRect] = [:]

        static func begin() {
            collecting = true
            held = []
        }

        /// Keeps the frame for the end of the pass, if one is collecting.
        static func hold(_ window: MacWindow, _ topLeft: CGPoint?, _ size: CGSize?) -> Bool {
            guard collecting else { return false }
            held.append((window, topLeft, size))
            return true
        }

        /// Tells the host where the windows go, if anywhere new, then moves them.
        static func finish() {
            collecting = false
            let batch = held
            held = []
            var moves: [(id: UInt32, rect: CGRect, isNew: Bool)] = []
            for item in batch {
                guard let topLeft = item.topLeft, let size = item.size else { continue }
                let rect = CGRect(origin: topLeft, size: size)
                let id = item.window.windowId
                if lastTargets[id] != rect { moves.append((id, rect, lastTargets[id] == nil)) }
                lastTargets[id] = rect
            }
            if !moves.isEmpty {
                let started = Date()
                let answered = GlideLink.shared.announce(moves)
                // DEBUG
                let line = String(format: "glide: %d held, %d move (%@), answered %@ after %.0f ms\n",
                                  batch.count, moves.count, moves.map { String($0.id) }.joined(separator: ","),
                                  answered ? "yes" : "no", Date().timeIntervalSince(started) * 1000)
                FileHandle.standardError.write(Data(line.utf8))
            }
            for item in batch {
                item.window.macApp.setAxFrame(item.window.windowId, item.topLeft, item.size)
            }
        }
    }

    /// The line to the host: a Unix socket it listens on (`SPACE_CUBE_GLIDE_SOCKET`). The engine
    /// writes `move <n> <id>,<x>,<y>,<w>,<h> …` and waits, 250 ms at most, for `ok <n>`. A window
    /// laid out for the first time (just opened) has its id written `n<id>`.
    @MainActor
    final class GlideLink {
        static let shared = GlideLink()
        private let path = ProcessInfo.processInfo.environment["SPACE_CUBE_GLIDE_SOCKET"]
        private var fd: Int32 = -1
        private var sequence = 0
        private var nextConnect = Date.distantPast
        private var pending = Data()

        @discardableResult
        func announce(_ moves: [(id: UInt32, rect: CGRect, isNew: Bool)]) -> Bool {
            guard let path, connected(to: path) else { return false }
            sequence += 1
            let body = moves.map { move in
                String(format: "%@%u,%.1f,%.1f,%.1f,%.1f", move.isNew ? "n" : "", move.id, move.rect.minX, move.rect.minY, move.rect.width, move.rect.height)
            }.joined(separator: " ")
            let line = Array("move \(sequence) \(body)\n".utf8)
            let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard sent == line.count else {
                disconnect()
                return false
            }
            let deadline = Date().addingTimeInterval(0.25)
            let wanted = "ok \(sequence)"
            while true {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return false }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, Int32(max(1, left * 1000))) > 0 else { return false }
                var chunk = [UInt8](repeating: 0, count: 256)
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else {
                    disconnect()
                    return false
                }
                pending.append(contentsOf: chunk[0 ..< count])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let reply = String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex ... newline)
                    if reply == wanted { return true }
                }
            }
        }

        private func connected(to path: String) -> Bool {
            if fd >= 0 { return true }
            guard Date() >= nextConnect else { return false }
            nextConnect = Date().addingTimeInterval(2)
            let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socket >= 0 else { return false }
            var noSigPipe: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                close(socket)
                return false
            }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                close(socket)
                return false
            }
            fd = socket
            pending = Data()
            return true
        }

        private func disconnect() {
            if fd >= 0 { close(fd) }
            fd = -1
        }
    }
#endif
