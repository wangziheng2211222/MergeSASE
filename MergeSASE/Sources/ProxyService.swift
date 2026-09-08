import Foundation
import Combine
import AppKit
import Darwin

enum AppPhase: String { case idle, starting, running, stopping, error }

enum LogLevel { case info, success, warn, error }

enum ToolInstallStatus {
    case unknown
    case installing
    case installed
    case failed

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

enum CCSwitchImportStatus {
    case notStarted
    case waitingForLogin
    case extracting
    case imported
    case needsManualPaste
    case failed
}

enum CodexReadyStatus {
    case incomplete
    case ready
}

enum ExternalProxyPreference: String, CaseIterable, Identifiable {
    case auto
    case clash
    case shadowrocket

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .clash: return "Clash"
        case .shadowrocket: return "Shadowrocket"
        }
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let timestamp: Date
    let text: String
    let level: LogLevel
}

struct NetworkCheckResult {
    var accessible: Bool = false
    var url: String = ""
    var ip: String = ""
    var statusCode: String = ""
    var latencyMs: String = ""
}

struct VPNClientDetection {
    var displayName: String = "未检测"
    var detail: String = "请先连接 SASE 或 OpenVPN Connect"
    var running: Bool = false
}

struct ExternalProxyDetection {
    var displayName: String = "未检测"
    var detail: String = "请选择 Clash 或 Shadowrocket"
    var host: String = "127.0.0.1"
    var port: Int = 7897
    var running: Bool = false
    var supportsClashConfig: Bool = false
}

struct ProxyEndpointSnapshot: Codable {
    var enabled: Bool
    var server: String
    var port: String
}

struct NetworkServiceSnapshot: Codable {
    var service: String
    var web: ProxyEndpointSnapshot
    var secureWeb: ProxyEndpointSnapshot
    var socks: ProxyEndpointSnapshot
    var bypassDomains: [String]
}

struct FileSnapshot: Codable {
    var path: String
    var existed: Bool
    var backupName: String?
}

struct RestoreSnapshot: Codable {
    var formatVersion: Int?
    var createdAt: Date
    var networkServices: [NetworkServiceSnapshot]
    var files: [FileSnapshot]
    var launchdEnvironment: [String: String?]?
    var managedRuntime: ManagedRuntimeSnapshot?
}

struct ManagedRuntimeSnapshot: Codable {
    var networkServices: [String]
    var bypassDomains: [String]
    var proxyHost: String
    var proxyPort: Int
}

enum DeveloperBalanceStatus {
    case unconfigured
    case loading
    case ok
    case error
    case unauthorized
}

