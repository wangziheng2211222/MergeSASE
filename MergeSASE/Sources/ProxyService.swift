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
    var internalResult = NetworkCheckResult()
    var externalResult = NetworkCheckResult()
    var logs: [LogLine] = []
    var companyDomains: [String] {
        didSet { UserDefaults.standard.set(companyDomains, forKey: "companyDomains") }
    }
    var statusMessage: String = "就绪"
    var newDomain: String = ""

    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "companyDomains") ?? []
        // Migrate from old default or bootstrap
        if saved.isEmpty || saved == ["company.internal"] {
            self.companyDomains = ["cds8.cn", "limayao.com"]
            UserDefaults.standard.removeObject(forKey: "companyDomains") // let didSet write fresh value
        } else {
            self.companyDomains = saved
        }
        Task { await refreshStatus() }
    }

    private func log(_ text: String, _ level: LogLevel = .info) {
        logs.append(LogLine(timestamp: Date(), text: text, level: level))
        if logs.count > 500 { logs.removeFirst(100) }
    }

    func addDomain(_ domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !companyDomains.contains(trimmed) else { return }
        companyDomains.append(trimmed)
    }

    func removeDomain(_ domain: String) {
        companyDomains.removeAll { $0 == domain }
        if companyDomains.isEmpty { companyDomains = ["cds8.cn", "limayao.com"] }
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
        var internalRanges = Set(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"])
        for domain in companyDomains {
            let digRes = await CommandRunner.runShell("dig +short \(domain) 2>/dev/null | grep -v '^;;' | grep -E '^[0-9]' | head -1")
            let ip = digRes.stdout.trimmingCharacters(in: .whitespaces)
            if !ip.isEmpty {
                let parts = ip.components(separatedBy: ".")
                if parts.count == 4 {
                    internalRanges.insert("\(parts[0]).\(parts[1]).0.0/16")
                }
                log("检测到公司内网 IP: \(ip) → 排除路由 \(parts[0]).\(parts[1]).0.0/16", .info)
            }
        }

        let routeExcludeYAML = internalRanges.sorted().map { "          - '\($0)'" }.joined(separator: "\n")
        let mergeContent = """
        # MergeSASE — Clash Verge Profile Enhancement
        profile:
          store-selected: true

        dns:
          use-system-hosts: false
          fake-ip-filter:
            - '+.\(companyDomains.joined(separator: "'\n            - '+."))'

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

        // Reload Clash config via API
        await reloadClashConfig(port: port)
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

        // Write Clash merge config with route-exclude
        await writeMergeConfig(port: port)

        // Generate guard script — include resolved IP ranges
        let guardDir = "\(homeDir)/.local/bin"
        let guardScript = "\(guardDir)/clash-proxy-guard.sh"
        try? FileManager.default.createDirectory(atPath: guardDir, withIntermediateDirectories: true, attributes: nil)
        var guardBypassItems = ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16",
                                "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16"]
        for domain in companyDomains {
            guardBypassItems.append(domain)
            guardBypassItems.append("*.\(domain)")
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
        let guardContent = """
        #!/bin/bash
        CLASH_HOST="127.0.0.1"
        CLASH_PORT="\(port)"
        COMPANY_DOMAINS=(
        \(domainLines)
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
                          "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "197.19.0.0/16"]
        for domain in companyDomains {
            bypassList.append(domain)
            bypassList.append("*.\(domain)")
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
        let chromeBypassItems: [String] = companyDomains.map { "*.\($0)" } + bypassList.filter { $0.contains("/") || $0 == "127.0.0.1" || $0 == "localhost" || $0 == "*.local" }
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

        // 2. Turn off system proxy
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
        log("系统代理已关闭", .success)

        // 3. Remove Chrome policies
        _ = await CommandRunner.run("/usr/bin/defaults", ["delete", "\(homeDir)/Library/Preferences/com.google.Chrome.plist", "ProxySettings"])
        try? FileManager.default.removeItem(atPath: "\(homeDir)/Library/Application Support/Google/Chrome/Managed/com.google.Chrome.plist")
        chromePolicyInstalled = false
        log("Chrome 策略已移除", .success)

        // 4. Remove Clash merge configs
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

        // 5. Reload Clash config
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

        // 6. Clean up files
        try? FileManager.default.removeItem(atPath: plistPath)
        try? FileManager.default.removeItem(atPath: guardScript)
        log("配置文件已清理", .info)

        // 7. Kill Chrome so next launch is normal (no proxy args)
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
        async let clashCheck = CommandRunner.runShell("ps aux 2>/dev/null | grep -iE 'mihomo' | grep -v grep")

        let (proxy, guardChk, clashChk) = await (proxyCheck, guardCheck, clashCheck)

        systemProxyEnabled = proxy.stdout.contains("HTTPEnable : 1")
        if let range = proxy.stdout.range(of: "HTTPPort : ") {
            let portStr = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if let p = Int(portStr) { clashPort = p }
        }
        if let range = proxy.stdout.range(of: "HTTPProxy : ") {
            proxyHost = proxy.stdout[range.upperBound...].components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "127.0.0.1"
        }
        guardLoaded = guardChk.exitCode == 0
        clashRunning = !clashChk.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let chromePlistPath = "\(homeDir)/Library/Preferences/com.google.Chrome.plist"
        if FileManager.default.fileExists(atPath: chromePlistPath) {
            let readRes = await CommandRunner.run("/usr/bin/defaults", ["read", chromePlistPath, "ProxySettings"])
            chromePolicyInstalled = readRes.succeeded && !readRes.stdout.isEmpty
        } else {
            chromePolicyInstalled = false
        }

        if phase == .running { statusMessage = "运行中" }
    }

    // MARK: - Network Checks (detailed)

    func checkExternalNetwork() async {
        log("检测外部网络: google.com...")
        externalResult.url = "https://www.google.com"
        let result = await CommandRunner.runShell(
            "curl -s -o /dev/null -w '%{http_code}|%{time_total}|%{remote_ip}' --max-time 5 https://www.google.com 2>&1"
        )
        let parts = result.stdout.components(separatedBy: "|")
        let code = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latency = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let remoteIP = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""

        externalResult.statusCode = code
        externalResult.accessible = (code == "200" || code == "301" || code == "302")

        if let ms = Double(latency) {
            externalResult.latencyMs = String(format: "%.0fms", ms * 1000)
        } else {
            externalResult.latencyMs = latency
        }

        if externalResult.accessible {
            log("外部网络可访问: google.com → HTTP \(code) (\(externalResult.latencyMs)) 出口IP: \(remoteIP) ✓", .success)
        } else {
            log("外部网络不可访问: HTTP \(code) (\(externalResult.latencyMs))", .error)
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
