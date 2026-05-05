import SwiftUI
import AppKit

struct ContentView: View {
    @State private var svc = ProxyService()
    @State private var refreshTimer: Timer?
    @State private var showLog = false
    @State private var showDomainEditor = false
    @FocusState private var domainFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 10) {
                    heroAction
                    statusCard
                    networkCard
                    domainCard
                    logCard
                }
                .padding(14)
            }
            .scrollContentBackground(.hidden)
            .background(bgGray)
        }
        .frame(minWidth: 280, idealWidth: 300, minHeight: 380, idealHeight: 460)
        .background(bgGray)
        .onAppear {
            Task { await svc.refreshStatus() }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in await svc.refreshStatus() }
            }
        }
        .onDisappear { refreshTimer?.invalidate(); refreshTimer = nil }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("MergeSASE")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            HStack(spacing: 3) {
                Circle().fill(phaseColor).frame(width: 4, height: 4)
                Text(svc.statusMessage).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - Hero Action

    private var heroAction: some View {
        Group {
            switch svc.phase {
            case .idle:
                actionBtn("一键启动", icon: "play.fill", tint: .blue) { Task { await svc.start() } }
            case .starting:
                actionBtn("启动中…", icon: nil, tint: .blue, loading: true) {}
            case .running:
                actionBtn("停止", icon: "stop.fill", tint: Color(.systemRed)) { Task { await svc.stop() } }
            case .stopping:
                actionBtn("停止中…", icon: nil, tint: Color(.systemRed), loading: true) {}
            case .error:
                VStack(spacing: 6) {
                    actionBtn("重试", icon: "arrow.clockwise", tint: .orange) { Task { await svc.retry() } }
                    secondaryBtn("强制停止", icon: "stop.fill") { Task { await svc.stop() } }
                }
            }
        }
    }

    private func actionBtn(_ label: String, icon: String?, tint: Color, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent).controlSize(.extraLarge).tint(tint)
        .disabled(loading)
    }

    private func secondaryBtn(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 11, weight: .medium))
        }.buttonStyle(.borderless)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: 0) {
            StatRow(icon: "network", label: "Clash 进程", detail: svc.clashRunning ? "运行中" : "未运行", active: svc.clashRunning)
            sep
            StatRow(icon: "arrow.left.arrow.right", label: "系统代理", detail: svc.systemProxyEnabled ? "\(svc.proxyHost):\(svc.clashPort)" : "未启用", active: svc.systemProxyEnabled)
            sep
            StatRow(icon: "shield.checkered", label: "守护进程", detail: svc.guardLoaded ? "已加载" : "未加载", active: svc.guardLoaded)
            sep
            StatRow(icon: "globe", label: "Chrome 策略", detail: svc.chromePolicyInstalled ? "已配置" : "未配置", active: svc.chromePolicyInstalled)
        }
        .card()
    }

    private var sep: some View {
        Rectangle().fill(.primary.opacity(0.06)).frame(height: 1).padding(.leading, 28)
    }

    // MARK: - Network Card

    private var networkCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("网络连通性").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                Spacer()
                Button("检测全部") { Task { await svc.checkInternalNetwork(); await svc.checkExternalNetwork() } }
                    .font(.system(size: 10)).buttonStyle(.borderless)
                    .disabled(svc.phase == .starting || svc.phase == .stopping)
            }
            .padding(.bottom, 4)

            NetRow(
                label: "公司内网",
                detail: svc.companyDomains.first ?? "company.internal",
                ip: svc.internalResult.ip,
                latency: svc.internalResult.latencyMs,
                accessible: svc.internalResult.ip.isEmpty && svc.internalResult.statusCode.isEmpty ? nil : svc.internalResult.accessible
            )

            NetRow(
                label: "外部网络",
                detail: "google.com",
                ip: svc.externalResult.statusCode,
                latency: svc.externalResult.latencyMs,
                accessible: svc.externalResult.statusCode.isEmpty ? nil : svc.externalResult.accessible
            )
        }
        .card()
    }

    // MARK: - Domain Card

    private var domainCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDomainEditor.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("公司域名").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                    Text(svc.companyDomains.joined(separator: ", ")).font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5)).lineLimit(1)
                    Image(systemName: "chevron.\(showDomainEditor ? "down" : "right")").font(.system(size: 7, weight: .medium)).foregroundColor(.secondary.opacity(0.3))
                }
            }
            .buttonStyle(.plain)

            if showDomainEditor {
                VStack(spacing: 6) {
                    ForEach(svc.companyDomains, id: \.self) { domain in
                        HStack {
                            Text(domain).font(.system(size: 12))
                            Spacer()
                            if svc.companyDomains.count > 1 {
                                Button { withAnimation { svc.removeDomain(domain) } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.4))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        TextField("新增域名", text: $svc.newDomain)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .focused($domainFieldFocused)
                            .onSubmit { svc.addDomain(svc.newDomain); svc.newDomain = ""; domainFieldFocused = true }
                        Button {
                            svc.addDomain(svc.newDomain); svc.newDomain = ""
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .disabled(svc.newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.top, 6)
            }
        }
        .card()
    }

    // MARK: - Log Card

    private var logCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showLog.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("日志").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                    if !showLog, let last = svc.logs.last {
                        Circle().fill(.secondary.opacity(0.2)).frame(width: 2, height: 2)
                        Text(last.text).font(.system(size: 10)).foregroundColor(.secondary.opacity(0.45)).lineLimit(1)
                    }
                    Spacer()
                    Text("\(svc.logs.count)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.25))
                    Image(systemName: "chevron.\(showLog ? "down" : "right")").font(.system(size: 7, weight: .medium)).foregroundColor(.secondary.opacity(0.3))
                }
            }
            .buttonStyle(.plain)

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(svc.logs) { line in
                                HStack(spacing: 5) {
                                    Text("[" + timeF.string(from: line.timestamp) + "]").foregroundColor(.secondary.opacity(0.3))
                                    Text(line.text).foregroundColor(logColor(line.level))
                                }
                                .font(.system(size: 9, design: .monospaced))
                                .id(line.id)
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                    .onChange(of: svc.logs.count) { _, _ in
                        if let last = svc.logs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                .padding(.top, 4)

                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            svc.logs.map { "[\(timeF.string(from: $0.timestamp))] \($0.text)" }.joined(separator: "\n"),
                            forType: .string
                        )
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 2)
            }
        }
        .card()
    }

    // MARK: - Footer

    // MARK: - Helpers

    private var phaseColor: Color {
        switch svc.phase { case .idle: .secondary; case .starting, .stopping: .orange; case .running: .green; case .error: .red }
    }
    private func logColor(_ level: LogLevel) -> Color {
        switch level { case .success: .green; case .warn: .orange; case .error: .red; case .info: .primary }
    }
}

