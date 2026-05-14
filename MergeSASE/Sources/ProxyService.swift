import Foundation
import Observation

enum AppPhase: String { case idle, starting, running, stopping, error }

enum LogLevel { case info, success, warn, error }

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

enum DeveloperBalanceStatus {
    case unconfigured
    case loading
    case ok
    case unauthorized
    case error
}

struct BalanceField {
    let key: String
    let value: String
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
    var createdAt: Date
    var networkServices: [NetworkServiceSnapshot]
    var files: [FileSnapshot]
    var launchdEnvironment: [String: String?]?
}

@MainActor
@Observable
final class ProxyService {
    var phase: AppPhase = .idle
    var clashRunning = false
    var clashPort: Int = 7897
    var systemProxyEnabled = false
    var proxyHost: String = "127.0.0.1"
    var guardLoaded = false
    var chromePolicyInstalled = false
    var appEnvFixed = false
    var networkCheckInProgress = false
    var internalResult = NetworkCheckResult()
    var externalResult = NetworkCheckResult()
    var logs: [LogLine] = []
    var companyDomains: [String] {
        didSet { UserDefaults.standard.set(companyDomains, forKey: "companyDomains") }
    }
    var statusMessage: String = "就绪"
    var newDomain: String = ""
    var developerBaseAddress: String = "" {
        didSet { UserDefaults.standard.set(developerBaseAddress, forKey: developerBaseAddressKey) }
    }
    var developerCredential: String = ""
    var developerBalanceStatus: DeveloperBalanceStatus = .unconfigured
    var developerBalanceSummary: String = "未配置"
    var developerBalanceDetail: String = "配置开发者后台地址后即可授权登录"
    var developerBalanceLastChecked: Date?
    var developerBalanceFields: [BalanceField] = []
    var developerBalanceDeltaText: String = ""
    var developerBalanceAmount: Double?
    var developerRequestCount: Double?
    var developerAutoRefreshEnabled: Bool {
        didSet {
            UserDefaults.standard.set(developerAutoRefreshEnabled, forKey: "developerAutoRefreshEnabled")
            configureDeveloperAutoRefreshTimer()
        }
    }
    var menuBarBalanceTitle: String {
        switch developerBalanceStatus {
        case .ok:
            return developerBalanceSummary.isEmpty ? "余额" : developerBalanceSummary
        case .loading:
            return developerBalanceAmount.map { formatMenuBarBalance($0) } ?? "余额…"
        case .unauthorized:
            return developerBalanceAmount.map { formatMenuBarBalance($0) } ?? "请授权"
        case .error:
            return developerBalanceAmount.map { formatMenuBarBalance($0) } ?? "余额失败"
        case .unconfigured:
            return developerBalanceAmount.map { formatMenuBarBalance($0) } ?? (developerCredential.isEmpty ? "请授权" : "余额")
        }
    }
    var menuBarBalanceStatusText: String {
        switch developerBalanceStatus {
        case .ok:
            return developerBalanceLastChecked.map { "已更新 \(Self.shortTimeFormatter.string(from: $0))" } ?? "余额已刷新"
        case .loading:
            return "正在刷新余额"
        case .unauthorized:
            return "需要重新授权"
        case .error:
            return "刷新失败"
        case .unconfigured:
            return developerCredential.isEmpty ? "未配置登录态" : "已保存登录态，等待刷新"
        }
    }
    var menuBarBalanceSystemImage: String {
        switch developerBalanceStatus {
        case .ok:
            return "creditcard.fill"
        case .loading:
            return "arrow.clockwise"
        case .unauthorized:
            return "person.crop.circle.badge.exclamationmark"
        case .error:
            return "exclamationmark.triangle.fill"
        case .unconfigured:
            return "creditcard"
        }
    }
    var developerAddressDisplay: String {
        developerBaseAddress.isEmpty ? "未配置" : developerBaseAddress
    }
    var developerLoginURL: URL? {
        developerEndpointURL(path: "/auth/login")
    }
    var developerCookieHost: String? {
        developerBaseURL?.host
    }

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    private let developerBaseAddressKey = "developerBaseAddress"
    private let developerLastBalanceKey = "developerLastBalanceAmount"
    private let developerLastRequestCountKey = "developerLastRequestCount"
    private var backupDir: String { "\(homeDir)/Library/Application Support/MergeSASE/Backup" }
    private var snapshotPath: String { "\(backupDir)/snapshot.json" }
    private let managedProxyKeys = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"]
    private let managedAllProxyKeys = ["ALL_PROXY", "all_proxy"]
    private let managedNoProxyKeys = ["NO_PROXY", "no_proxy"]
    private var managedEnvKeys: [String] { managedProxyKeys + managedAllProxyKeys + managedNoProxyKeys }
    private let proxyRequiredHosts: [String] = []
    private var directCompanyHosts: [String] {
        var hosts = ["developer.company.internal", "api.company.internal"]
        if let host = developerCookieHost, !hosts.contains(host) {
            hosts.append(host)
        }
        return hosts
    }
    private var startupNetworkCheckCompleted = false
    private var developerAutoRefreshTimer: Timer?
    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "companyDomains") ?? []
        // Migrate from old default or bootstrap
        if saved.isEmpty {
            self.companyDomains = ["company.internal"]
            UserDefaults.standard.removeObject(forKey: "companyDomains") // let didSet write fresh value
        } else {
            self.companyDomains = saved
        }
        self.developerBaseAddress = UserDefaults.standard.string(forKey: developerBaseAddressKey) ?? ""
        if UserDefaults.standard.object(forKey: "developerAutoRefreshDefaultedV2") == nil {
            self.developerAutoRefreshEnabled = true
            UserDefaults.standard.set(true, forKey: "developerAutoRefreshDefaultedV2")
            UserDefaults.standard.set(true, forKey: "developerAutoRefreshEnabled")
        } else {
            self.developerAutoRefreshEnabled = UserDefaults.standard.bool(forKey: "developerAutoRefreshEnabled")
        }
        UserDefaults.standard.removeObject(forKey: developerLastBalanceKey)
        UserDefaults.standard.removeObject(forKey: developerLastRequestCountKey)
        configureDeveloperAutoRefreshTimer()
        Task {
            await refreshStatus()
        }
    }

    private func log(_ text: String, _ level: LogLevel = .info) {
        logs.append(LogLine(timestamp: Date(), text: text, level: level))
        if logs.count > 500 { logs.removeFirst(100) }
    }

    private func managedPaths() -> (plist: String, guardScript: String, mergePaths: [String], chromePaths: [String]) {
        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        let guardScript = "\(homeDir)/.local/bin/clash-proxy-guard.sh"
        let codexEnvPath = "\(homeDir)/.codex/.env"
        let mergePaths = [
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/merge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/merge.yaml",
            "\(homeDir)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/dns_config.yaml",
        ]
        let chromePaths = [
            "\(homeDir)/Library/Preferences/com.google.Chrome.plist",
            "\(homeDir)/Library/Application Support/Google/Chrome/Managed/com.google.Chrome.plist",
        ]
        return (plistPath, guardScript, mergePaths + [codexEnvPath], chromePaths)
    }

    private func parseProxyEndpoint(_ output: String) -> ProxyEndpointSnapshot {
        var enabled = false
        var server = ""
        var port = ""
        for line in output.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            if key == "Enabled" { enabled = value.lowercased().hasPrefix("yes") }
            if key == "Server" { server = value }
            if key == "Port" { port = value }
        }
        return ProxyEndpointSnapshot(enabled: enabled, server: server, port: port)
    }

    private func parseBypassDomains(_ output: String) -> [String] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("there aren't any") }
    }

    private func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "*.", with: "")
            .replacingOccurrences(of: "+.", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
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

    private func setLaunchdNoProxy(_ bypassItems: [String]) async {
        let value = noProxyItems(from: bypassItems).joined(separator: ",")
        for key in managedNoProxyKeys {
            _ = await CommandRunner.run("/bin/launchctl", ["setenv", key, value])
        }
        log("已设置应用环境 NO_PROXY/no_proxy（ccswitch 等非浏览器应用需重启后生效）", .success)
    }

    private func setLaunchdProxy(port: Int) async {
        let proxyURL = "http://127.0.0.1:\(port)"
        for key in managedProxyKeys {
            _ = await CommandRunner.run("/bin/launchctl", ["setenv", key, proxyURL])
        }
        for key in managedAllProxyKeys {
            _ = await CommandRunner.run("/bin/launchctl", ["unsetenv", key])
        }
        log("已设置应用环境 HTTP_PROXY/HTTPS_PROXY（ccswitch 等非浏览器应用需重启后生效）", .success)
        log("已清理应用环境 ALL_PROXY/all_proxy，避免强制兜底走 Clash", .success)
    }

    private func writeAppEnvironment(port: Int, bypassItems: [String]) async {
        let codexDir = "\(homeDir)/.codex"
        let codexEnvPath = "\(codexDir)/.env"
        let proxyURL = "http://127.0.0.1:\(port)"
        let noProxyValue = noProxyItems(from: bypassItems).joined(separator: ",")

        try? FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        let existing = (try? String(contentsOfFile: codexEnvPath, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var skippingManagedBlock = false

        for line in existing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# === MergeSASE managed proxy environment ===" {
                skippingManagedBlock = true
                continue
            }
            if trimmed == "# === End MergeSASE managed proxy environment ===" {
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

        # === MergeSASE managed proxy environment ===
        export HTTP_PROXY=\(proxyURL)
        export HTTPS_PROXY=\(proxyURL)
        # Public traffic can still use HTTP(S)_PROXY; company SASE traffic must bypass Clash.
        unset ALL_PROXY
        unset all_proxy
        export NO_PROXY=\(noProxyValue)
        export http_proxy=\(proxyURL)
        export https_proxy=\(proxyURL)
        export no_proxy=\(noProxyValue)
        # === End MergeSASE managed proxy environment ===
        """

        do {
            try (kept.joined(separator: "\n") + block + "\n").write(toFile: codexEnvPath, atomically: true, encoding: .utf8)
            appEnvFixed = true
            log("Codex/应用代理环境已修复: 公司域名与 SASE 网段直连，公网仍走 Clash", .success)
        } catch {
            appEnvFixed = false
            log("Codex/应用代理环境写入失败: \(error.localizedDescription)", .warn)
        }
    }

    private func restoreLaunchdEnvironment(_ snapshot: RestoreSnapshot) async {
        let launchdEnvironment = snapshot.launchdEnvironment ?? [:]
        for key in managedEnvKeys {
            if let stored = launchdEnvironment[key], let value = stored, !value.isEmpty {
                _ = await CommandRunner.run("/bin/launchctl", ["setenv", key, value])
            } else {
                _ = await CommandRunner.run("/bin/launchctl", ["unsetenv", key])
            }
        }
    }

    private func takeRestoreSnapshotIfNeeded() async {
        if FileManager.default.fileExists(atPath: snapshotPath) {
            log("已存在启动前快照，本次不覆盖", .info)
            return
        }

        try? FileManager.default.removeItem(atPath: backupDir)
        try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        let svcResult = await CommandRunner.runShell("networksetup -listallnetworkservices 2>/dev/null | tail -n +2")
        let services = svcResult.stdout.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }

        var networkSnapshots: [NetworkServiceSnapshot] = []
        for service in services {
            let web = await CommandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service])
            let secure = await CommandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])
            let socks = await CommandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])
            let bypass = await CommandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])
            networkSnapshots.append(NetworkServiceSnapshot(
                service: service,
                web: parseProxyEndpoint(web.stdout),
                secureWeb: parseProxyEndpoint(secure.stdout),
                socks: parseProxyEndpoint(socks.stdout),
                bypassDomains: parseBypassDomains(bypass.stdout)
            ))
        }

        let paths = managedPaths()
        let filePaths = paths.chromePaths + paths.mergePaths + [paths.plist, paths.guardScript]
        var fileSnapshots: [FileSnapshot] = []
        for (idx, path) in filePaths.enumerated() {
            if FileManager.default.fileExists(atPath: path) {
                let backupName = "file_\(idx)"
                try? FileManager.default.copyItem(atPath: path, toPath: "\(backupDir)/\(backupName)")
                fileSnapshots.append(FileSnapshot(path: path, existed: true, backupName: backupName))
            } else {
                fileSnapshots.append(FileSnapshot(path: path, existed: false, backupName: nil))
            }
        }

        var launchdEnvironment: [String: String?] = [:]
        for key in managedEnvKeys {
            let envRes = await CommandRunner.run("/bin/launchctl", ["getenv", key])
            launchdEnvironment[key] = envRes.succeeded && !envRes.stdout.isEmpty ? envRes.stdout : nil
        }

        let snapshot = RestoreSnapshot(
            createdAt: Date(),
            networkServices: networkSnapshots,
            files: fileSnapshots,
            launchdEnvironment: launchdEnvironment
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
            log("启动前配置快照已保存", .success)
        } else {
            log("启动前配置快照保存失败，停止时只能执行清理式还原", .warn)
        }
    }

    private func restoreEndpoint(_ endpoint: ProxyEndpointSnapshot, service: String, setCommand: String, stateCommand: String) async {
        if !endpoint.server.isEmpty, let port = Int(endpoint.port) {
            _ = await CommandRunner.run("/usr/sbin/networksetup", [setCommand, service, endpoint.server, "\(port)"])
        }
        _ = await CommandRunner.run("/usr/sbin/networksetup", [stateCommand, service, endpoint.enabled ? "on" : "off"])
    }

    private func restoreStartupSnapshot() async -> Bool {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)),
            let snapshot = try? JSONDecoder().decode(RestoreSnapshot.self, from: data)
        else {
            return false
        }

        for item in snapshot.networkServices {
            await restoreEndpoint(item.web, service: item.service, setCommand: "-setwebproxy", stateCommand: "-setwebproxystate")
            await restoreEndpoint(item.secureWeb, service: item.service, setCommand: "-setsecurewebproxy", stateCommand: "-setsecurewebproxystate")
            await restoreEndpoint(item.socks, service: item.service, setCommand: "-setsocksfirewallproxy", stateCommand: "-setsocksfirewallproxystate")
            if item.bypassDomains.isEmpty {
                _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setproxybypassdomains", item.service, "Empty"])
            } else {
                _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setproxybypassdomains", item.service] + item.bypassDomains)
            }
        }
        await restoreLaunchdEnvironment(snapshot)

        for file in snapshot.files {
            let dir = (file.path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(atPath: file.path)
            if file.existed, let backupName = file.backupName {
                try? FileManager.default.copyItem(atPath: "\(backupDir)/\(backupName)", toPath: file.path)
            }
        }

        try? FileManager.default.removeItem(atPath: backupDir)
        log("已按启动前快照恢复系统代理、Chrome、Clash 和守护配置", .success)
        return true
    }

    func addDomain(_ domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !companyDomains.contains(trimmed) else { return }
        companyDomains.append(trimmed)
    }

    func removeDomain(_ domain: String) {
        companyDomains.removeAll { $0 == domain }
        if companyDomains.isEmpty { companyDomains = ["company.internal"] }
    }

    // MARK: - Developer Balance

    func saveDeveloperCredential() {
        let value = developerCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        developerCredential = value
        if value.isEmpty {
            developerBalanceStatus = .unconfigured
            developerBalanceSummary = "未配置"
            developerBalanceDetail = "授权后即可读取开发者余额"
            developerBalanceFields = []
            developerBalanceDeltaText = ""
            developerBalanceAmount = nil
            developerRequestCount = nil
            UserDefaults.standard.removeObject(forKey: developerLastBalanceKey)
            UserDefaults.standard.removeObject(forKey: developerLastRequestCountKey)
            configureDeveloperAutoRefreshTimer()
            log("开发者余额登录态已清除", .info)
        } else {
            developerBalanceSummary = "已授权"
            developerBalanceDetail = "登录态仅在本次运行内保存，点击刷新读取当前额度"
            configureDeveloperAutoRefreshTimer()
            log("开发者余额登录态已临时保存", .success)
        }
    }

    @discardableResult
    func saveDeveloperBaseAddress(_ value: String) -> Bool {
        guard let normalized = normalizedDeveloperBaseAddress(value) else {
            developerBaseAddress = ""
            developerBalanceStatus = .unconfigured
            developerBalanceSummary = "填地址"
            developerBalanceDetail = "请先输入开发者后台地址"
            log("开发者后台地址未配置或无效", .warn)
            return false
        }
        developerBaseAddress = normalized
        developerBalanceDetail = developerCredential.isEmpty ? "已配置地址，下一步授权登录" : "本次运行已授权，点击刷新读取当前额度"
        log("开发者后台地址已保存: \(normalized)", .success)
        return true
    }

    func saveDeveloperCredential(_ value: String) {
        developerCredential = value
        saveDeveloperCredential()
    }

    func clearDeveloperCredential() {
        developerCredential = ""
        developerAutoRefreshEnabled = false
        saveDeveloperCredential()
    }

    private func configureDeveloperAutoRefreshTimer() {
        developerAutoRefreshTimer?.invalidate()
        developerAutoRefreshTimer = nil

        let credential = developerCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard developerAutoRefreshEnabled, !credential.isEmpty else { return }

        developerAutoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                await self.refreshDeveloperBalance()
            }
        }
    }

    func refreshDeveloperBalance() async {
        guard let developerBalanceURL = developerEndpointURL(path: "/api/user/developer-dashboard") else {
            developerBalanceStatus = .unconfigured
            developerBalanceSummary = "填地址"
            developerBalanceDetail = "请先输入开发者后台地址"
            developerBalanceDeltaText = ""
            log("开发者余额未配置后台地址", .warn)
            return
        }

        let credential = developerCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            developerBalanceStatus = .unconfigured
            developerBalanceSummary = "请授权"
            developerBalanceDetail = "授权后即可读取开发者余额"
            developerBalanceDeltaText = ""
            log("开发者余额未配置登录态", .warn)
            return
        }

        developerBalanceStatus = .loading
        developerBalanceSummary = "查询中…"
        developerBalanceDetail = "正在读取 /api/user/developer-dashboard"

        var request = URLRequest(url: developerBalanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(cookieHeader(from: credential), forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MergeSASE/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            developerBalanceLastChecked = Date()

            if statusCode == 401 || statusCode == 403 {
                developerBalanceStatus = .unauthorized
                developerBalanceSummary = "请授权"
                developerBalanceDetail = "登录态无效或已过期，请重新授权"
                developerBalanceFields = []
                log("开发者余额查询失败: 登录态无效或已过期", .warn)
                return
            }

            guard (200..<300).contains(statusCode) else {
                developerBalanceStatus = .error
                developerBalanceSummary = "HTTP \(statusCode)"
                developerBalanceDetail = compactResponseText(data)
                developerBalanceFields = []
                log("开发者余额查询失败: HTTP \(statusCode)", .error)
                return
            }

            var parsed = parseBalanceResponse(data)
            if let quotaBalance = await fetchDeveloperModelQuotaBalance(credential: credential) {
                parsed.summary = quotaBalance.display
                parsed.amount = quotaBalance.amount
                parsed.fields = parsed.fields.map { field in
                    field.key == "当前余额" ? BalanceField(key: field.key, value: quotaBalance.display) : field
                }
            }
            developerBalanceStatus = .ok
            developerBalanceSummary = parsed.summary
            developerBalanceDetail = parsed.detail
            developerBalanceFields = parsed.fields
            updateBalanceChange(newAmount: parsed.amount, requestCount: parsed.requestCount)
            log("开发者余额已刷新: \(parsed.summary)", .success)
        } catch {
            developerBalanceStatus = .error
            developerBalanceSummary = "查询失败"
            developerBalanceDetail = error.localizedDescription
            developerBalanceFields = []
            log("开发者余额查询失败: \(error.localizedDescription)", .error)
        }
    }

    private func updateBalanceChange(newAmount: Double?, requestCount: Double?) {
        if let newAmount {
            if let oldAmount = developerBalanceAmount {
                developerBalanceDeltaText = formatBalanceDelta(newAmount - oldAmount)
            } else {
                developerBalanceDeltaText = "相比上次 $0.00"
            }
            developerBalanceAmount = newAmount
            UserDefaults.standard.set(newAmount, forKey: developerLastBalanceKey)
        }

        if let requestCount {
            developerRequestCount = requestCount
            UserDefaults.standard.set(requestCount, forKey: developerLastRequestCountKey)
        }
    }

    private func cookieHeader(from value: String) -> String {
        if value.contains("=") || value.contains(";") {
            return value
        }
        return "session_id=\(value)"
    }

    private func fetchDeveloperModelQuotaBalance(credential: String) async -> (display: String, amount: Double)? {
        guard let modelQuotaURL = developerEndpointURL(path: "/api/user/self/model_quota") else {
            return nil
        }

        var request = URLRequest(url: modelQuotaURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(cookieHeader(from: credential), forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MergeSASE/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(statusCode) else { return nil }
            return parseModelQuotaBalance(data)
        } catch {
            return nil
        }
    }

    private var developerBaseURL: URL? {
        guard let normalized = normalizedDeveloperBaseAddress(developerBaseAddress) else { return nil }
        return URL(string: normalized)
    }

    private func developerEndpointURL(path: String) -> URL? {
        guard let baseURL = developerBaseURL else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return components?.url
    }

    private func normalizedDeveloperBaseAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            var components = URLComponents(string: withScheme),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            host != "developer.company.internal",
            host != "api.company.internal"
        else {
            return nil
        }
        components.scheme = components.scheme?.lowercased() ?? "https"
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func parseBalanceResponse(_ data: Data) -> (summary: String, detail: String, fields: [BalanceField], amount: Double?, requestCount: Double?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return ("已返回", compactResponseText(data), [], nil, nil)
        }

        if let dashboard = parseDashboardStats(object) {
            return dashboard
        }

        let flattened = flattenJSON(object)
        let matches = flattened
            .filter { isBalanceLikeKey($0.key) }
            .sorted { balanceKeyPriority($0.key) < balanceKeyPriority($1.key) }

        let fields = matches.prefix(6).map { BalanceField(key: $0.key, value: $0.value) }
        if let first = matches.first {
            let detail = fields.map { "\($0.key): \($0.value)" }.joined(separator: " · ")
            return (first.value, detail, fields, currencyAmount(from: first.value), nil)
        }

        if let detail = flattened.first(where: { $0.key.lowercased().hasSuffix("detail") })?.value {
            return ("已返回", detail, [], nil, nil)
        }

        return ("已返回", compactResponseText(data), [], nil, nil)
    }

    private func parseModelQuotaBalance(_ data: Data) -> (display: String, amount: Double)? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return nil
        }

        if
            let overview = root["monthly_overview"] as? [String: Any],
            let remainingQuota = numberValue(overview["display_remaining_quota"])
        {
            return (formatQuotaBalance(remainingQuota), remainingQuota / 500_000)
        }

        guard let groups = root["data"] as? [[String: Any]] else {
            return nil
        }
        let monthlyGroups = groups.filter {
            ($0["period"] as? String) == "monthly" && Int(numberValue($0["max_quota_type"]) ?? 0) == 0
        }
        guard !monthlyGroups.isEmpty else { return nil }

        let starGroups = monthlyGroups.filter {
            (($0["models"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "*"
        }
        let source = starGroups.isEmpty ? monthlyGroups : starGroups
        if source.contains(where: { (numberValue($0["max_quota"]) ?? 0) <= 0 }) {
            return ("不限", 0)
        }

        let remainingQuota = source.reduce(0) { partial, group in
            let maxQuota = max(0, numberValue(group["max_quota"]) ?? 0)
            let usedQuota = max(0, numberValue(group["used_quota"]) ?? 0)
            return partial + max(0, maxQuota - usedQuota)
        }
        return (formatQuotaBalance(remainingQuota), remainingQuota / 500_000)
    }

    private func parseDashboardStats(_ object: Any) -> (summary: String, detail: String, fields: [BalanceField], amount: Double?, requestCount: Double?)? {
        guard
            let root = object as? [String: Any],
            let data = root["data"] as? [String: Any],
            let cards = data["stats_cards"] as? [String: Any]
        else {
            return nil
        }

        let preferredKeys = [
            "current_balance",
            "historical_consumed",
            "request_count",
            "statistics_count",
            "statistics_quota",
            "statistics_tokens"
        ]
        var values: [String: BalanceField] = [:]
        var numericValues: [String: Double] = [:]

        for card in cards.values {
            guard
                let cardDict = card as? [String: Any],
                let items = cardDict["items"] as? [[String: Any]]
            else {
                continue
            }

            for item in items {
                guard let metricKey = item["key"] as? String else { continue }
                let label = item["label"] as? String ?? metricKey
                let display = item["display"] as? String
                    ?? (item["value_usd"] as? NSNumber)?.stringValue
                    ?? (item["value"] as? NSNumber)?.stringValue
                    ?? ""
                guard !display.isEmpty else { continue }
                values[metricKey] = BalanceField(key: label, value: display)
                if let value = item["value_usd"] as? NSNumber {
                    numericValues[metricKey] = value.doubleValue
                } else if let value = item["value"] as? NSNumber {
                    numericValues[metricKey] = value.doubleValue
                }
            }
        }

        let fields = preferredKeys.compactMap { values[$0] }
        guard let current = values["current_balance"], !fields.isEmpty else {
            return nil
        }

        let detail = fields
            .dropFirst()
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
        return (current.value, detail, fields, currencyAmount(from: current.value) ?? numericValues["current_balance"], numericValues["request_count"])
    }

    private func currencyAmount(from value: String) -> Double? {
        let cleaned = value.replacingOccurrences(of: ",", with: "")
        if let match = cleaned.firstMatch(of: /[-+]?\d+(?:\.\d+)?/) {
            return Double(String(match.output))
        }
        return nil
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private func formatCurrentBalance(_ value: Double) -> String {
        "$\(String(format: "%.2f", value))"
    }

    private func formatQuotaBalance(_ quota: Double) -> String {
        let value = quota / 500_000
        guard value.isFinite else { return "$0.00" }
        return "$\(String(format: "%.2f", value))"
    }

    private func formatMenuBarBalance(_ value: Double) -> String {
        formatCurrentBalance(value)
    }

    private func formatBalanceDelta(_ value: Double) -> String {
        let normalized = abs(value) < 0.005 ? 0 : value
        guard normalized != 0 else {
            return "相比上次 $0.00"
        }
        let sign = normalized > 0 ? "+" : "-"
        return "相比上次 \(sign)\(formatCurrentBalance(abs(normalized)))"
    }

    private func isBalanceLikeKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower.contains("model") || lower.contains("chart") || lower.contains("history") || lower.contains("log") {
            return false
        }
        return [
            "balance", "remain", "remaining", "quota", "credit", "amount",
            "available", "left", "surplus", "余额", "剩余", "额度"
        ].contains { lower.contains($0) }
    }

    private func balanceKeyPriority(_ key: String) -> Int {
        let lower = key.lowercased()
        let priorities = [
            "balance", "current_balance", "available_balance", "remaining_balance",
            "remain_quota", "remaining_quota", "available_quota", "current_quota",
            "remaining", "available", "left", "credit", "quota", "amount", "total"
        ]
        for (index, item) in priorities.enumerated() where lower.contains(item) {
            return index
        }
        return 100
    }

    private func flattenJSON(_ object: Any, prefix: String = "") -> [(key: String, value: String)] {
        if let dict = object as? [String: Any] {
            return dict.flatMap { key, value in
                flattenJSON(value, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }
        }
        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in
                flattenJSON(value, prefix: "\(prefix)[\(index)]")
            }
        }
        let value: String
        if object is NSNull {
            value = "null"
        } else if let number = object as? NSNumber {
            value = number.stringValue
        } else {
            value = "\(object)"
        }
        return [(prefix, value)]
    }

    private func compactResponseText(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(240))
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

    private func writeMergeConfig(port: Int) async {
        // Resolve company domains to find internal IP ranges
        var internalRanges = Set(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16", "198.18.0.0/16"])
        for domain in companyDomains {
            for prefix in ["", "new-api", "api", "www", "portal", "vpn"] {
                let host = prefix.isEmpty ? domain : "\(prefix).\(domain)"
                let digRes = await CommandRunner.runShell("dig +short \(host) 2>/dev/null | grep -v '^;;' | grep -E '^[0-9]' | head -1")
                let ip = digRes.stdout.trimmingCharacters(in: .whitespaces)
                if !ip.isEmpty {
                    let parts = ip.components(separatedBy: ".")
                    if parts.count == 4 {
                        internalRanges.insert("\(parts[0]).\(parts[1]).0.0/16")
                    }
                    log("检测到公司内网 IP: \(host) → \(ip) → 排除路由 \(parts[0]).\(parts[1]).0.0/16", .info)
                    break
                }
            }
        }

        let routeExcludeYAML = internalRanges.sorted().map { "          - '\($0)'" }.joined(separator: "\n")
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
        # MergeSASE — Clash Verge Profile Enhancement
        profile:
          store-selected: true

        dns:
          use-system-hosts: false
          fake-ip-filter-mode: blacklist
          fake-ip-filter:
        \(fakeIPFilterYAML)
          nameserver-policy:
        \(nameserverPolicyYAML)

        tun:
          enable: true
          stack: system
          route-exclude-address:
        \(routeExcludeYAML)
          route-exclude:
        \(routeExcludeYAML)
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
        await reloadClashConfig(port: port)
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
            "- IP-CIDR,198.18.0.0/16,DIRECT,no-resolve",
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

    private func reloadClashConfig(port: Int) async {
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
            var authPart = ""
            if !secret.isEmpty { authPart = "-H 'Authorization: Bearer \(secret)'" }

            // Try with path parameter
            let apiRes = await CommandRunner.runShell(
                "curl -s -o /dev/null -w '%{http_code}' -X PUT 'http://\(apiAddr)/configs?force=true' -H 'Content-Type: application/json' \(authPart) -d '{\"path\":\"\(configPath)\"}' 2>/dev/null"
            )
            if apiRes.stdout == "200" || apiRes.stdout == "204" {
                log("Clash 配置已重载 (API)", .success)
                reloaded = true
            } else {
                // Try without path
                let retryRes = await CommandRunner.runShell(
                    "curl -s -o /dev/null -w '%{http_code}' -X PUT 'http://\(apiAddr)/configs' -H 'Content-Type: application/json' \(authPart) -d '{}' 2>/dev/null"
                )
                if retryRes.stdout == "200" || retryRes.stdout == "204" {
                    log("Clash 配置已重载 (API)", .success)
                    reloaded = true
                }
            }
        }

        if !reloaded {
            log("请在 Clash Verge 中手动点击「重载配置」使 route-exclude 生效", .warn)
        }

        // Small delay for config to take effect
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: - Start

    func start() async {
        phase = .starting
        statusMessage = "启动中…"
        log("========== 开始启动 ==========")

        let port = await detectClashPort()
        clashPort = port
        log("检测到 Clash 端口: \(port)", .success)

        await takeRestoreSnapshotIfNeeded()

        // Write Clash merge config with route-exclude
        await writeMergeConfig(port: port)

        // Generate guard script — include resolved IP ranges
        let guardDir = "\(homeDir)/.local/bin"
        let guardScript = "\(guardDir)/clash-proxy-guard.sh"
        try? FileManager.default.createDirectory(atPath: guardDir, withIntermediateDirectories: true, attributes: nil)
        var guardBypassItems = ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16",
                                "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16", "198.18.0.0/16"]
        for domain in companyDomains {
            guardBypassItems.append(contentsOf: broadBypassItems(for: domain))
            let digRes = await CommandRunner.runShell("dig +short \(domain) 2>/dev/null | grep -v '^;;' | grep -E '^[0-9]' | head -1")
            let ip = digRes.stdout.trimmingCharacters(in: .whitespaces)
            if !ip.isEmpty {
                let parts = ip.components(separatedBy: ".")
                if parts.count == 4 {
                    guardBypassItems.append("\(parts[0]).\(parts[1]).0.0/16")
                }
            }
        }
        // Deduplicate
        var seenGuard = Set<String>()
        guardBypassItems = guardBypassItems.filter { seenGuard.insert($0).inserted }

        let guardBypassStr = guardBypassItems.map { "\"\($0)\"" }.joined(separator: " ")
        let domainLines = companyDomains.map { "    \"\($0)\"" }.joined(separator: "\n")
        let proxyRequiredLines = proxyRequiredHosts.map { "    \"\($0)\"" }.joined(separator: "\n")
        let guardContent = """
        #!/bin/bash
        CLASH_HOST="127.0.0.1"
        CLASH_PORT="\(port)"
        COMPANY_DOMAINS=(
        \(domainLines)
        )
        PROXY_REQUIRED_HOSTS=(
        \(proxyRequiredLines)
        )
        BYPASS=(\(guardBypassStr))
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            case "$service" in \\**) continue ;; esac
            networksetup -setwebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
            networksetup -setsecurewebproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
            networksetup -setsocksfirewallproxy "$service" "$CLASH_HOST" "$CLASH_PORT" 2>/dev/null || true
            networksetup -setproxybypassdomains "$service" "${BYPASS[@]}" 2>/dev/null || true
        done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
        """
        do {
            try guardContent.write(toFile: guardScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guardScript)
            log("守护脚本已写入", .success)
        } catch {
            log("守护脚本写入失败: \(error.localizedDescription)", .error)
            phase = .error; statusMessage = "守护脚本写入失败"; return
        }

        // Write launchd plist
        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        try? FileManager.default.createDirectory(atPath: "\(homeDir)/Library/LaunchAgents", withIntermediateDirectories: true, attributes: nil)
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
        do {
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)
            log("launchd 配置已写入", .success)
        } catch {
            log("launchd 配置写入失败: \(error.localizedDescription)", .error)
            phase = .error; statusMessage = "launchd 配置写入失败"; return
        }

        // Set system proxy — include resolved IP ranges in bypass
        var bypassList = ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16",
                          "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16", "198.18.0.0/16"]
        for domain in companyDomains {
            bypassList.append(contentsOf: broadBypassItems(for: domain))
            let digRes = await CommandRunner.runShell("dig +short \(domain) 2>/dev/null | grep -v '^;;' | grep -E '^[0-9]' | head -1")
            let ip = digRes.stdout.trimmingCharacters(in: .whitespaces)
            if !ip.isEmpty {
                let parts = ip.components(separatedBy: ".")
                if parts.count == 4 {
                    bypassList.append("\(parts[0]).\(parts[1]).0.0/16")
                }
            }
        }
        // Deduplicate while preserving order
        var seen = Set<String>()
        bypassList = bypassList.filter { seen.insert($0).inserted }
        await setLaunchdNoProxy(bypassList)
        await setLaunchdProxy(port: port)
        await writeAppEnvironment(port: port, bypassItems: bypassList)
        if !proxyRequiredHosts.isEmpty {
            log("以下 API 域名将强制走 Clash，不写入绕过: \(proxyRequiredHosts.joined(separator: ", "))", .info)
        }

        let svcResult = await CommandRunner.runShell("networksetup -listallnetworkservices 2>/dev/null | tail -n +2")
        let services = svcResult.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        for service in services {
            let trimmed = service.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("An asterisk") { continue }
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setwebproxy", trimmed, proxyHost, "\(port)"])
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxy", trimmed, proxyHost, "\(port)"])
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", trimmed, proxyHost, "\(port)"])
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setproxybypassdomains", trimmed] + bypassList)
        }
        log("系统代理已设置: \(proxyHost):\(port)", .success)

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
                <string>127.0.0.1:\(port)</string>
                <key>ProxyBypassList</key>
                <string>\(bypassStr)</string>
            </dict>
        </dict>
        </plist>
        """

        // Path 1: Chrome Managed Policy (user-level, Chrome 89+)
        let managedDir = "\(homeDir)/Library/Application Support/Google/Chrome/Managed"
        try? FileManager.default.createDirectory(atPath: managedDir, withIntermediateDirectories: true, attributes: nil)
        try? chromePolicyXML.write(toFile: "\(managedDir)/com.google.Chrome.plist", atomically: true, encoding: .utf8)

        // Path 2: Legacy preferences (older Chrome versions)
        _ = await CommandRunner.run("/usr/bin/defaults", [
            "write", "\(homeDir)/Library/Preferences/com.google.Chrome.plist", "ProxySettings",
            "-dict", "ProxyMode", "fixed_servers", "ProxyServer", "127.0.0.1:\(port)", "ProxyBypassList", bypassStr
        ])
        chromePolicyInstalled = true
        log("Chrome 策略已配置", .success)

        // Restart Chrome with proxy flags (only reliable way)
        _ = await CommandRunner.runShell("killall 'Google Chrome' 2>/dev/null")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await CommandRunner.run("/usr/bin/open", [
            "-a", "Google Chrome", "--args",
            "--proxy-server=http://127.0.0.1:\(port)",
            "--proxy-bypass-list=\(bypassStr)",
            "--disable-quic"
        ])
        log("Chrome 已重启（代理 + 内网绕过已生效）", .success)

        // Load launchd
        _ = await CommandRunner.run("/bin/launchctl", ["unload", plistPath])
        let loadRes = await CommandRunner.run("/bin/launchctl", ["load", plistPath])
        if loadRes.succeeded {
            log("守护已启动（事件驱动，SASE 清代理时 2 秒内恢复）", .success)
            guardLoaded = true
        } else {
            log("守护启动失败: \(loadRes.stderr)", .error)
            phase = .error; statusMessage = "守护启动失败"; return
        }


        await refreshStatus()
        phase = guardLoaded && systemProxyEnabled ? .running : .error
        statusMessage = phase == .running ? "运行中" : "部分异常"
        log("========== 启动完成 ==========", phase == .running ? .success : .warn)

        if phase == .running {
            await checkInternalNetwork()
            await checkExternalNetwork()
        }
    }

    // MARK: - Stop

    func stop() async {
        phase = .stopping
        statusMessage = "停止中…"
        log("========== 开始停止 ==========")

        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        let guardScript = "\(homeDir)/.local/bin/clash-proxy-guard.sh"

        // 1. Unload launchd guard
        _ = await CommandRunner.run("/bin/launchctl", ["unload", plistPath])
        guardLoaded = false
        log("守护已停止", .success)

        let restoredFromSnapshot = await restoreStartupSnapshot()

        if !restoredFromSnapshot {
            // 2. Fallback: turn off the proxy and remove files managed by MergeSASE.
            let svcResult = await CommandRunner.runShell("networksetup -listallnetworkservices 2>/dev/null | tail -n +2")
            let services = svcResult.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
            for service in services {
                let trimmed = service.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("An asterisk") { continue }
                _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setwebproxystate", trimmed, "off"])
                _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxystate", trimmed, "off"])
                _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", trimmed, "off"])
            }
            systemProxyEnabled = false
            log("未找到启动前快照，已执行清理式系统代理关闭", .warn)

            for key in managedEnvKeys {
                _ = await CommandRunner.run("/bin/launchctl", ["unsetenv", key])
            }
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
                if FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                    log("已清理 merge 配置: \((path as NSString).lastPathComponent)", .success)
                }
            }

            try? FileManager.default.removeItem(atPath: plistPath)
            try? FileManager.default.removeItem(atPath: guardScript)
            log("配置文件已清理", .info)
        }

        // Reload Clash config after restoring or removing merge config.
        let sighupRes = await CommandRunner.runShell("kill -HUP $(pgrep -f mihomo) 2>/dev/null")
        if sighupRes.succeeded {
            log("Clash 配置已重载（已恢复原始路由）", .success)
        } else {
            // Fallback to API reload
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
                            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
                    }
                }
                break
            }
            var authPart = ""
            if !secret.isEmpty { authPart = "-H 'Authorization: Bearer \(secret)'" }
            _ = await CommandRunner.runShell(
                "curl -s -o /dev/null -X PUT 'http://127.0.0.1:9097/configs?force=true' -H 'Content-Type: application/json' \(authPart) -d '{}' 2>/dev/null"
            )
            log("Clash 配置已通过 API 重载", .info)
        }

        // Kill Chrome so next launch no longer carries MergeSASE command-line flags.
        _ = await CommandRunner.runShell("killall 'Google Chrome' 2>/dev/null")
        log("Chrome 已退出（下次启动将不再使用代理）", .info)

        await refreshStatus()
        phase = .idle
        statusMessage = "就绪"
        log("========== 停止完成 ==========", .success)
    }

    // MARK: - Retry

    func retry() async {
        log("========== 重试 ==========")
        await stop()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await start()
    }

    // MARK: - Status Refresh

    func refreshStatus() async {
        async let proxyCheck = CommandRunner.runShell("scutil --proxy 2>/dev/null")
        async let guardCheck = CommandRunner.run("/bin/launchctl", ["list", "com.clash.proxyguard"])
        let (proxy, guardChk) = await (proxyCheck, guardCheck)

        systemProxyEnabled = proxy.stdout.contains("HTTPEnable : 1")
        if let range = proxy.stdout.range(of: "HTTPPort : ") {
            let portStr = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if let p = Int(portStr) { clashPort = p }
        }
        if let range = proxy.stdout.range(of: "HTTPProxy : ") {
            proxyHost = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "127.0.0.1"
        }
        guardLoaded = guardChk.exitCode == 0
        clashRunning = await detectClashRunning(port: clashPort)

        let chromePlistPath = "\(homeDir)/Library/Preferences/com.google.Chrome.plist"
        if FileManager.default.fileExists(atPath: chromePlistPath) {
            let readRes = await CommandRunner.run("/usr/bin/defaults", ["read", chromePlistPath, "ProxySettings"])
            chromePolicyInstalled = readRes.succeeded && !readRes.stdout.isEmpty
        } else {
            chromePolicyInstalled = false
        }

        let codexEnvPath = "\(homeDir)/.codex/.env"
        if let content = try? String(contentsOfFile: codexEnvPath, encoding: .utf8) {
            appEnvFixed = content.contains("limayao.com")
                && content.contains("197.19.0.0/16")
                && content.contains("unset ALL_PROXY")
                && content.contains("export no_proxy=")
                && !content.contains("export no_proxy=$NO_PROXY")
        } else {
            appEnvFixed = false
        }

        if phase == .running { statusMessage = "运行中" }
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

        var result = await externalCurl(proxyURL: proxyURL)
        var usedProxy = true
        if !externalCodeIsAccessible(result.code) {
            let directResult = await externalCurl(proxyURL: nil)
            if externalCodeIsAccessible(directResult.code) {
                result = directResult
                usedProxy = false
            }
        }

        externalResult.statusCode = result.code
        externalResult.accessible = externalCodeIsAccessible(result.code)

        if let ms = Double(result.latency) {
            externalResult.latencyMs = String(format: "%.0fms", ms * 1000)
        } else {
            externalResult.latencyMs = result.latency
        }

        if externalResult.accessible {
            let mode = usedProxy ? "代理 \(proxyURL)" : "直接连接"
            log("外部网络可访问: google.com → HTTP \(result.code) (\(externalResult.latencyMs)) 出口IP: \(result.remoteIP) [\(mode)] ✓", .success)
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
        guard let domain = companyDomains.first else { return }
        log("检测公司内网: \(domain)...", .info)
        internalResult.url = domain

        // Diagnostic: check active interfaces
        let ifconfigRes = await CommandRunner.runShell("ifconfig 2>/dev/null | grep -E '^utun[0-9]+:' | awk '{print $1}' | tr -d ':'")
        let utunIfs = ifconfigRes.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        if !utunIfs.isEmpty {
            log("活跃虚拟网卡: \(utunIfs.joined(separator: ", "))", .info)
        }

        // DNS resolve
        let digRaw = await CommandRunner.runShell("dig +short \(domain) 2>/dev/null")
        let digClean = digRaw.stdout.components(separatedBy: "\n")
            .filter { !$0.hasPrefix(";;") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .first ?? ""
        internalResult.ip = digClean.trimmingCharacters(in: .whitespaces)

        if !internalResult.ip.isEmpty {
            log("DNS 解析: \(domain) → \(internalResult.ip)", .info)

            // Route check for the resolved IP
            let routeRes = await CommandRunner.runShell("route -n get \(internalResult.ip) 2>/dev/null | grep -E 'interface:|destination:'")
            if !routeRes.stdout.isEmpty {
                log("路由信息: \(routeRes.stdout.replacingOccurrences(of: "\n", with: " | "))", .info)
            }

            // Warn if IP looks like a Clash fake-IP
            if internalResult.ip.hasPrefix("198.18.") {
                log("⚠️ 解析到 Clash fake-IP (\(internalResult.ip))，fake-ip-filter 可能未生效", .warn)
            }
        } else {
            log("根域 \(domain) 无 A 记录（常见于公司域名），尝试子域...", .info)

            // Diagnostics: check system DNS configuration
            let dnsCheck = await CommandRunner.runShell("scutil --dns 2>/dev/null | grep 'nameserver\\[' | head -5")
            if !dnsCheck.stdout.isEmpty {
                log("系统 DNS 服务器: \(dnsCheck.stdout.replacingOccurrences(of: "\n", with: ", "))", .info)
            }

            // Try full dig output to see what server responded
            let digFull = await CommandRunner.runShell("dig \(domain) 2>/dev/null | grep -E 'SERVER:|status:|ANSWER SECTION' -A2")
            if !digFull.stdout.isEmpty {
                log("dig 详情: \(digFull.stdout.replacingOccurrences(of: "\n", with: " | ").prefix(300))", .info)
            }

            // Try common subdomains
            for sub in ["new-api", "www", "api", "portal", "vpn"] {
                let subDomain = "\(sub).\(domain)"
                let subDig = await CommandRunner.runShell("dig +short \(subDomain) 2>/dev/null | grep -v '^;;' | grep -E '^[0-9]' | head -1")
                let subIP = subDig.stdout.trimmingCharacters(in: .whitespaces)
                if !subIP.isEmpty {
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
            let curlResult = await CommandRunner.runShell(
                "curl -s -o /dev/null -w '%{http_code}|%{time_total}' --max-time 4 \(scheme)://\(checkURL) 2>&1"
            )
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
            let routeRes = await CommandRunner.runShell("route -n get \(internalResult.ip) 2>/dev/null | grep 'interface:'")
            let routeIface = routeRes.stdout.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            let isInternalRoute = routeIface.hasPrefix("utun") || routeIface.hasPrefix("en")

            if isInternalRoute {
                internalResult.accessible = true
                internalResult.statusCode = "-"
                internalResult.latencyMs = "DNS ✓ 路由 \(routeIface)"
                log("公司内网可达: \(checkURL) → \(internalResult.ip)（DNS 已解析，路由走 \(routeIface)，HTTP 无响应为该 IP 无 Web 服务）", .success)
            } else {
                internalResult.accessible = false
                internalResult.statusCode = "不可达"
                internalResult.latencyMs = "路由异常"
                log("公司内网不通: \(checkURL) → \(internalResult.ip)，路由接口: \(routeIface)（预期 utun6）", .error)
            }
        } else {
            internalResult.accessible = false
            internalResult.latencyMs = "无"
            internalResult.statusCode = "-"
            log("公司内网不可访问: \(domain) 及子域均无法解析，请确认 SASE 已连接", .error)
        }
    }
}
