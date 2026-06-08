import Foundation
import Combine

enum AppPhase: String { case idle, starting, running, stopping, error }

enum LogLevel { case info, success, warn, error }

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
    var createdAt: Date
    var networkServices: [NetworkServiceSnapshot]
    var files: [FileSnapshot]
    var launchdEnvironment: [String: String?]?
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
    @Published var proxyHost: String = "127.0.0.1"
    @Published var externalProxyPreference: ExternalProxyPreference {
        didSet { UserDefaults.standard.set(externalProxyPreference.rawValue, forKey: "externalProxyPreference") }
    }
    @Published var externalProxyName = "未检测"
    @Published var externalProxyDetail = "请选择 Clash 或 Shadowrocket"
    @Published var externalProxyRunning = false
    @Published var externalProxySupportsClashConfig = false
    @Published var vpnClientName = "未检测"
    @Published var vpnClientDetail = "请先连接 SASE 或 OpenVPN Connect"
    @Published var vpnClientRunning = false
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
            UserDefaults.standard.set(apiKeys, forKey: "apiKeys")
            scheduleDeveloperBalanceRefresh()
        }
    }
    @Published var developerBalanceStatus: DeveloperBalanceStatus = .unconfigured
    @Published var developerBalanceSummary: String = "未配置"
    var menuBarTitle: String {
        developerBalanceSummary
    }
    var menuBarStatusText: String {
        guardEffectivelyRunning ? "代理守护已运行" : "代理守护未启动"
    }
    var menuBarSystemImage: String {
        guardEffectivelyRunning ? "shield.checkered" : "shield"
    }
    var guardEffectivelyRunning: Bool {
        vpnClientRunning
            && externalProxyRunning
            && systemProxyEnabled
            && guardLoaded
            && appEnvFixed
            && chromePolicyInstalled
    }
    var hasConfiguredCompanyDomain: Bool {
        companyDomains.contains { domain in
            let normalized = normalizedHost(domain)
            return !normalized.isEmpty && normalized != "company.internal"
        }
    }
    var hasConfiguredAPIKey: Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    var isSetupChecklistComplete: Bool {
        hasConfiguredCompanyDomain && hasConfiguredAPIKey
    }
    var shouldShowSetupChecklist: Bool {
        !isSetupChecklistComplete || !setupChecklistDismissed
    }
    var canPermanentlyDismissSetupChecklist: Bool {
        isSetupChecklistComplete
    }
    var apiKey: String { apiKeys.first ?? "" }
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    private var backupDir: String { "\(homeDir)/Library/Application Support/MergeSASE/Backup" }
    private var snapshotPath: String { "\(backupDir)/snapshot.json" }
    private let managedProxyKeys = ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"]
    private let managedAllProxyKeys = ["ALL_PROXY", "all_proxy"]
    private let managedNoProxyKeys = ["NO_PROXY", "no_proxy"]
    private var managedEnvKeys: [String] { managedProxyKeys + managedAllProxyKeys + managedNoProxyKeys }
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
        self.apiKeys = UserDefaults.standard.stringArray(forKey: "apiKeys") ?? []
        self.setupChecklistDismissed = UserDefaults.standard.bool(forKey: "setupChecklistDismissed")
        scheduleDeveloperBalanceRefresh()
        Task {
            await refreshStatus()
        }
    }

    private func log(_ text: String, _ level: LogLevel = .info) {
        logs.append(LogLine(timestamp: Date(), text: text, level: level))
        if logs.count > 500 { logs.removeFirst(100) }
    }

    private static func deduplicatedDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.compactMap { value in
            let domain = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "*.", with: "")
                .replacingOccurrences(of: "+.", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty, seen.insert(domain).inserted else { return nil }
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

    private func isClashFakeIP(_ ip: String) -> Bool {
        ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.")
    }

    private func realIPv4(from output: String) -> String? {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { ip in
                let parts = ip.split(separator: ".")
                return parts.count == 4
                    && parts.allSatisfy { Int($0) != nil }
                    && !isClashFakeIP(ip)
            }
    }

    private func routeRange(for ip: String) -> String? {
        let parts = ip.components(separatedBy: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return nil }
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
        let direct = await CommandRunner.runShell("dig +short \(host) 2>/dev/null")
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
            let result = await CommandRunner.runShell("dig @\(server) +short \(host) 2>/dev/null")
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
        let host = proxyHost.isEmpty ? "127.0.0.1" : proxyHost
        let proxyURL = "http://\(host):\(port)"
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
        # Public traffic can still use HTTP(S)_PROXY; company VPN traffic must bypass Clash.
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
            log("Codex/应用代理环境已修复: 公司域名与公司 VPN 网段直连，公网仍走 Clash", .success)
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

    private func cleanupManagedConfigurationWithoutSnapshot(plistPath: String, guardScript: String) async {
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
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                log("已清理 merge 配置: \((path as NSString).lastPathComponent)", .success)
            }
        }

        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: guardScript)
        guardLoaded = false
        log("配置文件已清理", .info)
    }

    private func restoreOrCleanupManagedConfiguration(plistPath: String, guardScript: String) async -> Bool {
        let restoredFromSnapshot = await restoreStartupSnapshot()
        if !restoredFromSnapshot {
            await cleanupManagedConfigurationWithoutSnapshot(plistPath: plistPath, guardScript: guardScript)
        }
        return restoredFromSnapshot
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
        var authPart = ""
        if !secret.isEmpty { authPart = "-H 'Authorization: Bearer \(secret)'" }
        _ = await CommandRunner.runShell(
            "curl -s -o /dev/null -X PUT 'http://127.0.0.1:9097/configs?force=true' -H 'Content-Type: application/json' \(authPart) -d '{}' 2>/dev/null"
        )
        log("Clash 配置已通过 API 重载", .info)
    }

    private func failStartAndRestore(_ reason: String) async {
        log("启动失败: \(reason)", .error)
        phase = .stopping
        statusMessage = "启动失败，正在自动恢复…"

        let plistPath = "\(homeDir)/Library/LaunchAgents/com.clash.proxyguard.plist"
        let guardScript = "\(homeDir)/.local/bin/clash-proxy-guard.sh"
        _ = await CommandRunner.run("/bin/launchctl", ["unload", plistPath])
        guardLoaded = false

        let restoredFromSnapshot = await restoreOrCleanupManagedConfiguration(plistPath: plistPath, guardScript: guardScript)
        await reloadClashAfterRestore()
        await refreshStatus()
        startupFailureCleanupCompleted = true
        phase = .error
        if restoredFromSnapshot {
            statusMessage = "启动失败，已自动恢复"
            log("========== 启动失败，已自动恢复 ==========", .warn)
        } else {
            statusMessage = "启动失败，已清理配置"
            log("========== 启动失败，未找到快照，已执行清理式卸载 ==========", .warn)
        }
    }

    func addDomain(_ domain: String) {
        let trimmed = normalizedHost(domain)
        guard !trimmed.isEmpty, !companyDomains.map(normalizedHost).contains(trimmed) else { return }
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

        developerBalanceStatus = .loading
        developerBalanceSummary = "查询中"

        var request = URLRequest(url: developerBalanceAPIURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(requestToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MergeSASE/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await performDeveloperBalanceRequest(request)
            guard requestToken == bearerToken(from: activeAPIKey ?? "") else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode != 401 && statusCode != 403 else {
                developerBalanceStatus = .unauthorized
                developerBalanceSummary = "Key 无效"
                log("余额查询鉴权失败: HTTP \(statusCode)\(developerBalanceMessageSuffix(data))", .warn)
                return
            }
            guard (200..<300).contains(statusCode) else {
                developerBalanceStatus = .error
                developerBalanceSummary = "查询失败"
                log("余额查询失败: HTTP \(statusCode)\(developerBalanceMessageSuffix(data))", .warn)
                return
            }

            if let amount = parseDeveloperBalanceAmount(data) {
                developerBalanceStatus = .ok
                developerBalanceSummary = "$\(String(format: "%.2f", amount))"
            } else {
                developerBalanceStatus = .error
                developerBalanceSummary = "解析失败"
                log("余额查询响应未识别余额字段\(developerBalanceTopLevelKeysSuffix(data))", .warn)
            }
        } catch {
            developerBalanceStatus = .error
            developerBalanceSummary = "查询失败"
            log("余额查询网络失败: \(error.localizedDescription)", .warn)
        }
    }

    private func performDeveloperBalanceRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var configs: [URLSessionConfiguration] = [developerBalanceURLSessionConfiguration(proxy: nil)]
        let host = proxyHost.isEmpty ? "127.0.0.1" : proxyHost
        if externalProxyRunning || systemProxyEnabled {
            configs.append(developerBalanceURLSessionConfiguration(proxy: (host, clashPort)))
        }

        var lastError: Error?
        var directFailureResponse: (Data, URLResponse)?
        for (index, config) in configs.enumerated() {
            config.waitsForConnectivity = true
            let session = URLSession(configuration: config)
            do {
                let result = try await session.data(for: request)
                session.finishTasksAndInvalidate()
                let statusCode = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
                if index == 0, configs.count > 1, !(200..<300).contains(statusCode) {
                    directFailureResponse = result
                    continue
                }
                return result
            } catch {
                session.invalidateAndCancel()
                lastError = error
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        if let directFailureResponse {
            return directFailureResponse
        }
        throw lastError ?? URLError(.unknown)
    }

    private func developerBalanceURLSessionConfiguration(proxy: (host: String, port: Int)?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        if let proxy {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: proxy.port
            ]
        }
        return config
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

    private func systemProxyEndpoint() async -> (host: String, port: Int)? {
        let proxy = await CommandRunner.runShell("scutil --proxy 2>/dev/null")
        guard proxy.stdout.contains("HTTPEnable : 1") else { return nil }

        var host = "127.0.0.1"
        var port: Int?
        if let range = proxy.stdout.range(of: "HTTPProxy : ") {
            host = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? host
        }
        if let range = proxy.stdout.range(of: "HTTPPort : ") {
            let portStr = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            port = Int(portStr)
        }
        guard let port else { return nil }
        return (host, port)
    }

    private func detectShadowrocketPort() async -> Int? {
        let lsofRes = await CommandRunner.runShell(
            "lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -iE 'Shadowrocket|shadowrocket' | grep -o '127\\.0\\.0\\.1:[0-9]\\+' | cut -d: -f2 | head -1"
        )
        if let port = Int(lsofRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
            return port
        }
        for port in [1087, 1080, 7890, 7897, 6152] {
            let check = await CommandRunner.runShell("nc -z 127.0.0.1 \(port) >/dev/null 2>&1 && echo 1 || echo 0")
            if check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return port
            }
        }
        return nil
    }

    private func detectExternalProxyClient() async -> ExternalProxyDetection {
        let systemEndpoint = await systemProxyEndpoint()
        let preference = externalProxyPreference

        func processContains(_ pattern: String) async -> Bool {
            let result = await CommandRunner.runShell("pgrep -if '\(pattern)' >/dev/null && echo 1 || echo 0")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }

        let shadowrocketRunning = await processContains("Shadowrocket|shadowrocket")
        let clashRunningNow = await detectClashRunning(port: systemEndpoint?.port ?? clashPort)

        if preference == .shadowrocket {
            let port: Int
            if let detectedPort = await detectShadowrocketPort() {
                port = detectedPort
            } else if let systemPort = systemEndpoint?.port {
                port = systemPort
            } else {
                port = 1087
            }
            return ExternalProxyDetection(
                displayName: "Shadowrocket",
                detail: shadowrocketRunning ? "127.0.0.1:\(port)" : "未检测到 Shadowrocket 进程",
                host: systemEndpoint?.host ?? "127.0.0.1",
                port: port,
                running: shadowrocketRunning,
                supportsClashConfig: false
            )
        }

        if preference == .clash {
            let port = await detectClashPort()
            return ExternalProxyDetection(
                displayName: "Clash",
                detail: "127.0.0.1:\(port)",
                host: "127.0.0.1",
                port: port,
                running: clashRunningNow,
                supportsClashConfig: true
            )
        }

        if shadowrocketRunning, !clashRunningNow {
            let port: Int
            if let systemPort = systemEndpoint?.port {
                port = systemPort
            } else {
                port = await detectShadowrocketPort() ?? 1087
            }
            return ExternalProxyDetection(
                displayName: "Shadowrocket",
                detail: "127.0.0.1:\(port)",
                host: systemEndpoint?.host ?? "127.0.0.1",
                port: port,
                running: true,
                supportsClashConfig: false
            )
        }

        let port: Int
        if let systemPort = systemEndpoint?.port {
            port = systemPort
        } else {
            port = await detectClashPort()
        }
        return ExternalProxyDetection(
            displayName: "Clash",
            detail: "127.0.0.1:\(port)",
            host: systemEndpoint?.host ?? "127.0.0.1",
            port: port,
            running: clashRunningNow,
            supportsClashConfig: true
        )
    }

    private func writeMergeConfig(port: Int) async {
        // Resolve company domains to find internal IP ranges
        var internalRanges = Set(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16"])
        let nameservers = await systemNameservers()
        for domain in companyDomains {
            for prefix in ["", "new-api", "api", "www", "portal", "vpn"] {
                let host = prefix.isEmpty ? domain : "\(prefix).\(domain)"
                if let ip = await resolveRealIPv4(host, nameservers: nameservers), let range = routeRange(for: ip) {
                    internalRanges.insert(range)
                    log("检测到公司内网 IP: \(host) → \(ip) → 排除路由 \(range)", .info)
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
        startupFailureCleanupCompleted = false
        phase = .starting
        statusMessage = "启动中…"
        log("========== 开始启动 ==========")

        let vpn = await detectCompanyVPNClient()
        vpnClientName = vpn.displayName
        vpnClientDetail = vpn.detail
        vpnClientRunning = vpn.running
        if vpn.running {
            log("检测到公司 VPN: \(vpn.displayName)（\(vpn.detail)）", .success)
        } else {
            log("未检测到 SASE/OpenVPN Connect，公司内网需要先连接 VPN", .warn)
        }

        let externalProxy = await detectExternalProxyClient()
        proxyHost = externalProxy.host
        clashPort = externalProxy.port
        clashRunning = externalProxy.running
        externalProxyName = externalProxy.displayName
            externalProxyDetail = externalProxy.detail
            externalProxyRunning = externalProxy.running
            externalProxySupportsClashConfig = externalProxy.supportsClashConfig
            log("检测到外网代理: \(externalProxy.displayName) \(externalProxy.detail)", externalProxy.running ? .success : .warn)
            if !externalProxy.running {
                log("外网代理未运行，请先打开 \(externalProxy.displayName) 或切换代理选择", .warn)
            }

        await takeRestoreSnapshotIfNeeded()

        if externalProxy.supportsClashConfig {
            await writeMergeConfig(port: externalProxy.port)
        } else {
            log("当前外网代理为 \(externalProxy.displayName)，跳过 Clash 专属 fake-ip/route-exclude 写入；请在 \(externalProxy.displayName) 里确保公司域名直连", .info)
        }

        // Generate guard script — include resolved IP ranges
        let guardDir = "\(homeDir)/.local/bin"
        let guardScript = "\(guardDir)/clash-proxy-guard.sh"
        try? FileManager.default.createDirectory(atPath: guardDir, withIntermediateDirectories: true, attributes: nil)
        let startupNameservers = await systemNameservers()
        var guardBypassItems = ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16",
                                "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16"]
        for domain in companyDomains {
            guardBypassItems.append(contentsOf: broadBypassItems(for: domain))
            if let ip = await resolveRealIPv4(domain, nameservers: startupNameservers), let range = routeRange(for: ip) {
                guardBypassItems.append(range)
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
        CLASH_HOST="\(externalProxy.host)"
        CLASH_PORT="\(externalProxy.port)"
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
            await failStartAndRestore("守护脚本写入失败")
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
            log("已跳过自动守护；系统代理、Chrome、Clash 仍会继续配置。请检查 ~/Library/LaunchAgents 权限后重试。", .warn)
        }

        // Set system proxy — include resolved IP ranges in bypass
        var bypassList = ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16",
                          "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16"]
        for domain in companyDomains {
            bypassList.append(contentsOf: broadBypassItems(for: domain))
            if let ip = await resolveRealIPv4(domain, nameservers: startupNameservers), let range = routeRange(for: ip) {
                bypassList.append(range)
            }
        }
        // Deduplicate while preserving order
        var seen = Set<String>()
        bypassList = bypassList.filter { seen.insert($0).inserted }
        await setLaunchdNoProxy(bypassList)
        await setLaunchdProxy(port: externalProxy.port)
        await writeAppEnvironment(port: externalProxy.port, bypassItems: bypassList)
        if !proxyRequiredHosts.isEmpty {
            log("以下 API 域名将强制走外网代理，不写入绕过: \(proxyRequiredHosts.joined(separator: ", "))", .info)
        }

        let svcResult = await CommandRunner.runShell("networksetup -listallnetworkservices 2>/dev/null | tail -n +2")
        let services = svcResult.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        for service in services {
            let trimmed = service.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("An asterisk") { continue }
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setwebproxy", trimmed, proxyHost, "\(externalProxy.port)"])
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxy", trimmed, proxyHost, "\(externalProxy.port)"])
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", trimmed, proxyHost, "\(externalProxy.port)"])
            _ = await CommandRunner.run("/usr/sbin/networksetup", ["-setproxybypassdomains", trimmed] + bypassList)
        }
        log("系统代理已设置: \(proxyHost):\(externalProxy.port)", .success)

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
        try? FileManager.default.createDirectory(atPath: managedDir, withIntermediateDirectories: true, attributes: nil)
        try? chromePolicyXML.write(toFile: "\(managedDir)/com.google.Chrome.plist", atomically: true, encoding: .utf8)

        // Path 2: Legacy preferences (older Chrome versions)
        _ = await CommandRunner.run("/usr/bin/defaults", [
            "write", "\(homeDir)/Library/Preferences/com.google.Chrome.plist", "ProxySettings",
            "-dict", "ProxyMode", "fixed_servers", "ProxyServer", "\(externalProxy.host):\(externalProxy.port)", "ProxyBypassList", bypassStr
        ])
        chromePolicyInstalled = true
        log("Chrome 策略已配置", .success)
        suggestBrowserAction("Chrome 策略已配置，建议手动重启 Chrome 后生效。")
        log("未自动重启 Chrome；如需让 Chrome 立即套用新策略，请手动重启 Chrome", .info)

        // Load launchd
        if FileManager.default.fileExists(atPath: plistPath) {
            _ = await CommandRunner.run("/bin/launchctl", ["unload", plistPath])
            let loadRes = await CommandRunner.run("/bin/launchctl", ["load", plistPath])
            if loadRes.succeeded {
                log("守护已启动（事件驱动，公司 VPN 清代理时 2 秒内恢复）", .success)
                guardLoaded = true
            } else {
                log("守护启动失败: \(loadRes.stderr.isEmpty ? "launchctl 未返回详细原因" : loadRes.stderr)", .warn)
                guardLoaded = false
                await failStartAndRestore("守护启动失败")
                return
            }
        }


        await refreshStatus()
        if systemProxyEnabled && guardLoaded {
            phase = .running
            statusMessage = "运行中"
            log("========== 启动完成 ==========", .success)
        } else {
            await failStartAndRestore(systemProxyEnabled ? "守护未加载" : "系统代理未生效")
            return
        }

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

        if startupFailureCleanupCompleted {
            log("启动失败时已自动还原/清理，本次跳过重复清理", .info)
        } else {
            _ = await restoreOrCleanupManagedConfiguration(plistPath: plistPath, guardScript: guardScript)

            if externalProxySupportsClashConfig || externalProxyPreference != .shadowrocket {
                // Reload Clash config after restoring or removing merge config.
                await reloadClashAfterRestore()
            }
        }

        suggestBrowserAction("Chrome 策略已移除，建议手动重启 Chrome 清掉旧代理。")
        log("未自动退出 Chrome；如 Chrome 仍沿用旧代理，请手动重启 Chrome", .info)

        await refreshStatus()
        startupFailureCleanupCompleted = false
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
        async let vpnCheck = detectCompanyVPNClient()
        async let externalProxyCheck = detectExternalProxyClient()
        let (proxy, guardChk, vpn, externalProxy) = await (proxyCheck, guardCheck, vpnCheck, externalProxyCheck)

        systemProxyEnabled = proxy.stdout.contains("HTTPEnable : 1")
        if let range = proxy.stdout.range(of: "HTTPPort : ") {
            let portStr = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if let p = Int(portStr) { clashPort = p }
        }
        if let range = proxy.stdout.range(of: "HTTPProxy : ") {
            proxyHost = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "127.0.0.1"
        }
        guardLoaded = guardChk.exitCode == 0
        clashRunning = externalProxy.running
        externalProxyName = externalProxy.displayName
        externalProxyDetail = externalProxy.detail
        externalProxyRunning = externalProxy.running
        externalProxySupportsClashConfig = externalProxy.supportsClashConfig
        vpnClientName = vpn.displayName
        vpnClientDetail = vpn.detail
        vpnClientRunning = vpn.running

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

    private func detectCompanyVPNClient() async -> VPNClientDetection {
        async let processCheck = CommandRunner.runShell(
            "ps ax -o command= 2>/dev/null | grep -Ei 'OpenVPN Connect|OpenVPN|openvpn|openvpn3|ovpnagent|SASE|sase|GlobalProtect|Zscaler|Netskope|Cisco AnyConnect|AnyConnect' | grep -vi 'MergeSASE' | grep -v grep | head -5"
        )
        async let interfaceCheck = CommandRunner.runShell(
            "ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{iface=$1; sub(\":\", \"\", iface)} /status: active|inet /{print iface}' | grep -E '^(utun|tun|tap|ppp|ipsec)' | sort -u | tr '\\n' ' '"
        )
        async let routeCheck = CommandRunner.runShell(
            "netstat -rn -f inet 2>/dev/null | awk '$NF ~ /^(utun|tun|tap|ppp|ipsec)/ {print $NF}' | sort -u | tr '\\n' ' '"
        )
        let (process, interfaces, routes) = await (processCheck, interfaceCheck, routeCheck)

        let processOutput = process.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = processOutput.lowercased()
        let interfaceOutput = interfaces.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let routeOutput = routes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let vpnInterfaces = [interfaceOutput, routeOutput]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var seenInterfaces = Set<String>()
        let uniqueInterfaces = vpnInterfaces.filter { seenInterfaces.insert($0).inserted }
        let hasVPNInterface = !uniqueInterfaces.isEmpty
        let detail = uniqueInterfaces.isEmpty ? "未发现 VPN 虚拟网卡" : "接口 \(uniqueInterfaces.joined(separator: ", "))"

        if lower.contains("openvpn") || lower.contains("ovpnagent") {
            return VPNClientDetection(displayName: "OpenVPN Connect", detail: detail, running: hasVPNInterface)
        }
        if lower.contains("sase") {
            return VPNClientDetection(displayName: "SASE", detail: detail, running: hasVPNInterface)
        }
        if lower.contains("globalprotect") {
            return VPNClientDetection(displayName: "GlobalProtect", detail: detail, running: hasVPNInterface)
        }
        if lower.contains("zscaler") {
            return VPNClientDetection(displayName: "Zscaler", detail: detail, running: hasVPNInterface)
        }
        if lower.contains("netskope") {
            return VPNClientDetection(displayName: "Netskope", detail: detail, running: hasVPNInterface)
        }
        if lower.contains("anyconnect") {
            return VPNClientDetection(displayName: "Cisco AnyConnect", detail: detail, running: hasVPNInterface)
        }
        if !uniqueInterfaces.isEmpty {
            return VPNClientDetection(displayName: "公司 VPN", detail: detail, running: true)
        }
        return VPNClientDetection()
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
        guard let domain = companyDomains.first else {
            internalResult = NetworkCheckResult(accessible: false, url: "", ip: "", statusCode: "未配置", latencyMs: "")
            log("公司内网未检测: 还没有配置公司域名", .warn)
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
        let digRaw = await CommandRunner.runShell("dig +short \(domain) 2>/dev/null")
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
            let routeRes = await CommandRunner.runShell("route -n get \(internalResult.ip) 2>/dev/null | grep -E 'interface:|destination:'")
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
            let digFull = await CommandRunner.runShell("dig \(domain) 2>/dev/null | grep -E 'SERVER:|status:|ANSWER SECTION' -A2")
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
            let isInternalRoute = routeIface.hasPrefix("utun")
                || routeIface.hasPrefix("tun")
                || routeIface.hasPrefix("tap")
                || routeIface.hasPrefix("ppp")

            if isInternalRoute {
                internalResult.accessible = true
                internalResult.statusCode = "-"
                internalResult.latencyMs = "DNS ✓ 路由 \(routeIface)"
                log("公司内网可达: \(checkURL) → \(internalResult.ip)（DNS 已解析，路由走 \(routeIface)，HTTP 无响应为该 IP 无 Web 服务）", .success)
            } else {
                internalResult.accessible = false
                internalResult.statusCode = "不可达"
                internalResult.latencyMs = "路由异常"
                log("公司内网不通: \(checkURL) → \(internalResult.ip)，路由接口: \(routeIface)（预期公司 VPN 的 utun/tun/tap 接口）", .error)
            }
        } else {
            internalResult.accessible = false
            internalResult.latencyMs = "无"
            internalResult.statusCode = "-"
            log("公司内网不可访问: \(domain) 及子域均无法解析，请确认 SASE 或 OpenVPN Connect 已连接", .error)
        }
    }
}
