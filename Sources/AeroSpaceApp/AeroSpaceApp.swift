import AppBundle
import SwiftUI

// This file is shared between SPM and xcode project

@main
struct AeroSpaceApp: App {
    @StateObject var viewModel = TrayMenuModel.shared
    @StateObject var messageModel = MessageModel.shared
    @Environment(\.openWindow) var openWindow: OpenWindowAction

    init() {
        initAppBundle()
    }

    var body: some Scene {
        #if AEROSPACE_EMBEDDED
            // The host app's own menu bar item stands in for this one. A scene still has to come
            // before the message window: SwiftUI opens the first window scene at launch, so
            // without one an empty message window would greet every start.
            MenuBarExtra("AeroSpace", systemImage: "macwindow", isInserted: .constant(false)) { EmptyView() }
        #else
            menuBar(viewModel: viewModel)
        #endif
        getMessageWindow(messageModel: messageModel)
            .onChange(of: messageModel.message) { message in
                if message != nil {
                    openWindow(id: messageWindowId)
                }
            }
    }
}
