import SwiftUI
import AppKit

@main
struct MergeSASEApp: App {
    @StateObject private var svc = ProxyService()

    var body: some Scene {
        WindowGroup("蝉舒宝", id: "main") {
            ContentView(svc: svc)
                .navigationTitle("蝉舒宝")
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarBalanceMenu(svc: svc)
        } label: {
            Text(svc.menuBarTitle)
        }
    }
}

struct MenuBarBalanceMenu: View {
    @ObservedObject var svc: ProxyService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            Task { await toggleGuard() }
        } label: {
            Label(menuBarGuardButtonTitle, systemImage: menuBarGuardButtonImage)
        }
        .disabled(menuBarGuardButtonDisabled)

        Divider()

        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Text("打开蝉舒宝")
        }

        Button("退出") {
            NSApp.terminate(nil)
        }
    }

    private var menuBarGuardButtonTitle: String {
        switch svc.phase {
        case .starting:
            return "启动中…"
        case .stopping:
            return "停止中…"
        case .error:
            return "重试配置 Codex 网络"
        case .idle, .running:
            return svc.guardEffectivelyRunning ? "停止守护" : "开启守护"
        }
    }

    private var menuBarGuardButtonImage: String {
        switch svc.phase {
        case .starting, .stopping:
            return "hourglass"
        case .error:
            return "arrow.clockwise"
        case .idle, .running:
            return svc.guardEffectivelyRunning ? "stop.fill" : "play.fill"
        }
    }

    private var menuBarGuardButtonDisabled: Bool {
        svc.phase == .starting || svc.phase == .stopping
    }

    @MainActor
    private func toggleGuard() async {
        if svc.phase == .error {
            await svc.retry()
        } else if svc.guardEffectivelyRunning {
            await svc.stop()
        } else {
            await svc.start()
        }
    }
}
