import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var svc: ProxyService
    @State private var refreshTimer: Timer?
    @State private var showLog = false
    @State private var showDomainEditor = false
    @State private var showDeveloperBalance = false
    @State private var showDeveloperAdvanced = false
    @State private var showDeveloperKeySetup = false
    @State private var balanceDropPulse = false
    @State private var lastAnimatedBalance: Double?
    @FocusState private var domainFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 10) {
                        developerBalanceCard
                        statusCard
                        networkCard
                        domainCard
                        logCard
                    }
                    .padding(14)
                    .padding(.top, 6)
                }
                .scrollContentBackground(.hidden)
                .background(bgGray)

                VStack(spacing: 0) {
                    Rectangle().fill(.primary.opacity(0.06)).frame(height: 1)
                    heroAction
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .background(bgGray)
            }

        }
        .frame(minWidth: 280, idealWidth: 300, minHeight: 380, idealHeight: 460)
        .background(bgGray)
        .sheet(isPresented: $showDeveloperKeySetup) {
            DeveloperKeySheet(
                initialKey: svc.developerCredential
            ) { key in
                svc.saveDeveloperCredential(key)
                showDeveloperKeySetup = false
                Task { await svc.refreshDeveloperBalance() }
            } onCancel: {
                showDeveloperKeySetup = false
            }
        }
        .onAppear {
            Task { await svc.checkNetworksOnLaunch() }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in await svc.refreshStatus() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate(); refreshTimer = nil
        }
        .onChange(of: svc.developerAutoRefreshEnabled) { _, enabled in
            if enabled && !svc.developerCredential.isEmpty {
                Task { await svc.refreshDeveloperBalance() }
            }
        }
        .onChange(of: svc.developerBalanceAmount) { oldValue, newValue in
            if let old = oldValue ?? lastAnimatedBalance, let new = newValue, new < old {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) {
                    balanceDropPulse = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        balanceDropPulse = false
                    }
                }
            }
            if let newValue {
                lastAnimatedBalance = newValue
            }
        }
    }

    private func toggleDeveloperBalanceCard() {
        withAnimation(.easeInOut(duration: 0.15)) {
            if showDeveloperBalance {
                showDeveloperBalance = false
                showDeveloperAdvanced = false
            } else {
                showDeveloperBalance = true
                showDeveloperAdvanced = false
            }
        }
    }

    private func beginDeveloperAuthorization() {
        showDeveloperKeySetup = true
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("MergeSASE")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 3) {
                Circle().fill(phaseColor).frame(width: 4, height: 4)
                Text(svc.statusMessage).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - Hero Action

    private var heroAction: some View {
        Group {
            switch svc.phase {
            case .starting:
                actionBtn("启动中…", icon: nil, tint: .blue, loading: true) {}
            case .stopping:
                actionBtn("停止中…", icon: nil, tint: Color(.systemRed), loading: true) {}
            case .error:
                VStack(spacing: 6) {
                    actionBtn("重试", icon: "arrow.clockwise", tint: .orange) { Task { await svc.retry() } }
                    secondaryBtn("强制停止", icon: "stop.fill") { Task { await svc.stop() } }
                }
            case .idle, .running:
                if guardEffectivelyRunning {
                    actionBtn("停止守护", icon: "stop.fill", tint: Color(.systemGray)) { Task { await svc.stop() } }
                } else {
                    actionBtn("一键启动", icon: "play.fill", tint: .blue) { Task { await svc.start() } }
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
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent).controlSize(.extraLarge).tint(tint)
        .disabled(loading)
    }

    private func secondaryBtn(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 12, weight: .medium))
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
            StatRow(icon: "terminal", label: "应用环境", detail: svc.appEnvFixed ? "已修复" : "待修复", active: svc.appEnvFixed)
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
                Text("网络连通性").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                Spacer()
                Button(svc.networkCheckInProgress ? "检测中…" : "检测全部") { Task { await svc.checkAllNetworks() } }
                    .font(.system(size: 11)).buttonStyle(.borderless)
                    .disabled(svc.networkCheckInProgress || svc.phase == .starting || svc.phase == .stopping)
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

    // MARK: - Developer Balance Card

    private var developerBalanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                toggleDeveloperBalanceCard()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("开发者余额")
                            .font(.system(size: 17, weight: .semibold))
                        Text(developerBalanceStatusLine)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.55))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 5) {
                            if svc.developerBalanceStatus == .loading {
                                ProgressView()
                                    .controlSize(.regular)
                                    .tint(developerBalanceColor)
                                    .frame(width: 44, height: 36, alignment: .trailing)
                            } else {
                                Text(svc.developerBalanceSummary)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(developerBalanceColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .monospacedDigit()
                                    .fixedSize(horizontal: true, vertical: false)
                                    .scaleEffect(balanceDropPulse ? 1.07 : 1.0)
                                    .shadow(color: balanceDropPulse ? developerBalanceColor.opacity(0.35) : .clear, radius: balanceDropPulse ? 8 : 0)
                            }

                            if svc.developerBalanceStatus != .loading, !svc.developerBalanceDeltaText.isEmpty {
                                Text(svc.developerBalanceDeltaText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(developerBalanceDeltaColor)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(developerBalanceDeltaColor.opacity(0.1), in: Capsule())
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }

                        Image(systemName: "chevron.\(showDeveloperBalance ? "down" : "right")")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.35))
                            .frame(width: 12, height: 52, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 58)
            }
            .buttonStyle(.plain)

            if showDeveloperBalance, !developerMetricFields.isEmpty {
                VStack(spacing: 4) {
                    ForEach(developerMetricFields, id: \.key) { field in
                        DeveloperMetricTile(field: field)
                    }
                }
                .padding(.top, 1)
            }

            if shouldShowDeveloperAuthorizationPrompt {
                HStack {
                    Spacer()
                    Button {
                        beginDeveloperAuthorization()
                    } label: {
                        Label(developerAuthorizationTitle, systemImage: "key.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(developerAuthorizationHelp)
                }
            }

            if showDeveloperBalance {
                Divider().opacity(0.35)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showDeveloperAdvanced.toggle() }
                } label: {
                    HStack {
                        Text("高级设置")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.65))
                        Spacer()
                        HStack(spacing: 12) {
                            if let checkedAt = svc.developerBalanceLastChecked {
                                Text("更新 \(timeF.string(from: checkedAt))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                            Image(systemName: "chevron.\(showDeveloperAdvanced ? "down" : "right")")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.3))
                                .frame(width: 12, height: 40, alignment: .trailing)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(minHeight: 28)

                if showDeveloperAdvanced {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text("余额接口")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.65))
                            Text(svc.developerAddressDisplay)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.55))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }

                        HStack(spacing: 6) {
                            Spacer()

                            Button {
                                beginDeveloperAuthorization()
                            } label: {
                                Text(developerAuthorizationTitle)
                                    .font(.system(size: 9, weight: .medium))
                                    .frame(minHeight: 24)
                            }
                            .help(developerAuthorizationHelp)
                            .controlSize(.regular)

                            Button {
                                Task { await svc.refreshDeveloperBalance() }
                            } label: {
                                Label("刷新", systemImage: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("刷新余额")
                            .disabled(svc.developerBalanceStatus == .loading || svc.developerCredential.isEmpty)

                            Button {
                                svc.clearDeveloperCredential()
                            } label: {
                                Label("删除", systemImage: "trash")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("清除 API Key")
                            .disabled(svc.developerCredential.isEmpty)

                            Toggle("自动刷新", isOn: $svc.developerAutoRefreshEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .disabled(svc.developerCredential.isEmpty)
                        }
                    }
                }
            }
        }
        .prominentCard()
    }

    // MARK: - Domain Card

    private var domainCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDomainEditor.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("公司域名").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                    HStack(spacing: 12) {
                        Text(svc.companyDomains.joined(separator: ", ")).font(.system(size: 11)).foregroundColor(.secondary.opacity(0.5)).lineLimit(1)
                        Image(systemName: "chevron.\(showDomainEditor ? "down" : "right")")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.3))
                            .frame(width: 12, height: 40, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)

            if showDomainEditor {
                VStack(spacing: 6) {
                    ForEach(svc.companyDomains, id: \.self) { domain in
                        HStack {
                            Text(domain).font(.system(size: 13))
                            Spacer()
                            if svc.companyDomains.count > 1 {
                                Button { withAnimation { svc.removeDomain(domain) } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.4))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        TextField("新增域名", text: $svc.newDomain)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .focused($domainFieldFocused)
                            .onSubmit { svc.addDomain(svc.newDomain); svc.newDomain = ""; domainFieldFocused = true }
                        Button {
                            svc.addDomain(svc.newDomain); svc.newDomain = ""
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundColor(.blue)
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
                    Text("日志").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                    if !showLog, let last = svc.logs.last {
                        Circle().fill(.secondary.opacity(0.2)).frame(width: 2, height: 2)
                        Text(last.text).font(.system(size: 11)).foregroundColor(.secondary.opacity(0.45)).lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Text("\(svc.logs.count)").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.25))
                        Image(systemName: "chevron.\(showLog ? "down" : "right")")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.3))
                            .frame(width: 12, height: 40, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 36)
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
                                .font(.system(size: 10, design: .monospaced))
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
                        Label("复制全部", systemImage: "doc.on.doc").font(.system(size: 10))
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
    private var guardEffectivelyRunning: Bool {
        svc.clashRunning
            && svc.systemProxyEnabled
            && svc.guardLoaded
            && svc.appEnvFixed
            && svc.chromePolicyInstalled
    }
    private var developerBalanceColor: Color {
        switch svc.developerBalanceStatus {
        case .ok: Color(red: 0.92, green: 0.64, blue: 0.08)
        case .loading: .blue
        case .unauthorized, .error: .red
        case .unconfigured: .secondary
        }
    }
    private var developerBalanceStatusLine: String {
        switch svc.developerBalanceStatus {
        case .ok:
            return "账户额度实时概览"
        case .loading:
            return "正在刷新余额数据"
        case .unauthorized:
            return "API Key 无效，需要重新配置"
        case .error:
            return "刷新失败，请稍后重试"
        case .unconfigured:
            return "配置 API Key 后自动读取余额"
        }
    }
    private var developerBalanceDeltaColor: Color {
        .secondary
    }
    private var developerBalanceDeltaDisplay: String {
        svc.developerBalanceDeltaText.isEmpty ? "相比上次 $0.00" : svc.developerBalanceDeltaText
    }
    private var developerMetricFields: [BalanceField] {
        svc.developerBalanceFields.filter { $0.key != "当前余额" }
    }
    private var developerMetricColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)]
    }
    private var developerAuthorizationTitle: String {
        if svc.developerCredential.isEmpty { return "配置 Key" }
        switch svc.developerBalanceStatus {
        case .unauthorized:
            return "更换 Key"
        case .error:
            return "更换 Key"
        default:
            return "已配置"
        }
    }
    private var shouldShowDeveloperAuthorizationPrompt: Bool {
        svc.developerCredential.isEmpty || svc.developerBalanceStatus == .unauthorized
    }
    private var developerAuthorizationIcon: String? {
        developerAuthorizationTitle == "已配置" ? nil : "key.fill"
    }
    private var developerAuthorizationHelp: String {
        switch developerAuthorizationTitle {
        case "已配置":
            return "API Key 已配置，点击可更换"
        case "更换 Key":
            return "刷新失败或 API Key 无效，请重新配置"
        default:
            return "输入 sk- 开头的 API Key"
        }
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
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(active ? .accentColor : .secondary.opacity(0.3))
                .frame(width: 14)
            Text(label).font(.system(size: 13))
            Spacer()
            HStack(spacing: 3) {
                Circle().fill(active ? .green : .secondary.opacity(0.15)).frame(width: 4, height: 4)
                Text(detail).font(.system(size: 12)).foregroundColor(active ? .secondary : .secondary.opacity(0.35))
            }
        }
        .padding(.vertical, 9)
    }
}