@MainActor
final class ProxyService: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var clashRunning = false
    @Published var clashPort: Int = 7897
    @Published var systemProxyEnabled = false
    @Published var systemProxyMatchesExternal = false
    @Published var systemProxyBypassValid = false
    @Published var proxyHost: String = "127.0.0.1"
    @Published var externalProxyPreference: ExternalProxyPreference {
        didSet { UserDefaults.standard.set(externalProxyPreference.rawValue, forKey: "externalProxyPreference") }
    }
    @Published var shadowrocketPortText: String = "" {
        didSet { UserDefaults.standard.set(shadowrocketPortText, forKey: "shadowrocketProxyPort") }
    }
    @Published var externalProxyName = "未检测"
    @Published var externalProxyDetail = "请选择 Clash 或 Shadowrocket"
    @Published var externalProxyRunning = false
    @Published var externalProxySupportsClashConfig = false
    @Published var vpnClientName = "未检测"
    @Published var vpnClientDetail = "请先连接 SASE 或 OpenVPN Connect"
    @Published var vpnClientRunning = false
    @Published var openVPNConnectInstalled = false
    @Published var openVPNConnectPath = ""
    @Published var guardLoaded = false
    @Published var chromePolicyInstalled = false
    @Published var appEnvFixed = false
    @Published var networkCheckInProgress = false
    @Published var internalResult = NetworkCheckResult()
    @Published var externalResult = NetworkCheckResult()
    @Published var logs: [LogLine] = []
    @Published var companyDomains: [String] {
        didSet { UserDefaults.standard.set(companyDomains, forKey: "companyDomains") }
    }
    @Published var setupChecklistDismissed: Bool {
        didSet { UserDefaults.standard.set(setupChecklistDismissed, forKey: "setupChecklistDismissed") }
    }
    @Published var statusMessage: String = "就绪"
    @Published var browserSuggestion: String?
    @Published var newDomain: String = ""
    @Published var apiKeys: [String] {
        didSet {
            persistAPIKey(apiKey)
            scheduleDeveloperBalanceRefresh()
        }
    }
    @Published var developerBalanceStatus: DeveloperBalanceStatus = .unconfigured
    @Published var developerBalanceSummary: String = "未配置"
    @Published var ccSwitchStatus: ToolInstallStatus = .unknown
    @Published var codexStatus: ToolInstallStatus = .unknown
    @Published var codexAppPath = ""
    @Published var ccSwitchImportStatus: CCSwitchImportStatus = .notStarted
    @Published var ccSwitchProviderImported = false
    @Published var toolSetupInProgress = false
    @Published var browserImportMessage = "等待导入"
    @Published var ccSwitchInstallFailed = false
    @Published var codexInstallFailed = false
    var menuBarTitle: String {
        if developerBalanceStatus == .loading, developerBalanceSummary == "查询中" {
            return "余额"
        }
        return developerBalanceSummary
    }
    var menuBarStatusText: String {
        guardEffectivelyRunning ? "Codex 网络已配置" : "Codex 网络未配置"
    }
    var menuBarSystemImage: String {
        guardEffectivelyRunning ? "shield.checkered" : "shield"
    }
    var guardEffectivelyRunning: Bool {
        vpnClientRunning
            && externalProxyRunning
            && systemProxyEnabled
            && systemProxyMatchesExternal
            && systemProxyBypassValid
            && guardLoaded
            && appEnvFixed
            && chromePolicyInstalled
    }
    var guardNeedsStopping: Bool {
        let paths = managedPaths()
        return guardLoaded
            || FileManager.default.fileExists(atPath: snapshotPath)
            || FileManager.default.fileExists(atPath: paths.plist)
            || FileManager.default.fileExists(atPath: paths.guardScript)
    }
    var codexReadyStatus: CodexReadyStatus {
        ccSwitchStatus.isInstalled
            && codexStatus.isInstalled
            && ccSwitchProviderImported
            && hasConfiguredAPIKey
            && guardEffectivelyRunning ? .ready : .incomplete
    }
    var coreCodexSetupComplete: Bool {
        ccSwitchStatus.isInstalled
            && codexStatus.isInstalled
            && ccSwitchProviderImported
    }
    var ccSwitchStatusText: String {
        if ccSwitchInstallFailed { return "安装失败" }
        if case .failed = ccSwitchStatus { return "待安装" }
        return toolStatusText(ccSwitchStatus, installed: "已安装", missing: "待安装")
    }
    var codexStatusText: String {
        if codexInstallFailed { return "安装失败" }
        if case .failed = codexStatus { return "需要手动安装" }
        return toolStatusText(codexStatus, installed: "已安装", missing: "待安装")
    }
    var vpnSetupStatusText: String {
        if vpnClientRunning {
            return "\(vpnClientName) 已连接"
        }
        if openVPNConnectInstalled {
            return "请打开并连接 OpenVPN/SASE"
        }
        return "请下载并连接 OpenVPN/SASE"
    }
    var openVPNConnectStatusText: String {
        if vpnClientRunning {
            return "\(vpnClientName) 已连接"
        }
        return openVPNConnectInstalled ? "已安装，未连接" : "未安装"
    }
    var hasConfiguredCompanyDomain: Bool {
        companyDomains.contains { domain in
            guard let normalized = NetworkCompatibility.normalizedDomain(domain) else { return false }
            return normalized != "company.internal"
        }
    }
    var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? "v\(version)" : "v\(version) (\(build))"
    }
    var hasConfiguredAPIKey: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    var isSetupChecklistComplete: Bool {
        codexReadyStatus == .ready
    }
    var shouldShowSetupChecklist: Bool {
        !isSetupChecklistComplete || !setupChecklistDismissed
    }
    var canPermanentlyDismissSetupChecklist: Bool {
        isSetupChecklistComplete
    }
    var apiKey: String { apiKeys.first ?? "" }
    var maskedAPIKey: String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed.isEmpty ? "" : "••••••••" }
        return "\(trimmed.prefix(4))••••••\(trimmed.suffix(4))"
    }
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    private var backupDir: String { "\(homeDir)/Library/Application Support/蝉舒宝/Backup" }
    private var snapshotPath: String { "\(backupDir)/snapshot.json" }
    private let guardLaunchdLabel = "com.clash.proxyguard"
    private var guardLaunchdService: String { "gui/\(getuid())/\(guardLaunchdLabel)" }
    private let managedProxyKeys = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"]
    private let managedAllProxyKeys = ["ALL_PROXY", "all_proxy"]
    private let managedNoProxyKeys = ["NO_PROXY", "no_proxy"]
    private var managedEnvKeys: [String] { managedProxyKeys + managedAllProxyKeys + managedNoProxyKeys }
    private let currentSnapshotFormatVersion = 2
    private static let defaultCompanyDomains = ["cds8.cn", "limayao.com"]
    private let proxyRequiredHosts: [String] = []
    private var directCompanyHosts: [String] {
        ["developer.company.internal", "api.company.internal", "ai-platform-cicada-llm-api.limayao.com"]
    }
    private var startupNetworkCheckCompleted = false
    private let developerBalanceAPIURL = URL(string: "https://ai-platform-cicada-llm-api.limayao.com/api/usage/token/balance")!
    private let developerBalanceAutoRefreshInterval: UInt64 = 60_000_000_000
    private var developerBalanceRefreshTask: Task<Void, Never>?
    private var developerBalanceAutoRefreshTask: Task<Void, Never>?
    private var startupFailureCleanupCompleted = false
    private var stopInProgress = false
    private var monitoredNetworkServices: [String] = []
    private var monitoredBypassDomains: [String] = []
    private var monitoredProxyEndpoint: LocalProxyEndpoint?
    private var refreshGeneration: UInt64 = 0

    init() {
        let savedProxyPreference = UserDefaults.standard.string(forKey: "externalProxyPreference") ?? ExternalProxyPreference.auto.rawValue
        self.externalProxyPreference = ExternalProxyPreference(rawValue: savedProxyPreference) ?? .auto

        let saved = UserDefaults.standard.stringArray(forKey: "companyDomains") ?? []
        let defaultsSeededKey = "defaultCompanyDomainsSeeded"
        if UserDefaults.standard.bool(forKey: defaultsSeededKey) {
            self.companyDomains = Self.deduplicatedDomains(saved)
        } else {
            let seededDomains = Self.deduplicatedDomains(Self.defaultCompanyDomains + saved)
            self.companyDomains = seededDomains
            UserDefaults.standard.set(seededDomains, forKey: "companyDomains")
            UserDefaults.standard.set(true, forKey: defaultsSeededKey)
        }
        if let savedAPIKey = UserDefaults.standard.string(forKey: "developerAPIKey"),
           !savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.apiKeys = [savedAPIKey]
        } else if let legacyAPIKey = UserDefaults.standard.stringArray(forKey: "apiKeys")?.first,
                  !legacyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.apiKeys = [legacyAPIKey]
            UserDefaults.standard.set(legacyAPIKey, forKey: "developerAPIKey")
            UserDefaults.standard.removeObject(forKey: "apiKeys")
        } else {
            self.apiKeys = []
        }
        self.setupChecklistDismissed = UserDefaults.standard.bool(forKey: "setupChecklistDismissed")
        self.shadowrocketPortText = UserDefaults.standard.string(forKey: "shadowrocketProxyPort") ?? ""
        scheduleDeveloperBalanceRefresh()
        Task {
            await detectRequiredTools()
            await refreshStatus()
        }
    }

    private func log(_ text: String, _ level: LogLevel = .info) {
        logs.append(LogLine(timestamp: Date(), text: text, level: level))
        if logs.count > 500 { logs.removeFirst(100) }
    }

    private func invalidateStatusRefreshes() {
        refreshGeneration &+= 1
    }

    private func toolStatusText(_ status: ToolInstallStatus, installed: String, missing: String) -> String {
        switch status {
        case .unknown:
            return "检测中"
        case .installing:
            return "安装中"
        case .installed:
            return installed
        case .failed:
            return "失败"
        }
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "developerAPIKey")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "developerAPIKey")
        }
        UserDefaults.standard.removeObject(forKey: "apiKeys")
    }

    private static func deduplicatedDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.compactMap { value in
            guard let domain = NetworkCompatibility.normalizedDomain(value), seen.insert(domain).inserted else {
                return nil
            }
            return domain
        }
    }

    private func suggestBrowserAction(_ text: String) {
        browserSuggestion = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if browserSuggestion == text {
                browserSuggestion = nil
            }
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func loginShellOutput(_ command: String) async -> String {
        let result = await CommandRunner.run("/bin/zsh", ["-lc", command])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commandPath(_ command: String) async -> String? {
        let commonPaths = [
            "/usr/bin/\(command)"
        ]
        for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let output = await loginShellOutput("command -v \(command) 2>/dev/null || true")
        return output.isEmpty ? nil : output
    }

    private func commandExists(_ command: String) async -> Bool {
        await commandPath(command) != nil
    }

    private func ccSwitchAppInstalled() async -> Bool {
        let appPaths = [
            "/Applications/CC Switch.app",
            "\(homeDir)/Applications/CC Switch.app"
        ]
        if appPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return true
        }
        let spotlight = await CommandRunner.run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == 'com.farion.ccswitch'"])
        return spotlight.succeeded && !spotlight.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func detectCodexDesktopAppPath() async -> String? {
        let appPaths = [
            "/Applications/Codex.app",
            "\(homeDir)/Applications/Codex.app",
            "/Applications/ChatGPT.app",
            "\(homeDir)/Applications/ChatGPT.app"
        ]
        if let path = appPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return path
        }

        let spotlightQueries = [
            "kMDItemCFBundleIdentifier == 'com.openai.codex'",
            "kMDItemCFBundleIdentifier == 'com.openai.chat'",
            "kMDItemDisplayName == 'Codex'",
            "kMDItemDisplayName == 'ChatGPT'"
        ]
        for query in spotlightQueries {
            let spotlight = await CommandRunner.run("/usr/bin/mdfind", [query])
            let path = spotlight.stdout.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.hasSuffix(".app") }
            if spotlight.succeeded, let path {
                return path
            }
        }
        return nil
    }

    private func detectCompanyCCSwitchProviderImported() async -> Bool {
        let dbPath = "\(homeDir)/.cc-switch/cc-switch.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return false }

        let domains = Self.deduplicatedDomains(Self.defaultCompanyDomains + companyDomains)
            .filter { !$0.isEmpty }
        guard !domains.isEmpty else { return false }

        let conditions = domains.map { domain in
            let escaped = domain.replacingOccurrences(of: "'", with: "''")
            return """
            coalesce(p.website_url, '') LIKE '%\(escaped)%'
            OR coalesce(e.url, '') LIKE '%\(escaped)%'
            OR coalesce(p.settings_config, '') LIKE '%\(escaped)%'
            OR coalesce(p.meta, '') LIKE '%\(escaped)%'
            """
        }.joined(separator: " OR ")

        let query = """
        SELECT 1
        FROM providers p
        LEFT JOIN provider_endpoints e
          ON p.id = e.provider_id AND p.app_type = e.app_type
        WHERE p.app_type = 'codex' AND (\(conditions))
        LIMIT 1;
        """
        let result = await CommandRunner.run("/usr/bin/sqlite3", [dbPath, query])
        return result.succeeded && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func detectOpenVPNConnectAppPath() async -> String? {
        let appPaths = [
            "/Applications/OpenVPN Connect.app",
            "\(homeDir)/Applications/OpenVPN Connect.app"
        ]
        if appPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            return appPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
        }
        let spotlight = await CommandRunner.run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == 'org.openvpn.client.app'"])
        let path = spotlight.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return spotlight.succeeded ? path : nil
    }

    func detectRequiredTools() async {
        async let codexDesktopPath = detectCodexDesktopAppPath()
        async let hasCodexCLI = commandExists("codex")
        async let hasCCSwitchApp = ccSwitchAppInstalled()
        async let hasCompanyProvider = detectCompanyCCSwitchProviderImported()
        async let openVPNPath = detectOpenVPNConnectAppPath()
        let (detectedCodexDesktopPath, codexCLIInstalled, ccSwitchInstalled, companyProviderImported, detectedOpenVPNPath) = await (codexDesktopPath, hasCodexCLI, hasCCSwitchApp, hasCompanyProvider, openVPNPath)
        let codexInstalled = detectedCodexDesktopPath != nil || codexCLIInstalled

        codexStatus = codexInstalled ? .installed : .failed
        codexAppPath = detectedCodexDesktopPath ?? ""
        ccSwitchStatus = ccSwitchInstalled ? .installed : .failed
        ccSwitchProviderImported = companyProviderImported
        openVPNConnectPath = detectedOpenVPNPath ?? ""
        openVPNConnectInstalled = detectedOpenVPNPath != nil
        if codexInstalled { codexInstallFailed = false }
        if ccSwitchInstalled { ccSwitchInstallFailed = false }
    }

    func openOrDownloadOpenVPNConnect() {
        if openVPNConnectInstalled {
            let path = openVPNConnectPath.isEmpty ? "/Applications/OpenVPN Connect.app" : openVPNConnectPath
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            log("已打开 OpenVPN Connect，请连接公司 VPN profile", .info)
            return
        }

        if let url = URL(string: "https://openvpn.net/client/") {
            NSWorkspace.shared.open(url)
            log("已打开 OpenVPN Connect 官方下载页面", .info)
        }
    }

    func installCCSwitchIfNeeded() async {
        await detectRequiredTools()
        guard !ccSwitchStatus.isInstalled else {
            log("CC Switch 已安装", .success)
            return
        }

        toolSetupInProgress = false
        ccSwitchStatus = .installing
        log("将打开终端自动安装 CC Switch。过程中可能需要输入本机密码", .info)
        let command = """
        set -e
        RELEASES_URL="https://github.com/farion1231/cc-switch/releases"
        LATEST_URL=$(curl -fsSLI -o /dev/null -w "%{url_effective}" "$RELEASES_URL/latest" || true)
        VERSION="${LATEST_URL##*/}"
        if [[ -z "$VERSION" || "$VERSION" == "latest" || "$VERSION" != v* ]]; then
          echo "未能读取 CC Switch 最新版本，已打开下载页面，请手动下载 macOS DMG。"
          open "$RELEASES_URL"
          read -n 1 -s -r -p "按任意键关闭窗口..."
          exit 1
        fi

        TMP_DIR=$(mktemp -d)
        DMG_PATH="$TMP_DIR/CC-Switch-$VERSION-macOS.dmg"
        DMG_URL="$RELEASES_URL/download/$VERSION/CC-Switch-$VERSION-macOS.dmg"
        echo "正在下载 CC Switch $VERSION..."
        if ! curl -fL --progress-bar -o "$DMG_PATH" "$DMG_URL"; then
          echo "下载失败，已打开 CC Switch 下载页面，请手动下载 macOS DMG。"
          open "$RELEASES_URL/latest"
          read -n 1 -s -r -p "按任意键关闭窗口..."
          exit 1
        fi

        echo "正在挂载安装包..."
        MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -readonly -plist | /usr/bin/python3 -c 'import plistlib,sys; data=plistlib.load(sys.stdin); print(next(item["mount-point"] for item in data["system-entities"] if "mount-point" in item))')
        cleanup() {
          if [[ -n "${MOUNT_POINT:-}" ]]; then
            hdiutil detach "$MOUNT_POINT" -quiet || true
          fi
          rm -rf "$TMP_DIR"
        }
        trap cleanup EXIT

        APP_PATH=$(find "$MOUNT_POINT" -maxdepth 2 -name "CC Switch.app" -type d | head -n 1)
        if [[ -z "$APP_PATH" ]]; then
          echo "安装包里没有找到 CC Switch.app，已打开下载页面。"
          open "$RELEASES_URL/latest"
          exit 1
        fi

        echo "正在复制到 /Applications..."
        if [[ -w "/Applications" ]]; then
          rm -rf "/Applications/CC Switch.app"
          ditto "$APP_PATH" "/Applications/CC Switch.app"
        else
          sudo rm -rf "/Applications/CC Switch.app"
          sudo ditto "$APP_PATH" "/Applications/CC Switch.app"
        fi
        xattr -dr com.apple.quarantine "/Applications/CC Switch.app" 2>/dev/null || true
        open "/Applications/CC Switch.app"
        echo
        echo "CC Switch 安装流程结束。你可以回到蝉舒宝继续导入 provider。"
        read -n 1 -s -r -p "按任意键关闭窗口..."
        """
        let script = """
        tell application "Terminal"
            activate
            do script \(appleScriptStringLiteral(command))
        end tell
        """
        let result = await CommandRunner.run("/usr/bin/osascript", ["-e", script])
        if result.succeeded {
            ccSwitchInstallFailed = false
            browserSuggestion = "CC Switch 安装已在终端打开，完成后蝉舒宝会自动检测。"
        } else {
            ccSwitchInstallFailed = true
            ccSwitchStatus = .failed
            log("打开终端安装 CC Switch 失败: \((result.stderr.isEmpty ? result.stdout : result.stderr).prefix(240))", .error)
            await detectRequiredTools()
        }
    }

    func installCodexIfNeeded() async {
        await detectRequiredTools()
        guard !codexStatus.isInstalled else {
            log("Codex 桌面版已安装", .success)
            return
        }
        codexInstallFailed = false
        codexStatus = .failed
        log("Codex 桌面版需要手动安装；已打开 ChatGPT 桌面版下载页面", .info)
        if let url = URL(string: "https://chatgpt.com/zh-Hans-CN/features/desktop/") {
            NSWorkspace.shared.open(url)
        }
    }

    func openDeveloperPortal() {
        ccSwitchImportStatus = .waitingForLogin
        browserImportMessage = "请在登录窗口完成授权"
        if let url = URL(string: "https://ai.limayao.com/developer") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func saveAPIKeyLocally(_ value: String) -> Bool {
        updateAPIKey(value)
        return true
    }

    func importCCSwitchProviderFromBrowser() async {
        ccSwitchImportStatus = .extracting
        browserImportMessage = "正在读取浏览器页面"
        log("正在从浏览器读取 limayao 开发者后台的 CC Switch 导入信息", .info)

        if let payload = await extractDeveloperPayloadFromBrowser() {
            if let apiKey = payload.apiKey {
                saveAPIKeyLocally(apiKey)
                log("已从开发者后台提取 API Key 并保存到本地", .success)
            }
            if let deepLink = payload.deepLink, let url = URL(string: deepLink) {
                NSWorkspace.shared.open(url)
                ccSwitchProviderImported = true
                ccSwitchImportStatus = .imported
                browserImportMessage = "已唤起 CC Switch 导入"
                log("已通过 ccswitch:// 深链唤起 CC Switch 导入 provider", .success)
                return
            }
            if payload.apiKey != nil {
                ccSwitchImportStatus = .needsManualPaste
                browserImportMessage = "已提取 Key，未找到导入深链"
                log("已提取 API Key，但页面里未找到 ccswitch:// 导入深链，请手动点击后台的 CC Switch 导入按钮", .warn)
                return
            }
        }

        ccSwitchImportStatus = .needsManualPaste
        browserImportMessage = "未读取到导入信息"
        log("未能从浏览器读取 CC Switch 导入信息。请确认已登录后台，或手动复制 API Key", .warn)
    }

    func importCCSwitchProvider(fromPageText text: String) {
        ccSwitchImportStatus = .extracting
        browserImportMessage = "正在导入当前页面"
        let payload = DeveloperPortalPayload(
            deepLink: extractCCSwitchDeepLink(from: text),
            apiKey: extractAPIKey(from: text)
        )

        if let apiKey = payload.apiKey {
            saveAPIKeyLocally(apiKey)
            log("已从内置浏览器提取 API Key 并保存到本地", .success)
        }

        if let deepLink = payload.deepLink, let url = URL(string: deepLink) {
            NSWorkspace.shared.open(url)
            ccSwitchProviderImported = true
            ccSwitchImportStatus = .imported
            browserImportMessage = "已唤起 CC Switch 导入"
            log("已通过内置浏览器页面的 ccswitch:// 深链唤起 CC Switch 导入 provider", .success)
            return
        }

        if payload.apiKey != nil {
            ccSwitchImportStatus = .needsManualPaste
            browserImportMessage = "已提取 Key，未找到导入深链"
            log("内置浏览器已提取 API Key，但未找到 ccswitch:// 导入深链", .warn)
        } else {
            ccSwitchImportStatus = .needsManualPaste
            browserImportMessage = "请先登录并打开含 CC Switch 按钮的页面"
            log("内置浏览器当前页面未读取到 CC Switch 深链或 API Key，请确认已登录并停留在开发者后台", .warn)
        }
    }

    func extractDeveloperAPIKeyFromBrowser() async {
        ccSwitchImportStatus = .extracting
        browserImportMessage = "正在提取 API Key"
        if let payload = await extractDeveloperPayloadFromBrowser(), let apiKey = payload.apiKey {
            saveAPIKeyLocally(apiKey)
            ccSwitchImportStatus = .needsManualPaste
            browserImportMessage = "已提取 API Key"
            log("已从浏览器提取 API Key", .success)
        } else {
            ccSwitchImportStatus = .needsManualPaste
            browserImportMessage = "未找到 API Key"
            log("未能从浏览器页面提取 API Key", .warn)
        }
    }

    private struct DeveloperPortalPayload {
        let deepLink: String?
        let apiKey: String?
    }

    private func extractDeveloperPayloadFromBrowser() async -> DeveloperPortalPayload? {
        for browser in ["Google Chrome", "Safari"] {
            let script = browserExtractionAppleScript(browserName: browser)
            let result = await CommandRunner.run("/usr/bin/osascript", ["-e", script])
            guard result.succeeded, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let deepLink = extractCCSwitchDeepLink(from: output)
            let apiKey = extractAPIKey(from: output)
            if deepLink != nil || apiKey != nil {
                return DeveloperPortalPayload(deepLink: deepLink, apiKey: apiKey)
            }
        }
        return nil
    }

    private func browserExtractionAppleScript(browserName: String) -> String {
        let js = """
        (() => {
          const nodes = Array.from(document.querySelectorAll('.ccswitch-dropdown-item.ccswitch-dropdown-item--both, .ccswitch-dropdown-item--both, a, button'));
          const parts = [];
          for (const node of nodes) {
            const attrs = Array.from(node.attributes || []).map(a => `${a.name}=${a.value}`).join(' ');
            const text = (node.innerText || node.textContent || '').trim();
            parts.push(`${attrs}\\n${text}`);
          }
          parts.push(document.body ? document.body.innerText : '');
          return parts.join('\\n---CCS---\\n');
        })()
        """
        let escapedJS = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        if browserName == "Google Chrome" {
            return """
            tell application "Google Chrome"
                if not (exists front window) then return ""
                execute active tab of front window javascript "\(escapedJS)"
            end tell
            """
        }

        return """
        tell application "Safari"
            if not (exists front document) then return ""
            do JavaScript "\(escapedJS)" in front document
        end tell
        """
    }

    private func extractCCSwitchDeepLink(from text: String) -> String? {
        guard let match = text.firstMatch(of: /ccswitch:\/\/[^\s"'<>]+/) else { return nil }
        return String(match.output)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAPIKey(from text: String) -> String? {
        if let match = text.firstMatch(of: /(?i)bearer\s+([A-Za-z0-9_\-\.]{20,})/) {
            return String(match.1)
        }
        if let match = text.firstMatch(of: /(?i)(?:api[_ -]?key|token|key)\s*[:=]\s*["']?([A-Za-z0-9_\-\.]{20,})/) {
            return String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: " :=\"'\n\t"))
        }
        if let match = text.firstMatch(of: /(sk-[A-Za-z0-9_\-]{20,})/) {
            return String(match.1)
        }
        if let match = text.firstMatch(of: /(lm-[A-Za-z0-9_\-]{20,})/) {
            return String(match.1)
        }
        return nil
    }

    private func repairLaunchAgentWithAdministratorPrivileges(plistPath: String) async -> Bool {
        let launchAgentsPath = "\(homeDir)/Library/LaunchAgents"
        let currentUser = NSUserName()
        let command = [
            "mkdir -p \(shellQuoted(launchAgentsPath))",
            "chflags nouchg \(shellQuoted(launchAgentsPath)) 2>/dev/null || true",
            "chown \(shellQuoted(currentUser)):staff \(shellQuoted(launchAgentsPath))",
            "chmod 755 \(shellQuoted(launchAgentsPath))",
            "if [ -e \(shellQuoted(plistPath)) ]; then chflags nouchg \(shellQuoted(plistPath)) 2>/dev/null || true; chown \(shellQuoted(currentUser)):staff \(shellQuoted(plistPath)); chmod 644 \(shellQuoted(plistPath)); fi"
        ].joined(separator: " && ")

        log("LaunchAgents 权限需要管理员授权修复，请在系统弹窗中输入本机密码", .warn)
        let script = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"
        let result = await CommandRunner.run("/usr/bin/osascript", ["-e", script])
        if result.succeeded {
            log("LaunchAgents 权限已通过管理员授权修复", .success)
            return true
        }

        let reason = result.stderr.isEmpty ? result.stdout : result.stderr
        log("管理员授权修复 LaunchAgents 失败: \(reason.isEmpty ? "未返回详细原因" : reason)", .error)
        return false
    }

    private func ensureLaunchAgentWritable(plistPath: String) async -> Bool {
        let launchAgentsPath = "\(homeDir)/Library/LaunchAgents"
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                atPath: launchAgentsPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            log("LaunchAgents 目录创建失败: \(error.localizedDescription)", .error)
            return false
        }

        let currentUser = NSUserName()
        _ = await CommandRunner.run("/usr/sbin/chown", [currentUser, launchAgentsPath])
        _ = await CommandRunner.run("/bin/chmod", ["755", launchAgentsPath])

        if fileManager.fileExists(atPath: plistPath) {
            if fileManager.isWritableFile(atPath: plistPath) {
                return true
            }

            _ = await CommandRunner.run("/usr/sbin/chown", [currentUser, plistPath])
            _ = await CommandRunner.run("/bin/chmod", ["644", plistPath])
            if fileManager.isWritableFile(atPath: plistPath) {
                log("已修复旧 launchd 配置文件权限", .info)
                return true
            }

            do {
                try fileManager.removeItem(atPath: plistPath)
                log("旧 launchd 配置不可写，已删除后重建", .warn)
                return true
            } catch {
                log("旧 launchd 配置不可写且无法删除: \(error.localizedDescription)", .error)
                return await repairLaunchAgentWithAdministratorPrivileges(plistPath: plistPath)
            }
        }

        if fileManager.isWritableFile(atPath: launchAgentsPath) {
            return true
        }

        if await repairLaunchAgentWithAdministratorPrivileges(plistPath: plistPath) {
            return fileManager.isWritableFile(atPath: launchAgentsPath)
        }

        return false
    }

    private func managedPaths() -> (plist: String, guardScript: String, mergePaths: [String], chromePaths: [String]) {
        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        let guardScript = "\(homeDir)/.local/bin/clash-proxy-guard.sh"
        let codexEnvPath = "\(homeDir)/.codex/.env"
        let mergePaths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/merge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/merge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/dns_config.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge-check.yaml",
        ]
        let chromePaths = [
            "\(homeDir)/Library/Preferences/com.google.Chrome.plist",
            "\(homeDir)/Library/Application Support/Google/Chrome/Managed/com.google.Chrome.plist",
        ]
        return (plistPath, guardScript, mergePaths + [codexEnvPath], chromePaths)
    }

    private func isLaunchdGuardLoaded() async -> Bool {
        let result = await CommandRunner.run("/bin/launchctl", ["print", guardLaunchdService])
        return result.succeeded
    }

    private func isGuardScriptRunning(_ guardScript: String) async -> Bool {
        let escapedPath = NSRegularExpression.escapedPattern(for: guardScript)
        let result = await CommandRunner.run("/usr/bin/pgrep", ["-f", escapedPath])
        return result.succeeded && !result.stdout.isEmpty
    }

    private func stopLaunchdGuard(plistPath: String, guardScript: String) async -> Bool {
        let launchdDomain = "gui/\(getuid())"

        _ = await CommandRunner.run("/bin/launchctl", ["bootout", guardLaunchdService])
        if await isLaunchdGuardLoaded() {
            _ = await CommandRunner.run("/bin/launchctl", ["bootout", launchdDomain, plistPath])
        }
        if await isLaunchdGuardLoaded() {
            _ = await CommandRunner.run("/bin/launchctl", ["unload", plistPath])
        }
        if await isLaunchdGuardLoaded() {
            _ = await CommandRunner.run("/bin/launchctl", ["remove", guardLaunchdLabel])
        }

        let escapedPath = NSRegularExpression.escapedPattern(for: guardScript)
        _ = await CommandRunner.run("/usr/bin/pkill", ["-TERM", "-f", escapedPath])
        try? await Task.sleep(nanoseconds: 200_000_000)

        let launchdLoaded = await isLaunchdGuardLoaded()
        let scriptRunning = await isGuardScriptRunning(guardScript)
        guardLoaded = launchdLoaded
        if launchdLoaded || scriptRunning {
            var details: [String] = []
            if launchdLoaded { details.append("launchd 任务仍已加载") }
            if scriptRunning { details.append("守护脚本进程仍在运行") }
            log("网络守护停止失败: \(details.joined(separator: "；"))", .error)
            return false
        }

        log("网络守护已从 launchd 完全移除", .success)
        return true
    }

    private func parseCompleteProxyEndpoint(_ output: String) -> ProxyEndpointSnapshot? {
        var enabled: Bool?
        var server: String?
        var port: String?
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            if key == "Enabled" {
                if value.lowercased().hasPrefix("yes") { enabled = true }
                else if value.lowercased().hasPrefix("no") { enabled = false }
            }
            if key == "Server" { server = value }
            if key == "Port" { port = value }
        }
        guard let enabled, let server, let port else { return nil }
        if enabled {
            guard !server.isEmpty, let portNumber = Int(port), (1...65535).contains(portNumber) else {
                return nil
            }
        }
        return ProxyEndpointSnapshot(enabled: enabled, server: server, port: port)
    }

    private func parseProxyEndpoint(_ output: String) -> ProxyEndpointSnapshot {
        parseCompleteProxyEndpoint(output)
            ?? ProxyEndpointSnapshot(enabled: false, server: "", port: "")
    }

    private func parseBypassDomains(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("there aren't any") }
    }

    private func normalizedHost(_ value: String) -> String {
        NetworkCompatibility.normalizedDomain(value) ?? ""
    }

    private func isClashFakeIP(_ ip: String) -> Bool {
        ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.")
    }

    private func realIPv4(from output: String) -> String? {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { ip in
                NetworkCompatibility.isValidIPv4(ip) && !isClashFakeIP(ip)
            }
    }

    private func routeRange(for ip: String) -> String? {
        let parts = ip.components(separatedBy: ".")
        guard NetworkCompatibility.isValidIPv4(ip) else { return nil }
        return "\(parts[0]).\(parts[1]).0.0/16"
    }

    private func systemNameservers() async -> [String] {
        let result = await CommandRunner.runShell("scutil --dns 2>/dev/null | awk '/nameserver\\[[0-9]+\\]/{print $3}'")
        var seen = Set<String>()
        return result.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func resolveRealIPv4(_ host: String, nameservers: [String]? = nil) async -> String? {
        guard let host = NetworkCompatibility.normalizedDomain(host) else { return nil }
        let direct = await CommandRunner.run("/usr/bin/dig", ["+short", host])
        if let ip = realIPv4(from: direct.stdout) {
            return ip
        }

        let servers: [String]
        if let nameservers {
            servers = nameservers
        } else {
            servers = await systemNameservers()
        }
        for server in servers {
            guard NetworkCompatibility.isValidIPv4(server) else { continue }
            let result = await CommandRunner.run("/usr/bin/dig", ["@\(server)", "+short", host])
            if let ip = realIPv4(from: result.stdout) {
                return ip
            }
        }

        return nil
    }

    private func host(_ host: String, isUnder domain: String) -> Bool {
        let host = normalizedHost(host)
        let domain = normalizedHost(domain)
        return host == domain || host.hasSuffix(".\(domain)")
    }

    private func domainHasProxyRequiredHost(_ domain: String) -> Bool {
        proxyRequiredHosts.contains { host($0, isUnder: domain) }
    }

    private func broadBypassItems(for domain: String) -> [String] {
        let domain = normalizedHost(domain)
        guard !domain.isEmpty else { return [] }
        if domainHasProxyRequiredHost(domain) {
            return directCompanyHosts.filter { host($0, isUnder: domain) }
        }
        return [domain, "*.\(domain)"]
    }

    private var requiredCompanyBypassItems: [String] {
        companyDomains.flatMap { broadBypassItems(for: $0) }
    }

    private var baselineBypassItems: [String] {
        ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16",
         "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16"]
            + requiredCompanyBypassItems
    }

    private func managedBypassItems(nameservers: [String]) async -> [String] {
        var items = baselineBypassItems
        for domain in companyDomains {
            if let ip = await resolveRealIPv4(domain, nameservers: nameservers), let range = routeRange(for: ip) {
                items.append(range)
            }
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private func bypassItemCoversProxyRequiredHost(_ item: String) -> Bool {
        let domain = normalizedHost(item)
        guard !domain.isEmpty, !domain.contains("/") else { return false }
        return proxyRequiredHosts.contains { host($0, isUnder: domain) }
    }

    private func appBypassItems(_ items: [String]) -> [String] {
        var output: [String] = []
        for item in items {
            if bypassItemCoversProxyRequiredHost(item) {
                output.append(contentsOf: broadBypassItems(for: item))
            } else {
                output.append(item)
            }
        }
        var seen = Set<String>()
        return output.filter { seen.insert($0).inserted }
    }

    private func noProxyItems(from bypassItems: [String]) -> [String] {
        var items: [String] = ["localhost", "127.0.0.1", "::1"]
        for item in appBypassItems(bypassItems) {
            if item == "*.local" {
                items.append(".local")
            } else if item.hasPrefix("*.") {
                let suffix = String(item.dropFirst(1))
                items.append(suffix)
                items.append(String(item.dropFirst(2)))
            } else {
                items.append(item)
            }
        }

        for domain in companyDomains {
            for item in broadBypassItems(for: domain) {
                items.append(item)
                if item.hasPrefix("*.") {
                    let suffix = String(item.dropFirst(1))
                    items.append(suffix)
                    items.append(String(item.dropFirst(2)))
                }
            }
        }
        items.append(contentsOf: directCompanyHosts)

        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private func setLaunchdNoProxy(_ bypassItems: [String]) async -> Bool {
        let value = noProxyItems(from: bypassItems).joined(separator: ",")
        for key in managedNoProxyKeys {
            let result = await CommandRunner.run("/bin/launchctl", ["setenv", key, value])
            guard result.succeeded else { return false }
            let actual = await CommandRunner.run("/bin/launchctl", ["getenv", key])
            guard actual.succeeded, actual.stdout == value else { return false }
        }
        log("已设置应用环境 NO_PROXY/no_proxy（ccswitch 等非浏览器应用需重启后生效）", .success)
        return true
    }

    private func setLaunchdProxy(endpoint: LocalProxyEndpoint) async -> Bool {
        let proxyURL = proxyURL(for: endpoint)
        for key in managedProxyKeys {
            let result = await CommandRunner.run("/bin/launchctl", ["setenv", key, proxyURL])
            guard result.succeeded else { return false }
            let actual = await CommandRunner.run("/bin/launchctl", ["getenv", key])
            guard actual.succeeded, actual.stdout == proxyURL else { return false }
        }
        for key in managedAllProxyKeys {
            let result = await CommandRunner.run("/bin/launchctl", ["unsetenv", key])
            guard result.succeeded else { return false }
            let actual = await CommandRunner.run("/bin/launchctl", ["getenv", key])
            guard actual.stdout.isEmpty else { return false }
        }
        log("已设置应用环境 HTTP_PROXY/HTTPS_PROXY（ccswitch 等非浏览器应用需重启后生效）", .success)
        log("已清理应用环境 ALL_PROXY/all_proxy，避免强制兜底走 Clash", .success)
        return true
    }

    private func writeAppEnvironment(endpoint: LocalProxyEndpoint, bypassItems: [String]) async {
        let codexDir = "\(homeDir)/.codex"
        let codexEnvPath = "\(codexDir)/.env"
        let proxyURL = proxyURL(for: endpoint)
        let noProxyValue = noProxyItems(from: bypassItems).joined(separator: ",")

        try? FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        let existing = (try? String(contentsOfFile: codexEnvPath, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var skippingManagedBlock = false

        for line in existing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# === MergeSASE managed proxy environment ===" || trimmed == "# === 蝉舒宝 managed proxy environment ===" {
                skippingManagedBlock = true
                continue
            }
            if trimmed == "# === End MergeSASE managed proxy environment ===" || trimmed == "# === End 蝉舒宝 managed proxy environment ===" {
                skippingManagedBlock = false
                continue
            }
            if skippingManagedBlock { continue }

            let isOldProxyLine = [
                "export HTTP_PROXY=", "export HTTPS_PROXY=", "export ALL_PROXY=",
                "export http_proxy=", "export https_proxy=", "export all_proxy=",
                "export NO_PROXY=", "export no_proxy=",
                "unset ALL_PROXY", "unset all_proxy"
            ].contains { trimmed.hasPrefix($0) }

            if !isOldProxyLine {
                kept.append(line)
            }
        }

        while kept.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            kept.removeLast()
        }

        let block = """

        # === 蝉舒宝 managed proxy environment ===
        export HTTP_PROXY=\(proxyURL)
        export HTTPS_PROXY=\(proxyURL)
        # Public traffic can still use HTTP(S)_PROXY; company VPN traffic must bypass Clash.
        unset ALL_PROXY
        unset all_proxy
        export NO_PROXY=\(noProxyValue)
        export http_proxy=\(proxyURL)
        export https_proxy=\(proxyURL)
        export no_proxy=\(noProxyValue)
        # === End 蝉舒宝 managed proxy environment ===
        """

        do {
            let content = kept.joined(separator: "\n") + block + "\n"
            try content.write(toFile: codexEnvPath, atomically: true, encoding: .utf8)
            appEnvFixed = (try? String(contentsOfFile: codexEnvPath, encoding: .utf8)) == content
            if appEnvFixed {
                log("Codex/应用代理环境已写入并校验", .success)
            } else {
                log("Codex/应用代理环境写入后读回校验失败", .error)
            }
        } catch {
            appEnvFixed = false
            log("Codex/应用代理环境写入失败: \(error.localizedDescription)", .warn)
        }
    }

    private func restoreLaunchdEnvironment(_ snapshot: RestoreSnapshot) async -> [String] {
        var issues: [String] = []
        let launchdEnvironment = snapshot.launchdEnvironment ?? [:]
        for key in managedEnvKeys {
            let result: CommandResult
            if let stored = launchdEnvironment[key], let value = stored, !value.isEmpty {
                result = await CommandRunner.run("/bin/launchctl", ["setenv", key, value])
            } else {
                result = await CommandRunner.run("/bin/launchctl", ["unsetenv", key])
            }
            if !result.succeeded { issues.append("环境变量 \(key) 写入") }
        }
        return issues
    }

    private func snapshotIsUsable(at path: String) -> Bool {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let snapshot = try? JSONDecoder().decode(RestoreSnapshot.self, from: data)
        else {
            return false
        }

        guard snapshot.formatVersion == currentSnapshotFormatVersion,
              let launchdEnvironment = snapshot.launchdEnvironment,
              let runtime = snapshot.managedRuntime,
              Set(launchdEnvironment.keys) == Set(managedEnvKeys),
              !snapshot.networkServices.isEmpty,
              !runtime.networkServices.isEmpty,
              runtime.networkServices == snapshot.networkServices.map(\.service),
              !runtime.bypassDomains.isEmpty,
              !runtime.proxyHost.isEmpty,
              (1...65535).contains(runtime.proxyPort)
        else {
            return false
        }

        let serviceNames = snapshot.networkServices.map(\.service)
        guard serviceNames.allSatisfy({ !$0.isEmpty }), Set(serviceNames).count == serviceNames.count else {
            return false
        }

        let paths = managedPaths()
        let expectedPaths = Set(paths.chromePaths + paths.mergePaths)
        let savedPaths = snapshot.files.map(\.path)
        guard snapshot.files.count == expectedPaths.count,
              Set(savedPaths) == expectedPaths,
              Set(savedPaths).count == savedPaths.count
        else {
            return false
        }

        var backupNames = Set<String>()
        return snapshot.files.allSatisfy { file in
            guard file.existed else { return file.backupName == nil }
            guard let backupName = file.backupName,
                  !backupName.isEmpty,
                  backupName == (backupName as NSString).lastPathComponent,
                  backupNames.insert(backupName).inserted
            else {
                return false
            }
            return FileManager.default.fileExists(atPath: "\(backupDir)/\(backupName)")
        }
    }

    private func legacySnapshotIsRestorable(_ snapshot: RestoreSnapshot) -> Bool {
        guard snapshot.formatVersion == nil,
              let launchdEnvironment = snapshot.launchdEnvironment,
              Set(launchdEnvironment.keys).isSubset(of: Set(managedEnvKeys)),
              !snapshot.networkServices.isEmpty
        else {
            return false
        }

        let serviceNames = snapshot.networkServices.map(\.service)
        guard serviceNames.allSatisfy({ !$0.isEmpty }), Set(serviceNames).count == serviceNames.count else {
            return false
        }

        let paths = managedPaths()
        let legacyPaths = Set(paths.chromePaths + paths.mergePaths.filter {
            let name = ($0 as NSString).lastPathComponent
            return name != "clash-verge.yaml" && name != "clash-verge-check.yaml"
        })
        let savedPaths = snapshot.files.map(\.path)
        let savedPathSet = Set(savedPaths)
        let legacyPathsWithGuardFiles = legacyPaths.union([paths.plist, paths.guardScript])
        guard (savedPathSet == legacyPaths || savedPathSet == legacyPathsWithGuardFiles),
              Set(savedPaths).count == savedPaths.count
        else {
            return false
        }

        var backupNames = Set<String>()
        return snapshot.files.allSatisfy { file in
            guard file.existed else { return file.backupName == nil }
            guard let backupName = file.backupName,
                  !backupName.isEmpty,
                  backupName == (backupName as NSString).lastPathComponent,
                  backupNames.insert(backupName).inserted
            else {
                return false
            }
            return FileManager.default.fileExists(atPath: "\(backupDir)/\(backupName)")
        }
    }

    private func activePhysicalNetworkServices() async -> [String] {
        let order = await CommandRunner.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        guard order.succeeded else { return [] }

        var result: [String] = []
        for service in NetworkCompatibility.physicalNetworkServices(from: order.stdout) {
            let interface = await CommandRunner.run("/sbin/ifconfig", [service.device])
            guard interface.succeeded else { continue }
            let hasIPv4 = interface.stdout.components(separatedBy: .newlines).contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("inet ")
            }
            if interface.stdout.contains("status: active") || hasIPv4 {
                result.append(service.name)
            }
        }
        return result
    }

    private func takeRestoreSnapshotIfNeeded(
        for services: [String],
        managedRuntime: ManagedRuntimeSnapshot
    ) async -> Bool {
        let paths = managedPaths()
        let liveGuardLoaded = await isLaunchdGuardLoaded()
        let guardScriptRunning = await isGuardScriptRunning(paths.guardScript)
        if FileManager.default.fileExists(atPath: paths.plist)
            || FileManager.default.fileExists(atPath: paths.guardScript)
            || liveGuardLoaded
            || guardScriptRunning {
            log("检测到旧网络守护残留；为避免保存错误还原点，本次未修改网络", .error)
            return false
        }
        if FileManager.default.fileExists(atPath: snapshotPath) {
            if snapshotIsUsable(at: snapshotPath) {
                let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath))
                let snapshot = data.flatMap { try? JSONDecoder().decode(RestoreSnapshot.self, from: $0) }
                let savedServices = Set(snapshot?.networkServices.map(\.service) ?? [])
                if Set(services).isSubset(of: savedServices),
                   snapshot?.managedRuntime?.networkServices == managedRuntime.networkServices,
                   snapshot?.managedRuntime?.bypassDomains == managedRuntime.bypassDomains,
                   snapshot?.managedRuntime?.proxyHost == managedRuntime.proxyHost,
                   snapshot?.managedRuntime?.proxyPort == managedRuntime.proxyPort {
                    log("已存在可用的启动前快照，本次不覆盖", .info)
                    return true
                }
            }
            log("检测到不匹配的旧快照；为避免覆盖还原点，本次未修改网络", .error)
            return false
        }

        try? FileManager.default.removeItem(atPath: backupDir)
        try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        var networkSnapshots: [NetworkServiceSnapshot] = []
        for service in services {
            let web = await CommandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service])
            let secure = await CommandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])
            let socks = await CommandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])
            let bypass = await CommandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])
            guard web.succeeded, secure.succeeded, socks.succeeded, bypass.succeeded,
                  let webSnapshot = parseCompleteProxyEndpoint(web.stdout),
                  let secureSnapshot = parseCompleteProxyEndpoint(secure.stdout),
                  let socksSnapshot = parseCompleteProxyEndpoint(socks.stdout)
            else {
                try? FileManager.default.removeItem(atPath: backupDir)
                log("\(service) 当前代理配置读取不完整，已中止且未修改网络", .error)
                return false
            }
            networkSnapshots.append(NetworkServiceSnapshot(
                service: service,
                web: webSnapshot,
                secureWeb: secureSnapshot,
                socks: socksSnapshot,
                bypassDomains: parseBypassDomains(bypass.stdout)
            ))
        }

        let filePaths = paths.chromePaths + paths.mergePaths
        var fileSnapshots: [FileSnapshot] = []
        for (idx, path) in filePaths.enumerated() {
            if FileManager.default.fileExists(atPath: path) {
                let backupName = "file_\(idx)"
                do {
                    try FileManager.default.copyItem(atPath: path, toPath: "\(backupDir)/\(backupName)")
                } catch {
                    try? FileManager.default.removeItem(atPath: backupDir)
                    log("配置备份失败：\((path as NSString).lastPathComponent)，已中止且未修改网络", .error)
                    return false
                }
                fileSnapshots.append(FileSnapshot(path: path, existed: true, backupName: backupName))
            } else {
                fileSnapshots.append(FileSnapshot(path: path, existed: false, backupName: nil))
            }
        }

        var launchdEnvironment: [String: String?] = [:]
        for key in managedEnvKeys {
            let envRes = await CommandRunner.run("/bin/launchctl", ["getenv", key])
            guard envRes.succeeded else {
                try? FileManager.default.removeItem(atPath: backupDir)
                log("无法读取环境变量 \(key)，已中止且未修改网络", .error)
                return false
            }
            launchdEnvironment.updateValue(envRes.stdout.isEmpty ? nil : envRes.stdout, forKey: key)
        }

        let snapshot = RestoreSnapshot(
            formatVersion: currentSnapshotFormatVersion,
            createdAt: Date(),
            networkServices: networkSnapshots,
            files: fileSnapshots,
            launchdEnvironment: launchdEnvironment,
            managedRuntime: managedRuntime
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
            if snapshotIsUsable(at: snapshotPath) {
                log("启动前配置快照已保存并校验", .success)
                return true
            }
        }
        log("启动前配置快照保存失败，已中止启动且未修改网络", .error)
        return false
    }

    private func applySystemProxy(
        endpoint: LocalProxyEndpoint,
        bypassDomains: [String],
        services: [String]
    ) async -> Bool {
        let setters = ["-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy"]
        let stateSetters = ["-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate"]

        for service in services {
            for command in setters {
                let result = await CommandRunner.run("/usr/sbin/networksetup", [command, service, endpoint.host, "\(endpoint.port)"])
                guard result.succeeded else {
                    log("\(service) 代理写入失败: \(result.stderr.isEmpty ? result.stdout : result.stderr)", .error)
                    return false
                }
            }
            for command in stateSetters {
                let result = await CommandRunner.run("/usr/sbin/networksetup", [command, service, "on"])
                guard result.succeeded else {
                    log("\(service) 代理启用失败: \(result.stderr.isEmpty ? result.stdout : result.stderr)", .error)
                    return false
                }
            }
            let bypassResult = await CommandRunner.run("/usr/sbin/networksetup", ["-setproxybypassdomains", service] + bypassDomains)
            guard bypassResult.succeeded else {
                log("\(service) 绕过列表写入失败: \(bypassResult.stderr.isEmpty ? bypassResult.stdout : bypassResult.stderr)", .error)
                return false
            }

            let expected = ProxyEndpointSnapshot(enabled: true, server: endpoint.host, port: "\(endpoint.port)")
            let web = parseProxyEndpoint((await CommandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service])).stdout)
            let secure = parseProxyEndpoint((await CommandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])).stdout)
            let socks = parseProxyEndpoint((await CommandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])).stdout)
            let actualBypass = parseBypassDomains((await CommandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])).stdout)
            guard proxyEndpoint(web, matches: expected),
                  proxyEndpoint(secure, matches: expected),
                  proxyEndpoint(socks, matches: expected),
                  Set(normalizedBypassDomains(bypassDomains)).isSubset(of: Set(normalizedBypassDomains(actualBypass)))
            else {
                log("\(service) 代理写入后读回校验失败", .error)
                return false
            }
        }
        return true
    }

    private func monitoredNetworkConfigurationIsValid() async -> Bool {
        guard let endpoint = monitoredProxyEndpoint, !monitoredNetworkServices.isEmpty else {
            return false
        }

        let activeServices = await activePhysicalNetworkServices()
        guard !activeServices.isEmpty,
              Set(activeServices).isSubset(of: Set(monitoredNetworkServices))
        else {
            return false
        }

        let expected = ProxyEndpointSnapshot(enabled: true, server: endpoint.host, port: "\(endpoint.port)")
        let expectedBypass = Set(normalizedBypassDomains(monitoredBypassDomains))
        for service in monitoredNetworkServices {
            let webResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service])
            let secureResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])
            let socksResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])
            let bypassResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])
            guard webResult.succeeded, secureResult.succeeded, socksResult.succeeded, bypassResult.succeeded,
                  let web = parseCompleteProxyEndpoint(webResult.stdout),
                  let secure = parseCompleteProxyEndpoint(secureResult.stdout),
                  let socks = parseCompleteProxyEndpoint(socksResult.stdout),
                  proxyEndpoint(web, matches: expected),
                  proxyEndpoint(secure, matches: expected),
                  proxyEndpoint(socks, matches: expected),
                  expectedBypass.isSubset(of: Set(normalizedBypassDomains(parseBypassDomains(bypassResult.stdout))))
            else {
                return false
            }
        }
        return true
    }

    private func restoreEndpoint(_ endpoint: ProxyEndpointSnapshot, service: String, setCommand: String, stateCommand: String) async -> Bool {
        var succeeded = true
        if !endpoint.server.isEmpty, let port = Int(endpoint.port), (1...65535).contains(port) {
            let result = await CommandRunner.run("/usr/sbin/networksetup", [setCommand, service, endpoint.server, "\(port)"])
            succeeded = result.succeeded
        }
        let stateResult = await CommandRunner.run("/usr/sbin/networksetup", [stateCommand, service, endpoint.enabled ? "on" : "off"])
        return succeeded && stateResult.succeeded
    }

    private func proxyEndpoint(_ actual: ProxyEndpointSnapshot, matches expected: ProxyEndpointSnapshot) -> Bool {
        guard actual.enabled == expected.enabled else { return false }
        let hasRestorableDormantEndpoint = !expected.server.isEmpty
            && Int(expected.port).map { (1...65535).contains($0) } == true
        if !expected.enabled && !hasRestorableDormantEndpoint {
            return true
        }
        return actual.server.caseInsensitiveCompare(expected.server) == .orderedSame
            && actual.port == expected.port
    }

    private func normalizedBypassDomains(_ domains: [String]) -> [String] {
        Array(Set(domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })).sorted()
    }

    private func verifyRestoredSnapshot(_ snapshot: RestoreSnapshot) async -> [String] {
        var issues: [String] = []

        for item in snapshot.networkServices {
            let webResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", item.service])
            let secureResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", item.service])
            let socksResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", item.service])
            let bypassResult = await CommandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", item.service])
            guard webResult.succeeded, secureResult.succeeded, socksResult.succeeded, bypassResult.succeeded,
                  let web = parseCompleteProxyEndpoint(webResult.stdout),
                  let secure = parseCompleteProxyEndpoint(secureResult.stdout),
                  let socks = parseCompleteProxyEndpoint(socksResult.stdout)
            else {
                issues.append("\(item.service) 配置读取")
                continue
            }
            let bypass = parseBypassDomains(bypassResult.stdout)
            if !proxyEndpoint(web, matches: item.web) { issues.append("\(item.service) HTTP 代理") }
            if !proxyEndpoint(secure, matches: item.secureWeb) { issues.append("\(item.service) HTTPS 代理") }
            if !proxyEndpoint(socks, matches: item.socks) { issues.append("\(item.service) SOCKS 代理") }
            if normalizedBypassDomains(bypass) != normalizedBypassDomains(item.bypassDomains) {
                issues.append("\(item.service) 绕过列表")
            }
        }

        let expectedEnvironment = snapshot.launchdEnvironment ?? [:]
        for key in managedEnvKeys {
            let result = await CommandRunner.run("/bin/launchctl", ["getenv", key])
            let expected: String
            if let stored = expectedEnvironment[key], let value = stored {
                expected = value
            } else {
                expected = ""
            }
            if !result.succeeded || result.stdout != expected { issues.append("环境变量 \(key)") }
        }

        let paths = managedPaths()
        let guardPaths = Set([paths.plist, paths.guardScript])
        for file in snapshot.files where !guardPaths.contains(file.path) {
            if file.existed, let backupName = file.backupName {
                let expectedURL = URL(fileURLWithPath: "\(backupDir)/\(backupName)")
                let actualURL = URL(fileURLWithPath: file.path)
                guard
                    let expectedData = try? Data(contentsOf: expectedURL),
                    let actualData = try? Data(contentsOf: actualURL),
                    expectedData == actualData
                else {
                    issues.append("文件 \((file.path as NSString).lastPathComponent)")
                    continue
                }
            } else if FileManager.default.fileExists(atPath: file.path) {
                issues.append("文件 \((file.path as NSString).lastPathComponent)")
            }
        }

        for path in guardPaths where FileManager.default.fileExists(atPath: path) {
            issues.append("守护文件 \((path as NSString).lastPathComponent)")
        }
        if await isLaunchdGuardLoaded() { issues.append("launchd 守护任务") }
        if await isGuardScriptRunning(paths.guardScript) { issues.append("守护脚本进程") }
        return issues
    }

    private func restoreStartupSnapshot() async -> Bool? {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)),
            let snapshot = try? JSONDecoder().decode(RestoreSnapshot.self, from: data)
        else {
            return nil
        }

        let isCurrentSnapshot = snapshotIsUsable(at: snapshotPath)
        let isLegacySnapshot = legacySnapshotIsRestorable(snapshot)
        guard isCurrentSnapshot || isLegacySnapshot else {
            log("还原快照损坏或内容不完整，已改用受限清理模式", .warn)
            return nil
        }
        if isLegacySnapshot {
            log("检测到旧版完整快照，将恢复已保存内容并清理旧版未纳入快照的运行配置", .warn)
        }

        var restoreIssues: [String] = []
        for item in snapshot.networkServices {
            if !(await restoreEndpoint(item.web, service: item.service, setCommand: "-setwebproxy", stateCommand: "-setwebproxystate")) {
                restoreIssues.append("\(item.service) HTTP 代理写入")
            }
            if !(await restoreEndpoint(item.secureWeb, service: item.service, setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate")) {
                restoreIssues.append("\(item.service) HTTPS 代理写入")
            }
            if !(await restoreEndpoint(item.socks, service: item.service, setCommand: "-setsocksfirewallproxy", stateCommand: "-setsocksfirewallproxystate")) {
                restoreIssues.append("\(item.service) SOCKS 代理写入")
            }
            let bypassResult: CommandResult
            if item.bypassDomains.isEmpty {
                bypassResult = await CommandRunner.run("/usr/sbin/networksetup", ["-setproxybypassdomains", item.service, "Empty"])
            } else {
                bypassResult = await CommandRunner.run("/usr/sbin/networksetup", ["-setproxybypassdomains", item.service] + item.bypassDomains)
            }
            if !bypassResult.succeeded {
                restoreIssues.append("\(item.service) 绕过列表写入")
            }
        }
        restoreIssues.append(contentsOf: await restoreLaunchdEnvironment(snapshot))

        let paths = managedPaths()
        let guardPaths = Set([paths.plist, paths.guardScript])
        for file in snapshot.files where !guardPaths.contains(file.path) {
            let dir = (file.path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: file.path)
            if file.existed, let backupName = file.backupName {
                try? FileManager.default.copyItem(atPath: "\(backupDir)/\(backupName)", toPath: file.path)
            }
        }

        for path in guardPaths {
            try? FileManager.default.removeItem(atPath: path)
        }

        if isLegacySnapshot {
            let savedPaths = Set(snapshot.files.map(\.path))
            for path in paths.mergePaths where !savedPaths.contains(path) {
                if !cleanupManagedClashEntries(at: path) {
                    restoreIssues.append("文件 \((path as NSString).lastPathComponent) 清理")
                }
            }
        }

        let issues = restoreIssues + (await verifyRestoredSnapshot(snapshot))
        if !issues.isEmpty {
            log("启动前快照还原未通过校验: \(issues.joined(separator: "；"))", .error)
            log("还原快照已保留，可再次点击停止重试", .warn)
            return false
        }

        do {
            try FileManager.default.removeItem(atPath: backupDir)
        } catch {
            log("还原已通过校验，但快照清理失败: \(error.localizedDescription)", .error)
            return false
        }
        log("已按启动前快照恢复并逐项校验系统代理、环境变量和配置文件", .success)
        return true
    }

    private func cleanupManagedEnvironmentFile(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            let original = try String(contentsOfFile: path, encoding: .utf8)
            guard let cleaned = NetworkCompatibility.removingManagedEnvironmentBlocks(from: original) else {
                log("Codex 环境文件中的蝉舒宝标记不完整，已保留原文件", .error)
                return false
            }
            if cleaned != original {
                try cleaned.write(toFile: path, atomically: true, encoding: .utf8)
            }
            let verified = try String(contentsOfFile: path, encoding: .utf8)
            return verified == cleaned && !NetworkCompatibility.containsManagedEnvironmentMarker(verified)
        } catch {
            log("Codex 环境文件清理失败: \(error.localizedDescription)", .error)
            return false
        }
    }

    private func cleanupManagedClashEntries(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            let original = try String(contentsOfFile: path, encoding: .utf8)
            let cleaned = NetworkCompatibility.removingManagedClashEntries(
                from: original,
                companyDomains: companyDomains
            )
            if cleaned != original {
                try cleaned.write(toFile: path, atomically: true, encoding: .utf8)
            }
            let verified = try String(contentsOfFile: path, encoding: .utf8)
            return verified == cleaned && !NetworkCompatibility.containsManagedClashEntries(
                verified,
                companyDomains: companyDomains
            )
        } catch {
            log("Clash 配置清理失败（\((path as NSString).lastPathComponent)）: \(error.localizedDescription)", .error)
            return false
        }
    }

    private func cleanupAppOwnedMergeFile(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            let firstLine = content.components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard firstLine.hasPrefix("# 蝉舒宝") || firstLine.hasPrefix("# MergeSASE") else {
                return true
            }
            try FileManager.default.removeItem(atPath: path)
            return !FileManager.default.fileExists(atPath: path)
        } catch {
            log("Clash merge 配置清理失败: \(error.localizedDescription)", .error)
            return false
        }
    }

    private func guardManagedProxyEndpoint(at path: String) -> LocalProxyEndpoint? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var host: String?
        var port: Int?
        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n'\""))
            if key == "PROXY_HOST" || key == "CLASH_HOST" { host = value }
            if key == "PROXY_PORT" || key == "CLASH_PORT" { port = Int(value) }
        }
        guard let host, ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()),
              let port, (1...65535).contains(port)
        else {
            return nil
        }
        return LocalProxyEndpoint(host: host, port: port)
    }

    private func proxyEndpoint(_ snapshot: ProxyEndpointSnapshot, uses endpoint: LocalProxyEndpoint) -> Bool {
        snapshot.server.caseInsensitiveCompare(endpoint.host) == .orderedSame
            && snapshot.port == "\(endpoint.port)"
    }

    private func cleanupManagedConfigurationWithoutSnapshot(plistPath: String, guardScript: String) async -> Bool {
        var issues: [String] = []
        guard let managedEndpoint = guardManagedProxyEndpoint(at: guardScript) else {
            log("无法确认旧守护管理的代理端口，已保留现有网络设置和还原快照", .error)
            return false
        }
        let svcResult = await CommandRunner.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard svcResult.succeeded else {
            log("无法读取网络服务，清理式还原已中止", .error)
            return false
        }
        let services = svcResult.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        var proxyStatesToDisable: [(service: String, stateCommand: String, readCommand: String)] = []
        for service in services {
            let trimmed = service.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("An asterisk") || trimmed.hasPrefix("*") { continue }
            let commands = [
                (read: "-getwebproxy", state: "-setwebproxystate"),
                (read: "-getsecurewebproxy", state: "-setsecurewebproxystate"),
                (read: "-getsocksfirewallproxy", state: "-setsocksfirewallproxystate"),
            ]
            for command in commands {
                let result = await CommandRunner.run("/usr/sbin/networksetup", [command.read, trimmed])
                guard result.succeeded, let proxy = parseCompleteProxyEndpoint(result.stdout) else {
                    log("\(trimmed) 当前代理配置读取不完整，受限清理已中止", .error)
                    return false
                }
                if proxy.enabled, proxyEndpoint(proxy, uses: managedEndpoint) {
                    proxyStatesToDisable.append((trimmed, command.state, command.read))
                }
            }
        }
        for target in proxyStatesToDisable {
            let result = await CommandRunner.run("/usr/sbin/networksetup", [target.stateCommand, target.service, "off"])
            if !result.succeeded {
                issues.append("\(target.service) 系统代理关闭")
            }
        }
        systemProxyEnabled = false
        log("未找到可用启动前快照，仅关闭了与旧守护端口一致的系统代理", .warn)

        for key in managedEnvKeys {
            let result = await CommandRunner.run("/bin/launchctl", ["unsetenv", key])
            if !result.succeeded { issues.append("环境变量 \(key) 清理") }
        }
        appEnvFixed = false
        log("已清理 HTTP_PROXY/NO_PROXY 等应用环境变量", .info)

        _ = await CommandRunner.run("/usr/bin/defaults", ["delete", "\(homeDir)/Library/Preferences/com.google.Chrome.plist", "ProxySettings"])
        try? FileManager.default.removeItem(atPath: "\(homeDir)/Library/Application Support/Google/Chrome/Managed/com.google.Chrome.plist")
        chromePolicyInstalled = false
        log("Chrome 策略已移除", .success)

        let mergePaths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/merge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/merge.yaml",
        ]
        for path in mergePaths {
            if !cleanupAppOwnedMergeFile(at: path) {
                issues.append("Clash merge 配置")
            }
        }

        let codexEnvPath = "\(homeDir)/.codex/.env"
        if !cleanupManagedEnvironmentFile(at: codexEnvPath) {
            issues.append("Codex 环境文件")
        }

        let clashRuntimePaths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/dns_config.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge-check.yaml",
        ]
        for path in clashRuntimePaths where !cleanupManagedClashEntries(at: path) {
            issues.append("Clash 运行配置 \((path as NSString).lastPathComponent)")
        }

        for target in proxyStatesToDisable {
            let result = await CommandRunner.run("/usr/sbin/networksetup", [target.readCommand, target.service])
            guard result.succeeded, let proxy = parseCompleteProxyEndpoint(result.stdout) else {
                issues.append("\(target.service) 配置读取")
                continue
            }
            if proxy.enabled { issues.append("\(target.service) 系统代理") }
        }
        for key in managedEnvKeys {
            let result = await CommandRunner.run("/bin/launchctl", ["getenv", key])
            if !result.succeeded || !result.stdout.isEmpty {
                issues.append("环境变量 \(key)")
            }
        }
        let chromePreference = await CommandRunner.run("/usr/bin/defaults", [
            "read", "\(homeDir)/Library/Preferences/com.google.Chrome.plist", "ProxySettings"
        ])
        if chromePreference.succeeded { issues.append("Chrome 代理策略") }
        if FileManager.default.fileExists(atPath: "\(homeDir)/Library/Application Support/Google/Chrome/Managed/com.google.Chrome.plist") {
            issues.append("Chrome Managed 配置")
        }
        for path in mergePaths where FileManager.default.fileExists(atPath: path) {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let firstLine = content.components(separatedBy: .newlines)
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if firstLine.hasPrefix("# 蝉舒宝") || firstLine.hasPrefix("# MergeSASE") {
                    issues.append("Clash merge 配置")
                }
            } else {
                issues.append("Clash merge 配置读取")
            }
        }
        if FileManager.default.fileExists(atPath: codexEnvPath) {
            guard let content = try? String(contentsOfFile: codexEnvPath, encoding: .utf8) else {
                issues.append("Codex 环境文件读取")
                return false
            }
            if NetworkCompatibility.containsManagedEnvironmentMarker(content) {
                issues.append("Codex 环境文件")
            }
        }
        for path in clashRuntimePaths where FileManager.default.fileExists(atPath: path) {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                issues.append("Clash 运行配置读取")
                continue
            }
            if NetworkCompatibility.containsManagedClashEntries(content, companyDomains: companyDomains) {
                issues.append("Clash 运行配置 \((path as NSString).lastPathComponent)")
            }
        }
        if await isLaunchdGuardLoaded() { issues.append("launchd 守护任务") }
        if await isGuardScriptRunning(guardScript) { issues.append("守护脚本进程") }

        guardLoaded = await isLaunchdGuardLoaded()
        if !issues.isEmpty {
            log("清理式还原未通过校验: \(issues.joined(separator: "；"))", .error)
            return false
        }

        log("受管配置已清理并校验，守护元数据保留到清理事务提交", .info)
        log("清理式还原已逐项校验", .success)
        return true
    }

    private func removeGuardMetadataFiles(plistPath: String, guardScript: String) -> Bool {
        if FileManager.default.fileExists(atPath: plistPath) {
            do {
                try FileManager.default.removeItem(atPath: plistPath)
            } catch {
                log("launchd 配置文件清理失败，已保留守护脚本供再次重试", .error)
                return false
            }
        }
        if FileManager.default.fileExists(atPath: guardScript) {
            do {
                try FileManager.default.removeItem(atPath: guardScript)
            } catch {
                log("守护脚本清理失败，可再次点击停止重试", .error)
                return false
            }
        }
        if FileManager.default.fileExists(atPath: plistPath)
            || FileManager.default.fileExists(atPath: guardScript) {
            log("配置文件清理后仍有残留，可再次点击停止重试", .error)
            return false
        }
        log("配置文件已清理", .info)
        return true
    }

    private func restoreOrCleanupManagedConfiguration(plistPath: String, guardScript: String) async -> (restoredFromSnapshot: Bool, succeeded: Bool) {
        if let restored = await restoreStartupSnapshot() {
            return (true, restored)
        }
        let corruptSnapshotExists = FileManager.default.fileExists(atPath: snapshotPath)
        let cleaned = await cleanupManagedConfigurationWithoutSnapshot(plistPath: plistPath, guardScript: guardScript)
        guard cleaned else { return (false, false) }
        if corruptSnapshotExists {
            do {
                try FileManager.default.removeItem(atPath: backupDir)
                log("损坏的还原快照已在清理完成后移除", .info)
            } catch {
                log("配置已清理，但损坏快照无法移除；已保留守护脚本供再次重试: \(error.localizedDescription)", .error)
                return (false, false)
            }
        }
        let metadataRemoved = removeGuardMetadataFiles(plistPath: plistPath, guardScript: guardScript)
        return (false, metadataRemoved)
    }

    private func reloadClashViaAPI(
        address: String,
        secret: String,
        force: Bool,
        configPath: String? = nil
    ) async -> Bool {
        let payload: String
        if let configPath,
           let data = try? JSONSerialization.data(withJSONObject: ["path": configPath]),
           let json = String(data: data, encoding: .utf8) {
            payload = json
        } else {
            payload = "{}"
        }

        let suffix = force ? "/configs?force=true" : "/configs"
        var arguments = [
            "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "-X", "PUT", "http://\(address)\(suffix)",
            "-H", "Content-Type: application/json",
        ]
        if !secret.isEmpty {
            arguments.append(contentsOf: ["-H", "Authorization: Bearer \(secret)"])
        }
        arguments.append(contentsOf: ["-d", payload])
        let result = await CommandRunner.run("/usr/bin/curl", arguments)
        return result.succeeded && (result.stdout == "200" || result.stdout == "204")
    }

    private func reloadClashAfterRestore() async {
        let sighupRes = await CommandRunner.runShell("kill -HUP $(pgrep -f mihomo) 2>/dev/null")
        if sighupRes.succeeded {
            log("Clash 配置已重载（已恢复原始路由）", .success)
            return
        }

        var secret = ""
        let configPaths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml",
        ]
        for path in configPaths {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("secret:") {
                    secret = trimmed.replacingOccurrences(of: "secret:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "'", with: "")
                        .replacingOccurrences(of: "\"", with: "")
                }
            }
            break
        }
        if await reloadClashViaAPI(address: "127.0.0.1:9097", secret: secret, force: true) {
            log("Clash 配置已通过 API 重载", .success)
        } else {
            log("Clash 配置已恢复，但未确认热重载结果；下次启动 Clash 时会读取恢复后的配置", .warn)
        }
    }

    private func failStartAndRestore(_ reason: String) async {
        invalidateStatusRefreshes()
        log("启动失败: \(reason)", .error)
        phase = .stopping
        statusMessage = "启动失败，正在自动恢复…"

        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        let guardScript = "\(homeDir)/.local/bin/clash-proxy-guard.sh"
        guard await stopLaunchdGuard(plistPath: plistPath, guardScript: guardScript) else {
            startupFailureCleanupCompleted = false
            phase = .error
            statusMessage = "启动失败，守护未停止"
            log("========== 启动失败，守护仍在运行，未执行配置还原 ==========", .error)
            return
        }

        let restoreResult = await restoreOrCleanupManagedConfiguration(plistPath: plistPath, guardScript: guardScript)
        await reloadClashAfterRestore()
        await refreshStatus()
        startupFailureCleanupCompleted = restoreResult.succeeded && !guardLoaded
        if startupFailureCleanupCompleted {
            monitoredNetworkServices = []
            monitoredBypassDomains = []
            monitoredProxyEndpoint = nil
        }
        phase = .error
        if !restoreResult.succeeded || guardLoaded {
            statusMessage = "启动失败，还原未完成"
            log("========== 启动失败，还原未通过校验，可点击中止并还原重试 ==========", .error)
        } else if restoreResult.restoredFromSnapshot {
            statusMessage = "启动失败，已自动恢复"
            log("========== 启动失败，已自动恢复 ==========", .warn)
        } else {
            statusMessage = "启动失败，已清理配置"
            log("========== 启动失败，未找到快照，已执行清理式卸载 ==========", .warn)
        }
    }

    func addDomain(_ domain: String) {
        guard let trimmed = NetworkCompatibility.normalizedDomain(domain) else {
            statusMessage = "域名格式不正确"
            log("公司域名格式不正确，只能填写类似 example.com 的域名", .warn)
            return
        }
        guard !companyDomains.map(normalizedHost).contains(trimmed) else { return }
        companyDomains.append(trimmed)
    }

    func removeDomain(_ domain: String) {
        let trimmed = normalizedHost(domain)
        companyDomains.removeAll { normalizedHost($0) == trimmed }
    }

    func dismissSetupChecklist() {
        guard canPermanentlyDismissSetupChecklist else { return }
        setupChecklistDismissed = true
    }

    func showSetupChecklist() {
        setupChecklistDismissed = false
    }

    func updateAPIKey(_ value: String) {
        apiKeys = [value]
    }

    private var activeAPIKey: String? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scheduleDeveloperBalanceRefresh() {
        developerBalanceRefreshTask?.cancel()
        guard let activeAPIKey else {
            developerBalanceStatus = .unconfigured
            developerBalanceSummary = "未配置"
            syncDeveloperBalanceAutoRefreshLoop()
            return
        }

        syncDeveloperBalanceAutoRefreshLoop()
        developerBalanceRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await refreshDeveloperBalance(with: activeAPIKey)
        }
    }

    private func syncDeveloperBalanceAutoRefreshLoop() {
        developerBalanceAutoRefreshTask?.cancel()
        guard activeAPIKey != nil else {
            developerBalanceAutoRefreshTask = nil
            return
        }

        developerBalanceAutoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: developerBalanceAutoRefreshInterval)
                guard !Task.isCancelled, let currentAPIKey = activeAPIKey else { return }
                await refreshDeveloperBalance(with: currentAPIKey)
            }
        }
    }

    private func refreshDeveloperBalance(with apiKey: String) async {
        let requestToken = bearerToken(from: apiKey)
        guard !requestToken.isEmpty else {
            developerBalanceStatus = .unconfigured
            developerBalanceSummary = "未配置"
            return
        }

        let hasVisibleBalance = developerBalanceSummary.hasPrefix("$")
        developerBalanceStatus = .loading
        if !hasVisibleBalance {
            developerBalanceSummary = "查询中"
        }

        let result = await performDeveloperBalanceRequest(token: requestToken)
        guard requestToken == bearerToken(from: activeAPIKey ?? "") else { return }

        switch result {
        case .success(let data, let statusCode, let transport):
            guard statusCode != 401 && statusCode != 403 else {
                developerBalanceStatus = .unauthorized
                developerBalanceSummary = "Key 无效"
                log("余额查询鉴权失败: HTTP \(statusCode)\(developerBalanceMessageSuffix(data)) [\(transport)]", .warn)
                return
            }
            guard (200..<300).contains(statusCode) else {
                developerBalanceStatus = .error
                developerBalanceSummary = "查询失败"
                log("余额查询失败: HTTP \(statusCode)\(developerBalanceMessageSuffix(data)) [\(transport)]", .warn)
                return
            }

            if let amount = parseDeveloperBalanceAmount(data) {
                developerBalanceStatus = .ok
                developerBalanceSummary = "$\(String(format: "%.2f", amount))"
                log("余额查询成功 [\(transport)]", .success)
            } else {
                developerBalanceStatus = .error
                developerBalanceSummary = "解析失败"
                log("余额查询响应未识别余额字段\(developerBalanceTopLevelKeysSuffix(data))", .warn)
            }
        case .failure(let errorMessage):
            developerBalanceStatus = .error
            developerBalanceSummary = "查询失败"
            log("余额查询网络失败: \(errorMessage)", .warn)
        }
    }

    private enum DeveloperBalanceRequestResult {
        case success(data: Data, statusCode: Int, transport: String)
        case failure(String)
    }

    private func performDeveloperBalanceRequest(token: String) async -> DeveloperBalanceRequestResult {
        let host = proxyHost.isEmpty ? "127.0.0.1" : proxyHost
        var attempts: [(label: String, proxyURL: String?)] = []
        if externalProxyRunning || systemProxyEnabled {
            attempts.append(("代理 \(host):\(clashPort)", "http://\(host):\(clashPort)"))
        }
        attempts.append(("直接连接", nil))

        var lastError = ""
        var firstHTTPFailure: DeveloperBalanceRequestResult?
        for attempt in attempts {
            let result = await developerBalanceCurl(token: token, proxyURL: attempt.proxyURL)
            guard result.exitCode == 0 else {
                lastError = result.stderr.isEmpty ? "curl exit \(result.exitCode)" : result.stderr
                continue
            }

            let parts = result.stdout.components(separatedBy: "\n__MERGESASE_HTTP_CODE__:")
            guard parts.count >= 2,
                  let statusLine = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let statusCode = Int(statusLine)
            else {
                lastError = "余额接口响应缺少 HTTP 状态码"
                continue
            }

            let bodyText = parts.dropLast().joined(separator: "\n__MERGESASE_HTTP_CODE__:")
            let data = Data(bodyText.utf8)
            if !(200..<300).contains(statusCode) {
                if firstHTTPFailure == nil {
                    firstHTTPFailure = .success(data: data, statusCode: statusCode, transport: attempt.label)
                }
                continue
            }
            return .success(data: data, statusCode: statusCode, transport: attempt.label)
        }

        if let firstHTTPFailure {
            return firstHTTPFailure
        }
        return .failure(lastError.isEmpty ? "curl 未返回结果" : lastError)
    }

    private func developerBalanceCurl(token: String, proxyURL: String?) async -> CommandResult {
        var args = [
            "-u", "ALL_PROXY",
            "-u", "all_proxy",
            "-u", "HTTPS_PROXY",
            "-u", "https_proxy",
            "-u", "HTTP_PROXY",
            "-u", "http_proxy",
            "-u", "NO_PROXY",
            "-u", "no_proxy",
            "/usr/bin/curl",
            "-sS",
            "-L",
            "--connect-timeout", "8",
            "--max-time", "20",
            "-H", "Authorization: Bearer \(token)",
            "-H", "Accept: application/json",
            "-H", "User-Agent: ChanShuBao/1.0",
            "-w", "\n__MERGESASE_HTTP_CODE__:%{http_code}"
        ]
        if let proxyURL {
            args.append(contentsOf: ["--proxy", proxyURL])
        }
        args.append(developerBalanceAPIURL.absoluteString)
        return await CommandRunner.run("/usr/bin/env", args)
    }

    private func bearerToken(from value: String) -> String {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in token.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if trimmed.lowercased().hasPrefix("authorization:") {
                return bearerToken(from: trimmed)
            }
            if let bearerRange = trimmed.range(of: "bearer ", options: [.caseInsensitive]) {
                return bearerToken(from: String(trimmed[bearerRange.lowerBound...]))
            }
        }
        if token.lowercased().hasPrefix("authorization:") {
            token = String(token.dropFirst("authorization:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return token
    }

    private func parseDeveloperBalanceAmount(_ data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let preferredKeys = [
            "remaining_amount_usd",
            "display_remaining_quota",
            "current_balance",
            "remaining_balance",
            "available_balance",
            "remaining_quota",
            "remaining",
            "remain_quota",
            "quota_remaining",
            "available_quota",
            "token_balance",
            "balance_usd",
            "overflow_remaining_usd",
            "base_remaining_usd",
            "bonus_remaining_usd",
            "balance",
            "quota",
            "amount",
            "credit",
            "credits"
        ]

        for key in preferredKeys {
            if let amount = findNumber(forKey: key, in: object) {
                if key.contains("quota"), amount > 10_000 {
                    return amount / 500_000
                }
                return amount
            }
        }
        return nil
    }

    private func developerBalanceMessageSuffix(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = findString(forKeys: ["message", "msg", "error", "detail"], in: object),
              !message.isEmpty
        else {
            return ""
        }
        return "，\(message.prefix(120))"
    }

    private func developerBalanceTopLevelKeysSuffix(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let keys = object.keys.sorted().joined(separator: ", ")
        return keys.isEmpty ? "" : "，顶层字段: \(keys)"
    }

    private func findString(forKeys targetKeys: Set<String>, in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if targetKeys.contains(key.lowercased()) {
                    if let string = value as? String {
                        return string
                    }
                    if let number = value as? NSNumber {
                        return number.stringValue
                    }
                }
                if let found = findString(forKeys: targetKeys, in: value) {
                    return found
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findString(forKeys: targetKeys, in: value) {
                    return found
                }
            }
        }
        return nil
    }

    private func findNumber(forKey targetKey: String, in object: Any) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if key.lowercased() == targetKey, let number = numberValue(value) {
                    return number
                }
                if let number = findNumber(forKey: targetKey, in: value) {
                    return number
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let number = findNumber(forKey: targetKey, in: value) {
                    return number
                }
            }
        }
        return nil
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            let cleaned = string.replacingOccurrences(of: ",", with: "")
            if let match = cleaned.firstMatch(of: /[-+]?\d+(?:\.\d+)?/) {
                return Double(String(match.output))
            }
        }
        return nil
    }

    // MARK: - Port Detection

    private func detectClashPort() async -> Int {
        let configPaths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml",
            "\(homeDir)/.config/clash/config.yaml",
            "\(homeDir)/.config/mihomo/config.yaml",
        ]
        for path in configPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for pattern in ["mixed-port:", "mixed_port:"] {
                for line in content.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix(pattern) {
                        let num = trimmed.replacingOccurrences(of: pattern, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if let port = Int(num), port > 0, port < 65536 { return port }
                    }
                }
            }
        }
        let psRes = await CommandRunner.runShell("ps aux 2>/dev/null | grep -iE 'mihomo|clash' | grep -v grep | grep -o 'mixed-port[= ][0-9]\\+' | grep -o '[0-9]\\+' | head -1")
        if let port = Int(psRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 { return port }
        let lsofRes = await CommandRunner.runShell("lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | grep -iE 'mihomo|clash' | grep -o '127.0.0.1:[0-9]\\+' | cut -d: -f2 | head -1")
        if let port = Int(lsofRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 { return port }
        return 7897
    }

    private func proxyURL(for endpoint: LocalProxyEndpoint) -> String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        return "http://\(host):\(endpoint.port)"
    }

    private func proxyEndpointIsHealthy(_ endpoint: LocalProxyEndpoint) async -> Bool {
        let result = await CommandRunner.run("/usr/bin/env", [
            "-u", "ALL_PROXY", "-u", "all_proxy",
            "-u", "HTTPS_PROXY", "-u", "https_proxy",
            "-u", "HTTP_PROXY", "-u", "http_proxy",
            "-u", "NO_PROXY", "-u", "no_proxy",
            "/usr/bin/curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
            "--connect-timeout", "2", "--max-time", "4",
            "--proxy", proxyURL(for: endpoint),
            "https://www.gstatic.com/generate_204"
        ])
        return result.succeeded && result.stdout == "204"
    }

    private var configuredShadowrocketPort: Int? {
        let value = shadowrocketPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(value), (1...65535).contains(port) else { return nil }
        return port
    }

    private func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func listenerPIDs(onLoopbackPort port: Int) async -> Set<Int32> {
        let result = await CommandRunner.run("/usr/sbin/lsof", [
            "-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"
        ])
        guard result.succeeded else { return [] }

        var currentPID: Int32?
        var pids = Set<Int32>()
        let exactName = "n127.0.0.1:\(port)"
        let wildcardName = "n*:\(port)"
        for line in result.stdout.components(separatedBy: .newlines) {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
            } else if let currentPID,
                      line == exactName || line == wildcardName
                        || line.hasPrefix("\(exactName) ") || line.hasPrefix("\(wildcardName) ") {
                pids.insert(currentPID)
            }
        }
        return pids
    }

    private func shadowrocketOwnsListeningPort(_ port: Int) async -> Bool {
        let initialPIDs = await listenerPIDs(onLoopbackPort: port)
        for pid in initialPIDs {
            guard let path = executablePath(for: pid),
                  NetworkCompatibility.isShadowrocketExecutablePath(path)
            else {
                continue
            }
            let confirmedPIDs = await listenerPIDs(onLoopbackPort: port)
            if confirmedPIDs.contains(pid) { return true }
        }
        return false
    }

    private func shadowrocketDetection(connected: Bool) async -> ExternalProxyDetection {
        guard connected else {
            return ExternalProxyDetection(
                displayName: "Shadowrocket",
                detail: "未连接，请先在小火箭中连接",
                running: false,
                supportsClashConfig: false
            )
        }

        let manualValue = shadowrocketPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manualValue.isEmpty else {
            return ExternalProxyDetection(
                displayName: "Shadowrocket",
                detail: "请填写小火箭设置中的 Proxy Port",
                running: false,
                supportsClashConfig: false
            )
        }
        guard let configuredShadowrocketPort else {
            return ExternalProxyDetection(
                displayName: "Shadowrocket",
                detail: "代理端口格式不正确",
                running: false,
                supportsClashConfig: false
            )
        }
        guard await shadowrocketOwnsListeningPort(configuredShadowrocketPort) else {
            return ExternalProxyDetection(
                displayName: "Shadowrocket",
                detail: "该端口不是小火箭正在监听的 Proxy Port",
                port: configuredShadowrocketPort,
                running: false,
                supportsClashConfig: false
            )
        }
        let endpoint = LocalProxyEndpoint(host: "127.0.0.1", port: configuredShadowrocketPort)

        let healthy = await proxyEndpointIsHealthy(endpoint)
        return ExternalProxyDetection(
            displayName: "Shadowrocket",
            detail: healthy ? "已连接 · \(endpoint.host):\(endpoint.port)" : "已连接，但代理端口不可用",
            host: endpoint.host,
            port: endpoint.port,
            running: healthy,
            supportsClashConfig: false
        )
    }

    private func detectExternalProxyClient() async -> ExternalProxyDetection {
        let preference = externalProxyPreference
        let networkConnections = await CommandRunner.run("/usr/sbin/scutil", ["--nc", "list"])
        let shadowrocketConnected = networkConnections.succeeded
            && NetworkCompatibility.shadowrocketIsConnected(in: networkConnections.stdout)
        let clashDetectedPort = await detectClashPort()
        let clashRunningNow = await detectClashRunning(port: clashDetectedPort)
        let clashEndpoint = LocalProxyEndpoint(host: "127.0.0.1", port: clashDetectedPort)
        let clashHealthy = clashRunningNow ? await proxyEndpointIsHealthy(clashEndpoint) : false

        if preference == .shadowrocket {
            return await shadowrocketDetection(connected: shadowrocketConnected)
        }

        if preference == .clash {
            return ExternalProxyDetection(
                displayName: "Clash",
                detail: clashHealthy ? "已验证 · 127.0.0.1:\(clashDetectedPort)" : "进程或代理端口不可用",
                host: clashEndpoint.host,
                port: clashEndpoint.port,
                running: clashHealthy,
                supportsClashConfig: true
            )
        }

        if clashHealthy {
            return ExternalProxyDetection(
                displayName: "Clash",
                detail: "已验证 · 127.0.0.1:\(clashDetectedPort)",
                host: clashEndpoint.host,
                port: clashEndpoint.port,
                running: true,
                supportsClashConfig: true
            )
        }

        if shadowrocketConnected {
            return await shadowrocketDetection(connected: true)
        }

        return ExternalProxyDetection(
            displayName: "未检测",
            detail: "请先连接 Clash 或 Shadowrocket",
            running: false,
            supportsClashConfig: false
        )
    }

    private func writeMergeConfig(port: Int) async {
        let fakeIPFilterItems = companyDomains.flatMap { domain -> [String] in
            if domainHasProxyRequiredHost(domain) {
                return directCompanyHosts.filter { host($0, isUnder: domain) }
            }
            return ["+.\(normalizedHost(domain))"]
        }
        let fakeIPFilterYAML = fakeIPFilterItems.map { "    - '\($0)'" }.joined(separator: "\n")
        let nameserverPolicyYAML = companyDomains
            .map { "    '+.\(normalizedHost($0))': system" }
            .joined(separator: "\n")
        let mergeContent = """
        # 蝉舒宝 — Clash Verge Profile Enhancement
        profile:
          store-selected: true

        dns:
          use-system-hosts: false
          fake-ip-filter-mode: blacklist
          fake-ip-filter:
        \(fakeIPFilterYAML)
          nameserver-policy:
        \(nameserverPolicyYAML)
        """

        // Write to Clash Verge merge config locations
        let mergePaths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/merge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/merge.yaml",
        ]
        var written = false
        for path in mergePaths {
            let dir = (path as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: dir) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
                try? mergeContent.write(toFile: path, atomically: true, encoding: .utf8)
                log("Clash 合并配置已写入: \(path)", .success)
                written = true
            }
        }
        if !written {
            log("未找到 Clash Verge 配置目录，请手动将 Merge.yaml 导入 Clash Verge", .warn)
        }

        await patchClashDNSConfig()
        await patchGeneratedClashConfig()
        // Reload Clash config via API
        await reloadClashConfig(port: port, mergeConfigWritten: written)
    }

    private func patchClashDNSConfig() async {
        let path = "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/dns_config.yaml"
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let filters = companyDomains.map { "+.\(normalizedHost($0))" }
        let policyLines = companyDomains.map { "    '+.\(normalizedHost($0))': system" }

        func containsYAMLItem(_ item: String, in text: String) -> Bool {
            text.contains("- \(item)") || text.contains("- '\(item)'") || text.contains("- \"\(item)\"")
        }

        if content.contains("fake-ip-filter:") {
            let missing = filters.filter { !containsYAMLItem($0, in: content) }
            if !missing.isEmpty {
                let insertion = missing.map { "  - \($0)" }.joined(separator: "\n")
                content = content.replacingOccurrences(of: "  fake-ip-filter:\n", with: "  fake-ip-filter:\n\(insertion)\n")
            }
        }

        if content.contains("nameserver-policy: {}") {
            content = content.replacingOccurrences(
                of: "  nameserver-policy: {}",
                with: "  nameserver-policy:\n\(policyLines.joined(separator: "\n"))"
            )
        } else if content.contains("nameserver-policy:") {
            let missing = policyLines.filter { !content.contains($0) }
            if !missing.isEmpty {
                content = content.replacingOccurrences(of: "  nameserver-policy:\n", with: "  nameserver-policy:\n\(missing.joined(separator: "\n"))\n")
            }
        }

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            log("Clash DNS 配置已修复: 公司域名不再进入 fake-ip", .success)
        } catch {
            log("Clash DNS 配置修复失败: \(error.localizedDescription)", .warn)
        }
    }

    private func patchGeneratedClashConfig() async {
        let paths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge-check.yaml",
        ]
        let filters = companyDomains.map { "+.\(normalizedHost($0))" }
        let policyLines = companyDomains.map { "    '+.\(normalizedHost($0))': system" }
        let directRules = companyDomains.map { "- DOMAIN-SUFFIX,\(normalizedHost($0)),DIRECT" }
        let cidrRules = [
            "- IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "- IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "- IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "- IP-CIDR,197.19.0.0/16,DIRECT,no-resolve",
        ]

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let original = content

            if !content.contains("fake-ip-filter:") {
                let insertion = """
                  fake-ip-filter-mode: blacklist
                  fake-ip-filter:
                \(filters.map { "  - \($0)" }.joined(separator: "\n"))
                  nameserver-policy:
                \(policyLines.joined(separator: "\n"))
                """
                content = content.replacingOccurrences(of: "  fake-ip-range: 198.18.0.1/16\n", with: "  fake-ip-range: 198.18.0.1/16\n\(insertion)\n")
            } else {
                for filter in filters where !content.contains("- \(filter)") && !content.contains("- '\(filter)'") {
                    content = content.replacingOccurrences(of: "  fake-ip-filter:\n", with: "  fake-ip-filter:\n  - \(filter)\n")
                }
                if !content.contains("nameserver-policy:") {
                    content = content.replacingOccurrences(of: "  fake-ip-filter:\n", with: "  fake-ip-filter:\n")
                    if let range = content.range(of: "tun:\n") {
                        content.insert(contentsOf: "  nameserver-policy:\n\(policyLines.joined(separator: "\n"))\n", at: range.lowerBound)
                    }
                }
            }

            if content.contains("rules:\n") {
                let missingRules = (directRules + cidrRules).filter { !content.contains($0) }
                if !missingRules.isEmpty {
                    content = content.replacingOccurrences(of: "rules:\n", with: "rules:\n\(missingRules.joined(separator: "\n"))\n")
                }
            }

            if content != original {
                do {
                    try content.write(toFile: path, atomically: true, encoding: .utf8)
                    log("Clash 运行配置已修复: \((path as NSString).lastPathComponent)", .success)
                } catch {
                    log("Clash 运行配置写入失败: \(error.localizedDescription)", .warn)
                }
            }
        }
    }

    private func reloadClashConfig(port: Int, mergeConfigWritten: Bool) async {
        var reloaded = false

        // Method 1: SIGHUP to mihomo process
        let sighupRes = await CommandRunner.runShell("kill -HUP $(pgrep -f mihomo) 2>/dev/null")
        if sighupRes.succeeded {
            log("Clash 配置已重载 (SIGHUP)", .success)
            reloaded = true
        }

        // Method 2: API PUT /configs with path
        if !reloaded {
            let configPaths = [
                "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml",
                "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml",
            ]
            var apiAddr = "127.0.0.1:9097"
            var secret = ""
            var configPath = ""

            for path in configPaths {
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                configPath = path
                for line in content.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("external-controller:") {
                        apiAddr = trimmed.replacingOccurrences(of: "external-controller:", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                    }
                    if trimmed.hasPrefix("secret:") {
                        secret = trimmed.replacingOccurrences(of: "secret:", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                    }
                }
                break
            }

            log("正在通过 API 重载 Clash...", .info)

            if await reloadClashViaAPI(address: apiAddr, secret: secret, force: true, configPath: configPath) {
                log("Clash 配置已重载 (API)", .success)
                reloaded = true
            } else if await reloadClashViaAPI(address: apiAddr, secret: secret, force: false) {
                log("Clash 配置已重载 (API)", .success)
                reloaded = true
            }
        }

        if !reloaded {
            if mergeConfigWritten {
                log("Clash 合并配置已写入；未确认热重载结果，Clash Verge 会自动读取 merge 配置，无需手动重载", .info)
            } else {
                log("未找到 Clash Verge merge 配置目录，请手动将 Merge.yaml 导入 Clash Verge", .warn)
            }
        }

        // Small delay for config to take effect
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: - Start

    func start() async {
        invalidateStatusRefreshes()
        guard phase != .starting, phase != .stopping else { return }
        guard !guardNeedsStopping else {
            statusMessage = "请先停止并恢复现有守护"
            log("已有网络守护或还原快照，本次未重复启动", .warn)
            return
        }
        startupFailureCleanupCompleted = false
        phase = .starting
        statusMessage = "启动中…"
        log("========== 开始启动 ==========")

        let existingPaths = managedPaths()
        let liveGuardLoaded = await isLaunchdGuardLoaded()
        let liveGuardScriptRunning = await isGuardScriptRunning(existingPaths.guardScript)
        guard phase == .starting else { return }
        if liveGuardLoaded || liveGuardScriptRunning {
            guardLoaded = liveGuardLoaded
            phase = .idle
            statusMessage = "请先停止并恢复现有守护"
            log("检测到仍在运行的旧网络守护，本次未创建新快照", .warn)
            return
        }

        let validDomains = companyDomains.compactMap(NetworkCompatibility.normalizedDomain)
        guard !validDomains.isEmpty, validDomains.count == companyDomains.count else {
            phase = .idle
            statusMessage = "请检查公司域名"
            log("启动中止：公司域名为空或格式不正确，未修改网络", .error)
            return
        }

        let vpn = await detectCompanyVPNClient()
        vpnClientName = vpn.displayName
        vpnClientDetail = vpn.detail
        vpnClientRunning = vpn.running
        guard vpn.running else {
            phase = .idle
            statusMessage = "请先连接公司 VPN"
            log("启动中止：未确认公司 VPN 已连接，未修改网络", .error)
            return
        }
        log("检测到公司 VPN: \(vpn.displayName)（\(vpn.detail)）", .success)

        let externalProxy = await detectExternalProxyClient()
        proxyHost = externalProxy.host
        clashPort = externalProxy.port
        clashRunning = externalProxy.running
        externalProxyName = externalProxy.displayName
        externalProxyDetail = externalProxy.detail
        externalProxyRunning = externalProxy.running
        externalProxySupportsClashConfig = externalProxy.supportsClashConfig
        guard externalProxy.running else {
            phase = .idle
            statusMessage = externalProxy.detail
            log("启动中止：外网代理未通过连接和请求验证，未修改网络", .error)
            return
        }
        log("外网代理已验证: \(externalProxy.displayName) \(externalProxy.detail)", .success)

        let activeServices = await activePhysicalNetworkServices()
        guard !activeServices.isEmpty else {
            phase = .idle
            statusMessage = "未找到活动网络"
            log("启动中止：未找到正在使用的 Wi-Fi 或有线网络，未修改网络", .error)
            return
        }
        log("仅配置活动网络服务: \(activeServices.joined(separator: ", "))", .info)

        let startupNameservers = await systemNameservers()
        let guardBypassItems = await managedBypassItems(nameservers: startupNameservers)
        let managedRuntime = ManagedRuntimeSnapshot(
            networkServices: activeServices,
            bypassDomains: guardBypassItems,
            proxyHost: externalProxy.host,
            proxyPort: externalProxy.port
        )
        guard await takeRestoreSnapshotIfNeeded(for: activeServices, managedRuntime: managedRuntime) else {
            phase = .idle
            statusMessage = "启动失败：无法保存还原点"
            log("========== 启动中止：没有可靠还原点 ==========", .error)
            return
        }

        if externalProxy.supportsClashConfig {
            await writeMergeConfig(port: externalProxy.port)
        } else {
            log("Shadowrocket 兼容模式：不会修改小火箭 TUN；最终以内网和外网实测结果为准", .warn)
        }

        // Generate guard script — include resolved IP ranges
        let guardDir = "\(homeDir)/.local/bin"
        let guardScript = "\(guardDir)/clash-proxy-guard.sh"
        try? FileManager.default.createDirectory(atPath: guardDir, withIntermediateDirectories: true, attributes: nil)

        let guardBypassStr = guardBypassItems.map(shellQuoted).joined(separator: " ")
        let serviceLines = activeServices.map { "  \(shellQuoted($0))" }.joined(separator: "\n")
        let guardEndpoint = LocalProxyEndpoint(host: externalProxy.host, port: externalProxy.port)
        let guardContent = """
        #!/bin/bash
        PROXY_HOST=\(shellQuoted(externalProxy.host))
        PROXY_PORT=\(externalProxy.port)
        PROXY_URL=\(shellQuoted(proxyURL(for: guardEndpoint)))
        NETWORK_SERVICES=(
        \(serviceLines)
        )
        BYPASS=(\(guardBypassStr))
        STATUS=$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 \
          --proxy "$PROXY_URL" https://www.gstatic.com/generate_204) || exit 1
        [ "$STATUS" = "204" ] || exit 1
        for service in "${NETWORK_SERVICES[@]}"; do
            /usr/sbin/networksetup -setwebproxy "$service" "$PROXY_HOST" "$PROXY_PORT" >/dev/null || exit 1
            /usr/sbin/networksetup -setsecurewebproxy "$service" "$PROXY_HOST" "$PROXY_PORT" >/dev/null || exit 1
            /usr/sbin/networksetup -setsocksfirewallproxy "$service" "$PROXY_HOST" "$PROXY_PORT" >/dev/null || exit 1
            /usr/sbin/networksetup -setwebproxystate "$service" on >/dev/null || exit 1
            /usr/sbin/networksetup -setsecurewebproxystate "$service" on >/dev/null || exit 1
            /usr/sbin/networksetup -setsocksfirewallproxystate "$service" on >/dev/null || exit 1
            /usr/sbin/networksetup -setproxybypassdomains "$service" "${BYPASS[@]}" >/dev/null || exit 1
        done
        """
        do {
            try guardContent.write(toFile: guardScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guardScript)
            log("网络配置脚本已写入", .success)
        } catch {
            log("网络配置脚本写入失败: \(error.localizedDescription)", .error)
            await failStartAndRestore("网络配置脚本写入失败")
            return
        }

        // Write launchd plist
        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        try? FileManager.default.createDirectory(atPath: "\(homeDir)/Library/Logs", withIntermediateDirectories: true, attributes: nil)
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.clash.proxyguard</string>
            <key>ProgramArguments</key><array><string>\(guardScript)</string></array>
            <key>RunAtLoad</key><true/>
            <key>WatchPaths</key><array><string>/Library/Preferences/SystemConfiguration/preferences.plist</string></array>
            <key>ThrottleInterval</key><integer>2</integer>
            <key>StandardOutPath</key><string>\(homeDir)/Library/Logs/clash-proxy-guard.log</string>
            <key>StandardErrorPath</key><string>\(homeDir)/Library/Logs/clash-proxy-guard.log</string>
        </dict>
        </plist>
        """
        let canWriteLaunchAgent = await ensureLaunchAgentWritable(plistPath: plistPath)
        do {
            guard canWriteLaunchAgent else {
                throw CocoaError(.fileWriteNoPermission)
            }
            do {
                try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
            } catch {
                try plistContent.write(toFile: plistPath, atomically: false, encoding: .utf8)
            }
            log("launchd 配置已写入", .success)
        } catch {
            log("launchd 配置写入失败: \(error.localizedDescription)", .error)
            await failStartAndRestore("无法创建网络守护")
            return
        }

        // Set system proxy — include resolved IP ranges in bypass
        let bypassList = guardBypassItems
        let endpoint = LocalProxyEndpoint(host: externalProxy.host, port: externalProxy.port)
        guard await setLaunchdNoProxy(bypassList), await setLaunchdProxy(endpoint: endpoint) else {
            await failStartAndRestore("应用代理环境变量未生效")
            return
        }
        await writeAppEnvironment(endpoint: endpoint, bypassItems: bypassList)
        guard appEnvFixed else {
            await failStartAndRestore("Codex 代理环境未生效")
            return
        }
        if !proxyRequiredHosts.isEmpty {
            log("以下 API 域名将强制走外网代理，不写入绕过: \(proxyRequiredHosts.joined(separator: ", "))", .info)
        }

        guard await applySystemProxy(endpoint: endpoint, bypassDomains: bypassList, services: activeServices) else {
            await failStartAndRestore("系统代理写入或读回校验失败")
            return
        }
        monitoredNetworkServices = activeServices
        monitoredBypassDomains = bypassList
        monitoredProxyEndpoint = endpoint
        log("系统代理已设置并校验: \(externalProxy.host):\(externalProxy.port)", .success)

        // Write Chrome Managed Policy (forces proxy + bypass for all users)
        let chromeDomainBypassItems = companyDomains.flatMap { broadBypassItems(for: $0) }
        let chromeBypassItems: [String] = chromeDomainBypassItems + bypassList.filter { $0.contains("/") || $0 == "127.0.0.1" || $0 == "localhost" || $0 == "*.local" }
        let bypassStr = chromeBypassItems.joined(separator: ";")
        let chromePolicyXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ProxySettings</key>
            <dict>
                <key>ProxyMode</key>
                <string>fixed_servers</string>
                <key>ProxyServer</key>
                <string>\(externalProxy.host):\(externalProxy.port)</string>
                <key>ProxyBypassList</key>
                <string>\(bypassStr)</string>
            </dict>
        </dict>
        </plist>
        """

        // Path 1: Chrome Managed Policy (user-level, Chrome 89+)
        let managedDir = "\(homeDir)/Library/Application Support/Google/Chrome/Managed"
        do {
            try FileManager.default.createDirectory(atPath: managedDir, withIntermediateDirectories: true, attributes: nil)
            try chromePolicyXML.write(toFile: "\(managedDir)/com.google.Chrome.plist", atomically: true, encoding: .utf8)
            let defaultsResult = await CommandRunner.run("/usr/bin/defaults", [
                "write", "\(homeDir)/Library/Preferences/com.google.Chrome.plist", "ProxySettings",
                "-dict", "ProxyMode", "fixed_servers", "ProxyServer", "\(externalProxy.host):\(externalProxy.port)", "ProxyBypassList", bypassStr
            ])
            guard defaultsResult.succeeded else { throw CocoaError(.fileWriteNoPermission) }
            let verify = await CommandRunner.run("/usr/bin/defaults", [
                "read", "\(homeDir)/Library/Preferences/com.google.Chrome.plist", "ProxySettings"
            ])
            guard verify.succeeded, verify.stdout.contains("\(externalProxy.host):\(externalProxy.port)") else {
                throw CocoaError(.fileWriteUnknown)
            }
            chromePolicyInstalled = true
        } catch {
            chromePolicyInstalled = false
            log("Chrome 策略写入或读回失败: \(error.localizedDescription)", .error)
            await failStartAndRestore("Chrome 策略未生效")
            return
        }
        log("Chrome 策略已配置", .success)
        suggestBrowserAction("Chrome 策略已配置，建议手动重启 Chrome 后生效。")
        log("未自动重启 Chrome；如需让 Chrome 立即套用新策略，请手动重启 Chrome", .info)

        // Load launchd
        if FileManager.default.fileExists(atPath: plistPath) {
            guard await stopLaunchdGuard(plistPath: plistPath, guardScript: guardScript) else {
                await failStartAndRestore("旧网络守护无法停止")
                return
            }
            var loadRes = await CommandRunner.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
            if !loadRes.succeeded {
                loadRes = await CommandRunner.run("/bin/launchctl", ["load", plistPath])
            }
            guardLoaded = await isLaunchdGuardLoaded()
            if guardLoaded {
                log("网络守护已启动（事件驱动，公司 VPN 清代理时 2 秒内恢复）", .success)
            } else {
                log("网络守护启动失败: \(loadRes.stderr.isEmpty ? "launchctl 未返回详细原因" : loadRes.stderr)", .warn)
                await failStartAndRestore("网络守护启动失败")
                return
            }
        }


        await refreshStatus()
        guard systemProxyEnabled, systemProxyMatchesExternal, guardLoaded, externalProxyRunning, appEnvFixed, chromePolicyInstalled else {
            await failStartAndRestore("配置写入后的状态校验失败")
            return
        }

        await checkInternalNetwork()
        await checkExternalNetwork()
        guard internalResult.accessible, externalResult.accessible else {
            let reason = internalResult.accessible ? "外网代理验证失败" : "公司内网验证失败"
            await failStartAndRestore(reason)
            return
        }

        phase = .running
        statusMessage = "运行中"
        log("========== 启动完成：内网与代理外网均已验证 ==========", .success)
    }

    // MARK: - Stop

    @discardableResult
    func stop() async -> Bool {
        guard !stopInProgress else {
            log("停止流程已在执行，本次忽略重复请求", .info)
            return false
        }
        stopInProgress = true
        defer { stopInProgress = false }
        invalidateStatusRefreshes()

        phase = .stopping
        statusMessage = "停止中…"
        log("========== 开始停止 ==========")

        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        let guardScript = "\(homeDir)/.local/bin/clash-proxy-guard.sh"

        guard await stopLaunchdGuard(plistPath: plistPath, guardScript: guardScript) else {
            startupFailureCleanupCompleted = false
            phase = .error
            statusMessage = "停止失败：守护仍在运行"
            log("========== 停止未完成：为避免守护覆盖原配置，本次未执行还原 ==========", .error)
            return false
        }

        var restoreSucceeded = true
        if startupFailureCleanupCompleted {
            log("启动失败时已自动还原/清理，本次跳过重复清理", .info)
        } else {
            let restoreResult = await restoreOrCleanupManagedConfiguration(plistPath: plistPath, guardScript: guardScript)
            restoreSucceeded = restoreResult.succeeded

            if externalProxySupportsClashConfig || externalProxyPreference != .shadowrocket {
                // Reload Clash config after restoring or removing merge config.
                await reloadClashAfterRestore()
            }
        }

        await refreshStatus()
        let guardStillStopped = await stopLaunchdGuard(plistPath: plistPath, guardScript: guardScript)
        invalidateStatusRefreshes()
        guard restoreSucceeded && guardStillStopped else {
            startupFailureCleanupCompleted = false
            phase = .error
            statusMessage = guardStillStopped ? "停止未完成：还原校验失败" : "停止失败：守护仍在运行"
            log("========== 停止未完成，可再次点击中止并还原重试 ==========", .error)
            return false
        }
        guardLoaded = false

        suggestBrowserAction("Chrome 配置已恢复，建议手动重启 Chrome 读取恢复后的设置。")
        log("未自动退出 Chrome；如 Chrome 仍沿用旧设置，请手动重启 Chrome", .info)

        startupFailureCleanupCompleted = false
        monitoredNetworkServices = []
        monitoredBypassDomains = []
        monitoredProxyEndpoint = nil
        phase = .idle
        statusMessage = "就绪"
        log("========== 停止完成：守护已移除，还原已校验 ==========", .success)
        return true
    }

    // MARK: - Retry

    func retry() async {
        log("========== 重试 ==========")
        guard await stop() else {
            log("停止或还原未完成，已取消重新启动", .error)
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await start()
    }

    // MARK: - Status Refresh

    func refreshStatus() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration

        async let proxyCheck = CommandRunner.runShell("scutil --proxy 2>/dev/null")
        async let guardCheck = CommandRunner.run("/bin/launchctl", ["print", guardLaunchdService])
        async let vpnCheck = detectCompanyVPNClient()
        async let externalProxyCheck = detectExternalProxyClient()
        let (proxy, guardChk, vpn, externalProxy) = await (proxyCheck, guardCheck, vpnCheck, externalProxyCheck)

        let actualHTTPProxy = NetworkCompatibility.parseSystemHTTPProxy(proxy.stdout)
        let actualHTTPSProxy = NetworkCompatibility.parseSystemHTTPSProxy(proxy.stdout)
        let actualSOCKSProxy = NetworkCompatibility.parseSystemSOCKSProxy(proxy.stdout)
        let expectedExternalEndpoint = LocalProxyEndpoint(host: externalProxy.host, port: externalProxy.port)
        let systemProxyEnabledValue = actualHTTPProxy != nil || actualHTTPSProxy != nil || actualSOCKSProxy != nil
        let systemProxyMatchesExternalValue = externalProxy.running
            && actualHTTPProxy == expectedExternalEndpoint
            && actualHTTPSProxy == expectedExternalEndpoint
            && actualSOCKSProxy == expectedExternalEndpoint
        let actualExceptions = Set(normalizedBypassDomains(NetworkCompatibility.systemProxyExceptions(proxy.stdout)))
        let requiredExceptions = Set(normalizedBypassDomains(requiredCompanyBypassItems))
        let systemProxyBypassValidValue = requiredExceptions.isSubset(of: actualExceptions)
        let guardLoadedValue = guardChk.succeeded

        let chromePlistPath = "\(homeDir)/Library/Preferences/com.google.Chrome.plist"
        let chromePolicyInstalledValue: Bool
        if FileManager.default.fileExists(atPath: chromePlistPath) {
            let readRes = await CommandRunner.run("/usr/bin/defaults", ["read", chromePlistPath, "ProxySettings"])
            chromePolicyInstalledValue = readRes.succeeded
                && readRes.stdout.contains("\(externalProxy.host):\(externalProxy.port)")
        } else {
            chromePolicyInstalledValue = false
        }

        let codexEnvPath = "\(homeDir)/.codex/.env"
        let appEnvFixedValue: Bool
        if let content = try? String(contentsOfFile: codexEnvPath, encoding: .utf8) {
            let expectedProxyURL = proxyURL(for: LocalProxyEndpoint(host: externalProxy.host, port: externalProxy.port))
            appEnvFixedValue = content.contains("export HTTP_PROXY=\(expectedProxyURL)")
                && companyDomains.compactMap(NetworkCompatibility.normalizedDomain).allSatisfy { content.contains($0) }
                && content.contains("unset ALL_PROXY")
                && content.contains("export no_proxy=")
                && !content.contains("export no_proxy=$NO_PROXY")
        } else {
            appEnvFixedValue = false
        }

        var persistedRuntime: ManagedRuntimeSnapshot?
        if guardLoadedValue,
           snapshotIsUsable(at: snapshotPath),
           let snapshotData = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)),
           let snapshot = try? JSONDecoder().decode(RestoreSnapshot.self, from: snapshotData) {
            persistedRuntime = snapshot.managedRuntime
        }

        guard generation == refreshGeneration else { return }

        systemProxyEnabled = systemProxyEnabledValue
        systemProxyMatchesExternal = systemProxyMatchesExternalValue
        systemProxyBypassValid = systemProxyBypassValidValue
        if let actualSystemEndpoint = actualHTTPProxy ?? actualHTTPSProxy ?? actualSOCKSProxy {
            clashPort = actualSystemEndpoint.port
            proxyHost = actualSystemEndpoint.host
        }
        guardLoaded = guardLoadedValue
        clashRunning = externalProxy.running
        externalProxyName = externalProxy.displayName
        externalProxyDetail = externalProxy.detail
        externalProxyRunning = externalProxy.running
        externalProxySupportsClashConfig = externalProxy.supportsClashConfig
        vpnClientName = vpn.displayName
        vpnClientDetail = vpn.detail
        vpnClientRunning = vpn.running
        chromePolicyInstalled = chromePolicyInstalledValue
        appEnvFixed = appEnvFixedValue

        if phase == .idle, let runtime = persistedRuntime {
            monitoredNetworkServices = runtime.networkServices
            monitoredBypassDomains = runtime.bypassDomains
            monitoredProxyEndpoint = LocalProxyEndpoint(host: runtime.proxyHost, port: runtime.proxyPort)
            phase = .running
            log("已接管上次运行中的网络守护并恢复断线监控", .info)
        }

        if phase == .running {
            var managedNetworkIsValid = await monitoredNetworkConfigurationIsValid()
            guard generation == refreshGeneration, phase == .running else { return }
            if !managedNetworkIsValid {
                // The launchd guard may still be repairing a VPN-triggered change.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if generation == refreshGeneration, phase == .running {
                    managedNetworkIsValid = await monitoredNetworkConfigurationIsValid()
                }
            }
            guard generation == refreshGeneration, phase == .running else { return }

            var interruption: String?
            if !vpn.running { interruption = "公司 VPN 已断开" }
            else if !externalProxy.running { interruption = "外网代理已断开" }
            else if !systemProxyEnabledValue { interruption = "系统代理已失效" }
            else if !systemProxyMatchesExternalValue { interruption = "系统代理端口已变化" }
            else if !systemProxyBypassValidValue { interruption = "公司网络绕过配置已变化" }
            else if !guardLoadedValue { interruption = "网络守护已停止" }
            else if !managedNetworkIsValid { interruption = "活动网络的代理或绕过配置已变化" }
            else if !appEnvFixedValue { interruption = "Codex 代理环境已变化" }
            else if !chromePolicyInstalledValue { interruption = "Chrome 代理策略已变化" }

            if let interruption {
                log("\(interruption)，正在自动恢复启动前配置", .error)
                await stop()
                if phase == .idle {
                    statusMessage = "连接中断，已恢复原配置"
                }
                return
            }
            statusMessage = "运行中"
        }
    }

    private func detectClashRunning(port: Int) async -> Bool {
        let processCheck = await CommandRunner.runShell(
            "pgrep -if 'verge-mihomo|mihomo|clash-verge-service|clash-verge|Clash Verge' >/dev/null && echo 1 || echo 0"
        )
        if processCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return true
        }

        let netstatCheck = await CommandRunner.runShell(
            "netstat -anv -p tcp 2>/dev/null | grep -E '127\\.0\\.0\\.1\\.\(port)( |$)|\\.\(port)[[:space:]]' | grep -qiE 'verge-mihomo|mihomo|clash|LISTEN|ESTABLISHED' && echo 1 || echo 0"
        )
        if netstatCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return true
        }

        let lsofCheck = await CommandRunner.runShell(
            "lsof -nP -iTCP:\(port) 2>/dev/null | grep -qiE 'verge|mihomo|clash|LISTEN|ESTABLISHED' && echo 1 || echo 0"
        )
        return lsofCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func specificCompanyRouteInterface(for ip: String) async -> String? {
        let shadowrocketStatus = await CommandRunner.run("/usr/sbin/scutil", ["--nc", "status", "Shadowrocket"])
        let excludedInterfaces = Set(
            [NetworkCompatibility.interfaceName(in: shadowrocketStatus.stdout)].compactMap { $0 }
        )
        async let routeCheck = CommandRunner.run("/sbin/route", ["-n", "get", ip])
        async let routingTableCheck = CommandRunner.run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let (route, routingTable) = await (routeCheck, routingTableCheck)
        guard route.succeeded, routingTable.succeeded else { return nil }
        return NetworkCompatibility.specificVirtualRouteInterface(
            for: ip,
            routeOutput: route.stdout,
            routingTableOutput: routingTable.stdout,
            excluding: excludedInterfaces
        )
    }

    private func companyRouteInterface() async -> String? {
        let nameservers = await systemNameservers()
        for domain in companyDomains.compactMap(NetworkCompatibility.normalizedDomain) {
            for prefix in ["", "new-api", "api", "www", "portal", "vpn"] {
                let host = prefix.isEmpty ? domain : "\(prefix).\(domain)"
                guard let ip = await resolveRealIPv4(host, nameservers: nameservers) else { continue }
                if let interface = await specificCompanyRouteInterface(for: ip) {
                    return interface
                }
            }
        }
        return nil
    }

    private func detectCompanyVPNClient() async -> VPNClientDetection {
        async let processCheck = CommandRunner.runShell(
            "ps ax -o command= 2>/dev/null | grep -Ei 'OpenVPN Connect|OpenVPN|openvpn|openvpn3|ovpnagent|SASE|sase|GlobalProtect|Zscaler|Netskope|Cisco AnyConnect|AnyConnect' | grep -vi 'MergeSASE' | grep -v grep | head -20"
        )
        async let connectionCheck = CommandRunner.run("/usr/sbin/scutil", ["--nc", "list"])
        let (process, connections) = await (processCheck, connectionCheck)
        let connectedNames = NetworkCompatibility.connectedVPNNames(in: connections.stdout)
        let lower = process.stdout.lowercased()
        var detectedClients: [String] = []
        if lower.contains("sase") { detectedClients.append("SASE") }
        if lower.contains("openvpn") || lower.contains("ovpnagent") { detectedClients.append("OpenVPN Connect") }
        if lower.contains("globalprotect") { detectedClients.append("GlobalProtect") }
        if lower.contains("zscaler") { detectedClients.append("Zscaler") }
        if lower.contains("netskope") { detectedClients.append("Netskope") }
        if lower.contains("anyconnect") { detectedClients.append("Cisco AnyConnect") }

        guard let routeInterface = await companyRouteInterface() else {
            let client = connectedNames.first ?? detectedClients.first ?? "公司 VPN"
            let detail = connectedNames.isEmpty && detectedClients.isEmpty ? "未检测到已连接的公司 VPN" : "客户端已打开，但未确认公司路由"
            return VPNClientDetection(displayName: client, detail: detail, running: false)
        }

        if let connectedName = connectedNames.first {
            return VPNClientDetection(displayName: connectedName, detail: "公司路由 \(routeInterface)", running: true)
        }
        guard !detectedClients.isEmpty else {
            return VPNClientDetection(displayName: "公司 VPN", detail: "发现 \(routeInterface)，但无法确认所属客户端", running: false)
        }
        let displayName = detectedClients.count == 1 ? detectedClients[0] : "公司 VPN"
        return VPNClientDetection(displayName: displayName, detail: "公司路由 \(routeInterface)", running: true)
    }

    // MARK: - Network Checks (detailed)

    func checkNetworksOnLaunch() async {
        guard !startupNetworkCheckCompleted else { return }
        startupNetworkCheckCompleted = true

        await refreshStatus()
        guard phase != .starting && phase != .stopping else { return }

        log("========== 打开软件后自动检测网络 ==========", .info)
        await checkAllNetworks()
    }

    func checkAllNetworks() async {
        guard !networkCheckInProgress else { return }
        networkCheckInProgress = true
        defer { networkCheckInProgress = false }

        await checkInternalNetwork()
        await checkExternalNetwork()
    }

    private func externalCurl(proxyURL: String?) async -> (code: String, latency: String, remoteIP: String, stderr: String) {
        var args = [
            "-u", "ALL_PROXY",
            "-u", "all_proxy",
            "-u", "HTTPS_PROXY",
            "-u", "https_proxy",
            "-u", "HTTP_PROXY",
            "-u", "http_proxy",
            "-u", "NO_PROXY",
            "-u", "no_proxy",
            "/usr/bin/curl",
            "-sS",
            "-o", "/dev/null",
            "-w", "%{http_code}|%{time_total}|%{remote_ip}",
            "--max-time", "8"
        ]
        if let proxyURL {
            args.append(contentsOf: ["--proxy", proxyURL])
        }
        args.append("https://www.google.com")

        let result = await CommandRunner.run("/usr/bin/env", args)
        let parts = result.stdout.components(separatedBy: "|")
        let code = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latency = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let remoteIP = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (code, latency, remoteIP, result.stderr)
    }

    private func externalCodeIsAccessible(_ code: String) -> Bool {
        ["200", "301", "302"].contains(code)
    }

    func checkExternalNetwork() async {
        await refreshStatus()
        let host = proxyHost.isEmpty ? "127.0.0.1" : proxyHost
        let proxyURL = "http://\(host):\(clashPort)"
        log("检测外部网络: google.com（通过 \(proxyURL)）...")
        externalResult.url = "https://www.google.com"

        let result = await externalCurl(proxyURL: proxyURL)

        externalResult.statusCode = result.code
        externalResult.accessible = externalCodeIsAccessible(result.code)

        if let ms = Double(result.latency) {
            externalResult.latencyMs = String(format: "%.0fms", ms * 1000)
        } else {
            externalResult.latencyMs = result.latency
        }

        if externalResult.accessible {
            log("外部网络可访问: google.com → HTTP \(result.code) (\(externalResult.latencyMs)) 出口IP: \(result.remoteIP) [代理 \(proxyURL)] ✓", .success)
        } else {
            let errorDetail = result.stderr.isEmpty ? "" : "，错误: \(result.stderr)"
            log("外部网络不可访问: HTTP \(result.code) (\(externalResult.latencyMs))\(errorDetail)", .error)
            // Add diagnostic for external failure
            let proxyCheck = await CommandRunner.runShell("scutil --proxy 2>/dev/null | grep -E 'HTTPEnable|HTTPProxy|HTTPPort'")
            if !proxyCheck.stdout.isEmpty {
                log("当前代理状态: \(proxyCheck.stdout.replacingOccurrences(of: "\n", with: " | "))", .info)
            }
        }
    }

    func checkInternalNetwork() async {
        guard let rawDomain = companyDomains.first,
              let domain = NetworkCompatibility.normalizedDomain(rawDomain)
        else {
            internalResult = NetworkCheckResult(accessible: false, url: "", ip: "", statusCode: "未配置", latencyMs: "")
            log("公司内网未检测: 公司域名为空或格式不正确", .warn)
            return
        }
        log("检测公司内网: \(domain)...", .info)
        internalResult.url = domain

        // Diagnostic: check active interfaces
        let ifconfigRes = await CommandRunner.runShell("ifconfig 2>/dev/null | grep -E '^utun[0-9]+:' | awk '{print $1}' | tr -d ':'")
        let utunIfs = ifconfigRes.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        if !utunIfs.isEmpty {
            log("活跃虚拟网卡: \(utunIfs.joined(separator: ", "))", .info)
        }

        let nameservers = await systemNameservers()
        let digRaw = await CommandRunner.run("/usr/bin/dig", ["+short", domain])
        let digClean = digRaw.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.hasPrefix(";;") && !$0.isEmpty } ?? ""
        internalResult.ip = digClean

        if isClashFakeIP(internalResult.ip) {
            log("DNS 解析: \(domain) → \(internalResult.ip)", .info)
            log("⚠️ 解析到 Clash fake-IP (\(internalResult.ip))，这不是公司内网真实 IP", .warn)
            if let realIP = await resolveRealIPv4(domain, nameservers: nameservers) {
                internalResult.ip = realIP
                log("系统 DNS 解析: \(domain) → \(realIP)", .success)
            } else {
                internalResult.ip = ""
                log("系统 DNS 暂未解析到 \(domain) 的真实内网 IP，尝试常见子域...", .warn)
            }
        }

        if !internalResult.ip.isEmpty {
            log("DNS 解析: \(domain) → \(internalResult.ip)", .info)

            // Route check for the resolved IP
            let routeRes = await CommandRunner.run("/sbin/route", ["-n", "get", internalResult.ip])
            if !routeRes.stdout.isEmpty {
                log("路由信息: \(routeRes.stdout.replacingOccurrences(of: "\n", with: " | "))", .info)
            }

        } else {
            log("根域 \(domain) 无 A 记录（常见于公司域名），尝试子域...", .info)

            // Diagnostics: check system DNS configuration
            let dnsCheck = await CommandRunner.runShell("scutil --dns 2>/dev/null | grep 'nameserver\\[' | head -5")
            if !dnsCheck.stdout.isEmpty {
                log("系统 DNS 服务器: \(dnsCheck.stdout.replacingOccurrences(of: "\n", with: ", "))", .info)
            }

            // Try full dig output to see what server responded
            let digFull = await CommandRunner.run("/usr/bin/dig", [domain])
            if !digFull.stdout.isEmpty {
                log("dig 详情: \(digFull.stdout.replacingOccurrences(of: "\n", with: " | ").prefix(300))", .info)
            }

            // Try common subdomains
            for sub in ["new-api", "www", "api", "portal", "vpn"] {
                let subDomain = "\(sub).\(domain)"
                if let subIP = await resolveRealIPv4(subDomain, nameservers: nameservers) {
                    log("发现子域解析: \(subDomain) → \(subIP)（根域 \(domain) 无 A 记录是正常的）", .info)
                    if internalResult.ip.isEmpty {
                        internalResult.ip = subIP
                        internalResult.url = subDomain
                    }
                    break
                }
            }
        }

        // HTTP/HTTPS connectivity (best-effort, failure doesn't mean network is down)
        let checkURL = internalResult.ip.isEmpty ? domain : internalResult.url
        var httpOK = false

        for scheme in ["https", "http"] {
            let curlResult = await CommandRunner.run("/usr/bin/env", [
                "-u", "ALL_PROXY", "-u", "all_proxy",
                "-u", "HTTPS_PROXY", "-u", "https_proxy",
                "-u", "HTTP_PROXY", "-u", "http_proxy",
                "-u", "NO_PROXY", "-u", "no_proxy",
                "/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}|%{time_total}",
                "--max-time", "4", "\(scheme)://\(checkURL)"
            ])
            let parts = curlResult.stdout.components(separatedBy: "|")
            let code = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let latency = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

            if !code.isEmpty && code != "000" && code != "timeout" {
                internalResult.statusCode = code
                internalResult.accessible = true
                if let ms = Double(latency) {
                    internalResult.latencyMs = String(format: "%.0fms", ms * 1000)
                }
                log("公司内网可访问: \(scheme)://\(checkURL) → HTTP \(code) (\(internalResult.latencyMs)) ✓", .success)
                httpOK = true
                break
            }
        }

        if httpOK {
            // all good, HTTP check passed
        } else if !internalResult.ip.isEmpty {
            // DNS resolved — check route to verify internal path
            let routeIface = await specificCompanyRouteInterface(for: internalResult.ip)

            if let routeIface, vpnClientRunning {
                internalResult.accessible = true
                internalResult.statusCode = "-"
                internalResult.latencyMs = "DNS ✓ 路由 \(routeIface)"
                log("公司内网可达: \(checkURL) → \(internalResult.ip)（DNS 已解析，路由走 \(routeIface)，HTTP 无响应为该 IP 无 Web 服务）", .success)
            } else {
                internalResult.accessible = false
                internalResult.statusCode = "不可达"
                internalResult.latencyMs = "路由异常"
                log("公司内网不通: \(checkURL) → \(internalResult.ip)（未确认公司 VPN 的专用路由，且服务无响应）", .error)
            }
        } else {
            internalResult.accessible = false
            internalResult.latencyMs = "无"
            internalResult.statusCode = "-"
            log("公司内网不可访问: \(domain) 及子域均无法解析，请确认 SASE 或 OpenVPN Connect 已连接", .error)
        }
    }
}