// MARK: - Shared Components

struct StatRow: View {
    let icon: String; let label: String; let detail: String; let active: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(active ? .accentColor : .secondary.opacity(0.3))
                .frame(width: 14)
            Text(label).font(.system(size: 12))
            Spacer()
            HStack(spacing: 3) {
                Circle().fill(active ? .green : .secondary.opacity(0.15)).frame(width: 4, height: 4)
                Text(detail).font(.system(size: 11)).foregroundColor(active ? .secondary : .secondary.opacity(0.35))
            }
        }
        .padding(.vertical, 7)
    }
}

struct NetRow: View {
    let label: String; let detail: String; let ip: String; let latency: String
    let accessible: Bool?
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(accessible == true ? .green : accessible == false ? .red : .secondary.opacity(0.1)).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12))
                HStack(spacing: 3) {
                    Text(detail).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                    if !ip.isEmpty { Text("→").font(.system(size: 8)).foregroundColor(.secondary.opacity(0.25)); Text(ip).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary.opacity(0.6)) }
                    if !latency.isEmpty { Text("·").font(.system(size: 8)).foregroundColor(.secondary.opacity(0.25)); Text(latency).font(.system(size: 9, design: .monospaced)).foregroundColor(msColor) }
                }
            }
            Spacer()
            if let ok = accessible {
                Text(ok ? "可访问" : "不可访问").font(.system(size: 10, weight: .medium)).foregroundColor(ok ? .green : .red)
            } else {
                Text("未检测").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.4))
            }
        }
        .padding(.vertical, 4)
    }
    private var msColor: Color {
        guard !latency.isEmpty else { return .secondary }
        let num = Double(latency.replacingOccurrences(of: "ms", with: "")) ?? 0
        return num < 100 ? .green : num < 500 ? .orange : .red
    }
}

// MARK: - Card modifier

extension View {
    func card() -> some View {
        self
            .padding(12)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .primary.opacity(0.04), radius: 2, y: 1)
    }
}

private let timeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
private let bgGray = Color(nsColor: .controlBackgroundColor)
private let cardBg = Color(nsColor: .windowBackgroundColor)
