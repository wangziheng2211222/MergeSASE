import SwiftUI
import AppKit

@main
struct MergeSASEApp: App {
    @State private var svc = ProxyService()

    var body: some Scene {
        WindowGroup("MergeSASE", id: "main") {
            ContentView(svc: svc)
                .navigationTitle("MergeSASE")
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarBalanceMenu(svc: svc)
        } label: {
            Text(svc.menuBarBalanceTitle)
        }
    }
}

struct MenuBarBalanceMenu: View {
    @Bindable var svc: ProxyService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Text("打开主界面")
        }

        Button("退出") {
            NSApp.terminate(nil)
        }
    }
}