struct NetRow: View {
    let label: String; let detail: String; let ip: String; let latency: String
    let accessible: Bool?
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(accessible == true ? .green : accessible == false ? .red : .secondary.opacity(0.1)).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13))
                HStack(spacing: 3) {
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary.opacity(0.6))
                    if !ip.isEmpty { Text("→").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.25)); Text(ip).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary.opacity(0.6)) }
                    if !latency.isEmpty { Text("·").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.25)); Text(latency).font(.system(size: 10, design: .monospaced)).foregroundColor(msColor) }
                }
            }
            Spacer()
            if let ok = accessible {
                Text(ok ? "可访问" : "不可访问").font(.system(size: 11, weight: .medium)).foregroundColor(ok ? .green : .red)
            } else {
                Text("未检测").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.4))
            }
        }
        .padding(.vertical, 7)
    }
    private var msColor: Color {
        guard !latency.isEmpty else { return .secondary }
        let num = Double(latency.replacingOccurrences(of: "ms", with: "")) ?? 0
        return num < 100 ? .green : num < 500 ? .orange : .red
    }
}

struct DeveloperMetricTile: View {
    let field: BalanceField

    var body: some View {
        HStack(spacing: 8) {
            Text(field.key)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.65))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(field.value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
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

    func prominentCard() -> some View {
        self
            .padding(16)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .primary.opacity(0.05), radius: 4, y: 2)
    }
}

private let timeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
private let bgGray = Color(red: 0.95, green: 0.95, blue: 0.94)
private let cardBg = Color(nsColor: .windowBackgroundColor)

// MARK: - Developer Key

struct DeveloperKeySheet: View {
    @State private var draftKey: String
    @State private var showInvalidMessage = false
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initialKey: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self._draftKey = State(initialValue: initialKey)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配置 API Key")
                .font(.system(size: 15, weight: .semibold))

            SecureField("sk-...", text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { save() }

            if showInvalidMessage {
                Text("请输入 API Key，支持直接粘贴 sk-... 或 Authorization: Bearer sk-...")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存并刷新") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func save() {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showInvalidMessage = true
            return
        }
        showInvalidMessage = false
        onSave(trimmed)
    }
}
