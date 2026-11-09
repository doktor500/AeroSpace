#if AEROSPACE_EMBEDDED
    @testable import AppBundle
    import XCTest

    @MainActor
    final class SavedWorldTest: XCTestCase {
        override func setUp() async throws { setUpWorkspacesForTests() }

        /// Workspace `a`: window 1 and a container of 2 and 3. Workspace `b`: window 4 floating.
        private func savedWorld() -> SavedWorld {
            let a = Workspace.get(byName: "a")
            a.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
            let b = Workspace.get(byName: "b")
            TestWindow.new(id: 4, parent: b.floatingWindowsContainer)
            return SavedWorld(
                bootTime: 1,
                focusedWorkspace: "b",
                world: FrozenWorld(
                    workspaces: [FrozenWorkspace(a), FrozenWorkspace(b)],
                    monitors: [],
                    windowIds: [1, 2, 3, 4],
                ),
                owners: [1: 10, 2: 20, 3: 20, 4: 40],
                cornerParkings: [4: SavedCornerParking(position: CGPoint(x: 0.25, y: 0.5), floatingSize: CGSize(width: 300, height: 200))],
            )
        }

        func testRoundTripsThroughJson() throws {
            let saved = savedWorld()
            let data = try JSONEncoder().encode(saved)
            XCTAssertEqual(try JSONDecoder().decode(SavedWorld.self, from: data), saved)
        }

        func testDropsWindowsOfAppsThatAreGone() throws {
            let kept = try XCTUnwrap(savedWorld().keeping { _, pid in pid != 20 })

            XCTAssertEqual(kept.world.windowIds, [1, 4])
            XCTAssertEqual(kept.owners, [1: 10, 4: 40])
            // The container left empty goes with its windows, so window 1 is the whole tree.
            XCTAssertEqual(kept.world.workspaces[0].rootTilingNode.children.map(\.windowIds), [[1]])
            XCTAssertEqual(kept.world.workspaces[1].floatingWindows.map(\.id), [4])
            XCTAssertEqual(kept.cornerParkings.keys.sorted(), [4])
        }

        func testNothingLeftWhenEveryAppIsGone() {
            XCTAssertNil(savedWorld().keeping { _, _ in false })
        }
    }

    extension FrozenTreeNode {
        fileprivate var windowIds: [UInt32] {
            switch self {
                case .window(let w): [w.id]
                case .container(let c): c.children.flatMap(\.windowIds)
            }
        }
    }
#endif
