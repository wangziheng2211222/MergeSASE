import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var svc: ProxyService
    @State private var refreshTimer: Timer?
    @State private var showLog = false
    @State private var showDomainEditor = false
    @State private var showKeyConfig = false
    @State private var showDeveloperPortal = false
    @State private var showSplash = true
    @State private var setupChecklistHiddenForSession = false
    @FocusState private var domainFieldFocused: Bool
    @FocusState private var focusedAPIKeyIndex: Int?

    var body: some View {
        ZStack {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(spacing: 10) {
                                if shouldShowSetupChecklist {
                                    codexSetupCard(scrollProxy: scrollProxy)
                                }
                                keyConfigCard
                                    .id("keyConfigCard")
                                statusCard
                                networkCard
                                domainCard
                                    .id("companyDomainCard")
                                logCard
                            }
                            .padding(14)
                            .padding(.top, 6)
                        }
                        .scrollContentBackground(.hidden)
                        .background(appBg)
                    }

                    VStack(spacing: 0) {
                        Rectangle().fill(separatorColor).frame(height: 1)
                        heroAction
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 7)
                        footerContact
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                    }
                    .background(appBg)
                }

                if let suggestion = svc.browserSuggestion {
                    HStack {
                        Spacer(minLength: 0)
                        browserSuggestionBubble(suggestion)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.horizontal, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .opacity(showSplash ? 0 : 1)

            if showSplash {
                splashView
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .frame(minWidth: 260, idealWidth: 276, minHeight: 380, idealHeight: 460)
        .background(appBg)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: svc.browserSuggestion)
        .onAppear {
            Task { await svc.checkNetworksOnLaunch() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    showSplash = false
                }
                startRefreshTimer()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate(); refreshTimer = nil
        }
        .onChange(of: svc.externalProxyPreference) { _ in
            Task { await svc.refreshStatus() }
        }
        .onChange(of: svc.hasConfiguredCompanyDomain) { configured in
            if configured {
                setupChecklistHiddenForSession = false
            }
        }
        .onChange(of: svc.hasConfiguredAPIKey) { configured in
            if configured {
                setupChecklistHiddenForSession = false
            }
        }
        .sheet(isPresented: $showDeveloperPortal) {
            DeveloperPortalWebView(svc: svc)
        }
    }

    private var shouldShowSetupChecklist: Bool {
        svc.shouldShowSetupChecklist && !setupChecklistHiddenForSession
    }

    private var visibleLogs: [LogLine] {
        Array(svc.logs.suffix(120))
    }

    private func toggleKeyConfigCard() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showKeyConfig.toggle()
        }
    }

    private func beginCompanyDomainSetup(scrollProxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.15)) {
            showDomainEditor = true
            scrollProxy.scrollTo("companyDomainCard", anchor: .top)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            domainFieldFocused = true
        }
    }

    private func beginAPIKeySetup(scrollProxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.15)) {
            showKeyConfig = true
            scrollProxy.scrollTo("keyConfigCard", anchor: .top)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusedAPIKeyIndex = 0
        }
    }

    private func openDeveloperPortalSheet() {
        svc.ccSwitchImportStatus = .waitingForLogin
        svc.browserImportMessage = "请在登录窗口完成授权"
        showDeveloperPortal = true
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
            Task { @MainActor in
                await svc.refreshStatus()
                await svc.detectRequiredTools()
            }
        }
        refreshTimer?.tolerance = 2
    }

    // MARK: - Header

    private var splashView: some View {
        VStack(spacing: 88) {
            Spacer(minLength: 42)

            Image(nsImage: NSImage(named: "Title.svg") ?? NSImage(named: "Title.png") ?? NSImage())
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 176, height: 252)
                .frame(maxWidth: .infinity, alignment: .center)

            Image(nsImage: NSImage(named: "AppIcon.png") ?? NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 5)

            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appBg)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("蝉舒宝")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 3) {
                Circle().fill(phaseColor).frame(width: 4, height: 4)
                Text(svc.statusMessage).font(.system(size: 12)).foregroundColor(.secondary)
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
                actionBtn("正在配置 Codex 网络…", icon: nil, tint: .blue, loading: true) {}
            case .stopping:
                actionBtn("停止中…", icon: nil, tint: Color(.systemRed), loading: true) {}
            case .error:
                VStack(spacing: 6) {
                    actionBtn("中止并还原", icon: "stop.fill", tint: Color(.systemGray)) { Task { await svc.stop() } }
                    secondaryBtn("重试", icon: "arrow.clockwise") { Task { await svc.retry() } }
                }
            case .idle, .running:
                if svc.guardEffectivelyRunning {
                    actionBtn("停止守护", icon: "stop.fill", tint: Color(.systemGray)) { Task { await svc.stop() } }
                } else {
                    actionBtn(
                        svc.hasConfiguredCompanyDomain ? "开启守护" : "先添加公司域名",
                        icon: svc.hasConfiguredCompanyDomain ? "play.fill" : "exclamationmark.circle.fill",
                        tint: .blue,
                        disabled: !svc.hasConfiguredCompanyDomain
                    ) { Task { await svc.start() } }
                }
            }
        }
    }

    private func actionBtn(_ label: String, icon: String?, tint: Color, loading: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(label).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).tint(tint)
        .disabled(loading || disabled)
        .help(disabled ? "请先在公司域名区域添加公司域名" : "")
    }

    private func secondaryBtn(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon).font(.system(size: 12, weight: .medium))
        }.buttonStyle(.borderless)
    }

    private var footerContact: some View {
        Text("有问题联系 钉钉 @子恒 微信：steve_sunrui")
            .font(.system(size: 10))
            .foregroundColor(.secondary.opacity(0.45))
            .textSelection(.enabled)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
    }

    private func browserSuggestionBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.blue)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .frame(maxWidth: 236, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .primary.opacity(0.12), radius: 10, y: 4)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: 0) {
            StatRow(icon: "lock.shield", label: "公司 VPN", detail: svc.vpnClientRunning ? "\(svc.vpnClientName) · \(svc.vpnClientDetail)" : svc.vpnClientDetail, active: svc.vpnClientRunning)
            sep
            ExternalProxyRow(
                detail: svc.externalProxyRunning ? "\(svc.externalProxyName) · \(svc.externalProxyDetail)" : "\(svc.externalProxyPreference.label) · 未运行",
                active: svc.externalProxyRunning,
                selection: $svc.externalProxyPreference
            )
            sep
            StatRow(icon: "arrow.left.arrow.right", label: "系统代理", detail: svc.systemProxyEnabled ? "\(svc.proxyHost):\(svc.clashPort)" : "未启用", active: svc.systemProxyEnabled)
            sep
            StatRow(icon: "shield.checkered", label: "网络守护", detail: svc.guardLoaded ? "已加载" : "未加载", active: svc.guardLoaded)
            sep
            StatRow(icon: "terminal", label: "应用环境", detail: svc.appEnvFixed ? "已修复" : "待修复", active: svc.appEnvFixed)
            sep
            StatRow(icon: "globe", label: "Chrome 策略", detail: svc.chromePolicyInstalled ? "已配置" : "未配置", active: svc.chromePolicyInstalled)
        }
        .card()
    }

    private var sep: some View {
        Rectangle().fill(separatorColor).frame(height: 1).padding(.leading, 28)
    }

    // MARK: - Network Card

    private var networkCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("网络连通性").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                Spacer()
                Button(svc.networkCheckInProgress ? "检测中…" : "检测全部") { Task { await svc.checkAllNetworks() } }
                    .font(.system(size: 12)).buttonStyle(.borderless)
                    .disabled(svc.networkCheckInProgress || svc.phase == .starting || svc.phase == .stopping)
            }
            .padding(.bottom, 4)

            NetRow(
                label: "公司内网",
                detail: svc.companyDomains.first ?? "未配置",
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

    // MARK: - Codex Setup Checklist

    private func codexSetupCard(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("完成以下软件安装与配置后即可使用 Codex")
                        .font(.system(size: 20, weight: .semibold))
                    Text("安装 CC Switch，导入模型服务到 CC Switch 中，最后安装 Codex 桌面版。")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.78))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if svc.canPermanentlyDismissSetupChecklist {
                            svc.dismissSetupChecklist()
                        } else {
                            setupChecklistHiddenForSession = true
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.45))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(svc.canPermanentlyDismissSetupChecklist ? "收起配置清单" : "本次先收起")
            }

            VStack(spacing: 6) {
                SetupChecklistRow(
                    title: "OpenVPN / SASE",
                    detail: svc.vpnSetupStatusText,
                    done: svc.vpnClientRunning,
                    buttonTitle: svc.openVPNConnectInstalled ? "打开" : "下载",
                    isPrimary: !svc.vpnClientRunning,
                    action: { svc.openOrDownloadOpenVPNConnect() }
                )
                SetupChecklistRow(
                    title: "CC Switch",
                    detail: svc.ccSwitchStatusText,
                    done: svc.ccSwitchStatus.isInstalled,
                    buttonTitle: "安装",
                    isPrimary: true,
                    action: { Task { await svc.installCCSwitchIfNeeded() } }
                )
                SetupChecklistRow(
                    title: "导入模型服务到 CC Switch 中",
                    detail: svc.ccSwitchProviderImported ? "已导入" : "登录后台后导入",
                    done: svc.ccSwitchProviderImported,
                    buttonTitle: "导入",
                    isPrimary: !svc.ccSwitchProviderImported,
                    action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showKeyConfig = true
                        }
                        openDeveloperPortalSheet()
                    }
                )
                SetupChecklistRow(
                    title: "Codex 桌面版",
                    detail: svc.codexStatusText,
                    done: svc.codexStatus.isInstalled,
                    buttonTitle: "下载安装",
                    isPrimary: !svc.codexStatus.isInstalled,
                    action: { Task { await svc.installCodexIfNeeded() } }
                )
            }

            if svc.coreCodexSetupComplete && !svc.guardEffectivelyRunning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.blue)
                        .padding(.top, 2)
                    Text("如果遇到开启外网或内网后无法使用 Codex，请点击下方“开启守护”。")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .setupCard()
    }

    // MARK: - Balance Query Card

    private var keyConfigCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                toggleKeyConfigCard()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("余额查询")
                            .font(.system(size: 19, weight: .semibold))
                        Text("展开后可从开发者后台导入 CC Switch provider")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.55))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .center, spacing: 0) {
                        VStack(alignment: .trailing, spacing: 5) {
                            if svc.developerBalanceStatus == .loading && !svc.developerBalanceSummary.hasPrefix("$") {
                                ProgressView()
                                    .controlSize(.regular)
                                    .tint(.blue)
                                    .frame(width: 44, height: 36, alignment: .trailing)
                            } else {
                                Text(svc.developerBalanceSummary)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundColor(developerBalanceColor)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .contentTransition(.numericText())
                                    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: svc.developerBalanceSummary)
                            }
                        }

                        Image(systemName: "chevron.\(showKeyConfig ? "down" : "right")")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.3))
                            .frame(width: 12, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 58)
            }
            .buttonStyle(.plain)

            if showKeyConfig {
                VStack(spacing: 8) {
                    APIKeyTextRow(
                        value: svc.apiKey,
                        onFocus: { focusedAPIKeyIndex = 0 },
                        onChange: { svc.updateAPIKey($0) }
                    )
                    HStack(spacing: 8) {
                        Text("API Key 仅用于本机余额查询；后台登录态不会被读取或保存。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button {
                            openDeveloperPortalSheet()
                        } label: {
                            Label("登录并导入", systemImage: "square.and.arrow.down")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 1)
            }
        }
        .prominentCard()
    }

    // MARK: - Domain Card

    private var domainCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("公司域名").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                Spacer()
                HStack(spacing: 12) {
                    Text(svc.companyDomains.isEmpty ? "未配置" : svc.companyDomains.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.\(showDomainEditor ? "down" : "right")")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.3))
                        .frame(width: 12, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .onTapGesture {
                let opening = !showDomainEditor
                withAnimation(.easeInOut(duration: 0.15)) { showDomainEditor.toggle() }
                if opening {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        domainFieldFocused = true
                    }
                }
            }

            if showDomainEditor {
                VStack(spacing: 8) {
                    ForEach(svc.companyDomains, id: \.self) { domain in
                        HStack {
                            Text(domain).font(.system(size: 14))
                            Spacer()
                            Button { withAnimation { svc.removeDomain(domain) } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary.opacity(0.4))
                                    .frame(width: 28, height: 28)
                            }.buttonStyle(.plain)
                        }
                        .frame(minHeight: 30)
                    }
                    HStack(spacing: 8) {
                        TextField("新增域名", text: $svc.newDomain)
                            .textFieldStyle(.plain).font(.system(size: 14))
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
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 42)
                    .background(fieldBg, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(separatorColor.opacity(0.35), lineWidth: 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                    .onTapGesture {
                        domainFieldFocused = true
                    }
                }
                .padding(.top, 4)
            }
        }
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            guard !showDomainEditor else { return }
            withAnimation(.easeInOut(duration: 0.15)) { showDomainEditor = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                domainFieldFocused = true
            }
        }
    }

    // MARK: - Log Card

    private var logCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("日志").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary.opacity(0.6))
                if !showLog, let last = svc.logs.last {
                    Circle().fill(.secondary.opacity(0.2)).frame(width: 2, height: 2)
                    Text(last.text).font(.system(size: 12)).foregroundColor(.secondary.opacity(0.45)).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 12) {
                    Text("\(svc.logs.count)").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.25))
                    Image(systemName: "chevron.\(showLog ? "down" : "right")")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.3))
                        .frame(width: 12, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { showLog.toggle() }
            }

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleLogs) { line in
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
                    .onChange(of: svc.logs.count) { _ in
                        if let last = visibleLogs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
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
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            guard !showLog else { return }
            withAnimation(.easeInOut(duration: 0.15)) { showLog = true }
        }
    }

    // MARK: - Footer

    // MARK: - Helpers

    private var phaseColor: Color {
        switch svc.phase { case .idle: .secondary; case .starting, .stopping: .orange; case .running: .green; case .error: .red }
    }
    private var developerBalanceColor: Color {
        switch svc.developerBalanceStatus {
        case .ok:
            Color(red: 0.92, green: 0.64, blue: 0.08)
        case .error, .unauthorized:
            .red
        case .loading:
            .blue
        case .unconfigured:
            .secondary
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(active ? .accentColor : .secondary.opacity(0.3))
                .frame(width: 14)
            Text(label).font(.system(size: 14))
            Spacer()
            HStack(spacing: 3) {
                Circle().fill(active ? .green : .secondary.opacity(0.15)).frame(width: 4, height: 4)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(active ? .secondary : .secondary.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 9)
    }
}

struct ExternalProxyRow: View {
    let detail: String
    let active: Bool
    @Binding var selection: ExternalProxyPreference

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(active ? .accentColor : .secondary.opacity(0.3))
                .frame(width: 14)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("外网代理").font(.system(size: 14))
                    Spacer(minLength: 8)

                    Picker("代理选择", selection: $selection) {
                        ForEach(ExternalProxyPreference.allCases) { preference in
                            Text(preference.label).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 168)
                }

                HStack(spacing: 3) {
                    Circle().fill(active ? .green : .secondary.opacity(0.15)).frame(width: 4, height: 4)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(active ? .secondary : .secondary.opacity(0.35))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

struct NetRow: View {
    let label: String; let detail: String; let ip: String; let latency: String
    let accessible: Bool?
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(accessible == true ? .green : accessible == false ? .red : .secondary.opacity(0.1)).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 14))
                HStack(spacing: 3) {
                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary.opacity(0.6))
                    if !ip.isEmpty { Text("→").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.25)); Text(ip).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary.opacity(0.6)) }
                    if !latency.isEmpty { Text("·").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.25)); Text(latency).font(.system(size: 11, design: .monospaced)).foregroundColor(msColor) }
                }
            }
            Spacer()
            if let ok = accessible {
                Text(ok ? "可访问" : "不可访问").font(.system(size: 12, weight: .medium)).foregroundColor(ok ? .green : .red)
            } else {
                Text("未检测").font(.system(size: 12)).foregroundColor(.secondary.opacity(0.4))
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

struct APIKeyTextRow: View {
    let value: String
    let onFocus: () -> Void
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            SecureField("API Key", text: Binding(
                get: { value },
                set: { onChange($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.primary.opacity(0.86))
            .onTapGesture(perform: onFocus)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(fieldBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(separatorColor.opacity(0.35), lineWidth: 0.5)
        )
    }
}

struct SetupChecklistRow: View {
    let title: String
    let detail: String
    let done: Bool
    let buttonTitle: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(done ? .green : .secondary.opacity(0.32))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if done {
                Text("完成")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.38))
                    .frame(width: 76, alignment: .trailing)
                    .frame(minHeight: 30)
            } else {
                Button {
                    action()
                } label: {
                    Text(buttonTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isPrimary ? .white : .blue)
                        .frame(width: 76)
                        .frame(minHeight: 30)
                        .background(isPrimary ? Color.blue : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .background(fieldBg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(separatorColor.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - Card modifier

extension View {
    func card() -> some View {
        self
            .padding(12)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(separatorColor.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }

    func prominentCard() -> some View {
        self
            .padding(16)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(separatorColor.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
    }

    func setupCard() -> some View {
        self
            .padding(16)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
    }
}

private let timeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
private let appBg = Color(red: 0.94, green: 0.94, blue: 0.95)
private let cardBg = Color(red: 0.985, green: 0.985, blue: 0.99)
private let fieldBg = Color(red: 0.955, green: 0.955, blue: 0.965)
private let separatorColor = Color(nsColor: .separatorColor).opacity(0.55)
