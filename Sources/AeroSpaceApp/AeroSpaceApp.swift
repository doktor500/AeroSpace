import AppBundle
import SwiftUI

// This file is shared between SPM and xcode project

#if AEROSPACE_EMBEDDED
    /// Keeps the engine running when its message window closes. Its menu bar item is not
    /// inserted, so the message window is its only window, and SwiftUI would otherwise quit the
    /// app as soon as that window goes (a config warning shown, then cleared by the next
    /// reload), leaving the host to restart it.
    final class EmbeddedAppDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }
    }
#endif

@main
struct AeroSpaceApp: App {
    #if AEROSPACE_EMBEDDED
        @NSApplicationDelegateAdaptor(EmbeddedAppDelegate.self) var appDelegate
    #endif
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
