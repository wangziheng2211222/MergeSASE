import Foundation

struct LocalProxyEndpoint: Equatable {
    let host: String
    let port: Int
}

struct PhysicalNetworkService: Equatable {
    let name: String
    let device: String
}

enum NetworkCompatibility {
    static let shadowrocketBundleIdentifier = "com.liguangming.Shadowrocket"

    static func normalizedDomain(_ value: String) -> String? {
        var domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.hasPrefix("*.") || domain.hasPrefix("+.") {
            domain.removeFirst(2)
        }
        if domain.hasSuffix(".") {
            domain.removeLast()
        }

        guard !domain.isEmpty, domain.count <= 253, domain.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return nil
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard !label.isEmpty, label.count <= 63, label.first != "-", label.last != "-" else {
                return false
            }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else {
            return nil
        }
        return domain
    }

    static func parseSystemHTTPProxy(_ output: String) -> LocalProxyEndpoint? {
        parseSystemProxyEndpoint(
            output,
            enableKey: "HTTPEnable",
            hostKey: "HTTPProxy",
            portKey: "HTTPPort"
        )
    }

    static func parseSystemHTTPSProxy(_ output: String) -> LocalProxyEndpoint? {
        parseSystemProxyEndpoint(
            output,
            enableKey: "HTTPSEnable",
            hostKey: "HTTPSProxy",
            portKey: "HTTPSPort"
        )
    }

    static func parseSystemSOCKSProxy(_ output: String) -> LocalProxyEndpoint? {
        parseSystemProxyEndpoint(
            output,
            enableKey: "SOCKSEnable",
            hostKey: "SOCKSProxy",
            portKey: "SOCKSPort"
        )
    }

    static func systemProxyExceptions(_ output: String) -> [String] {
        var insideExceptions = false
        var result: [String] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "ExceptionsList : <array> {" {
                insideExceptions = true
                continue
            }
            guard insideExceptions else { continue }
            if line == "}" { break }
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2, Int(parts[0]) != nil, !parts[1].isEmpty {
                result.append(parts[1])
            }
        }
        return result
    }

    private static func parseSystemProxyEndpoint(
        _ output: String,
        enableKey: String,
        hostKey: String,
        portKey: String
    ) -> LocalProxyEndpoint? {
        var enabled = false
        var host: String?
        var port: Int?

        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case enableKey:
                enabled = parts[1] == "1"
            case hostKey:
                host = parts[1]
            case portKey:
                port = Int(parts[1])
            default:
                break
            }
        }

        guard enabled, let host, !host.isEmpty, let port, (1...65535).contains(port) else {
            return nil
        }
        return LocalProxyEndpoint(host: host, port: port)
    }

    static func shadowrocketIsConnected(in networkConnectionList: String) -> Bool {
        networkConnectionList.components(separatedBy: .newlines).contains { line in
            line.contains("(Connected)")
                && (line.contains(shadowrocketBundleIdentifier) || line.contains("\"Shadowrocket\""))
        }
    }

    static func connectedVPNNames(in networkConnectionList: String) -> [String] {
        networkConnectionList.components(separatedBy: .newlines).compactMap { line in
            guard line.contains("(Connected)"), !line.contains(shadowrocketBundleIdentifier) else {
                return nil
            }
            let quoted = line.split(separator: "\"")
            guard quoted.count >= 3 else { return nil }
            return String(quoted[1])
        }
    }

    static func interfaceName(in networkConnectionStatus: String) -> String? {
        for line in networkConnectionStatus.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2, parts[0] == "InterfaceName", !parts[1].isEmpty {
                return parts[1]
            }
        }
        return nil
    }

    static func shadowrocketOwnsListeningPort(_ port: Int, netstatOutput: String) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return netstatOutput.components(separatedBy: .newlines).contains { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 6 else { return false }
            let localAddress = fields[3]
            let lower = line.lowercased()
            return (localAddress.hasSuffix(".\(port)") || localAddress.hasSuffix(":\(port)"))
                && fields[5].caseInsensitiveCompare("LISTEN") == .orderedSame
                && lower.contains("shadowrocket")
        }
    }

    static func isShadowrocketExecutablePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/shadowrocket.app/")
            || lower.contains(shadowrocketBundleIdentifier.lowercased())
    }

    static func removingManagedEnvironmentBlocks(from content: String) -> String? {
        let startMarkers = Set([
            "# === MergeSASE managed proxy environment ===",
            "# === 蝉舒宝 managed proxy environment ===",
        ])
        let endMarkers = Set([
            "# === End MergeSASE managed proxy environment ===",
            "# === End 蝉舒宝 managed proxy environment ===",
        ])
        var output: [String] = []
        var insideManagedBlock = false

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if startMarkers.contains(trimmed) {
                guard !insideManagedBlock else { return nil }
                insideManagedBlock = true
                continue
            }
            if endMarkers.contains(trimmed) {
                guard insideManagedBlock else { return nil }
                insideManagedBlock = false
                continue
            }
            if !insideManagedBlock {
                output.append(line)
            }
        }

        guard !insideManagedBlock else { return nil }
        return output.joined(separator: "\n")
    }

    static func containsManagedEnvironmentMarker(_ content: String) -> Bool {
        content.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "# === MergeSASE managed proxy environment ==="
                || trimmed == "# === 蝉舒宝 managed proxy environment ==="
                || trimmed == "# === End MergeSASE managed proxy environment ==="
                || trimmed == "# === End 蝉舒宝 managed proxy environment ==="
        }
    }

    static func removingManagedClashEntries(from content: String, companyDomains: [String]) -> String {
        content.components(separatedBy: "\n")
            .filter { !isManagedClashEntry($0, companyDomains: companyDomains) }
            .joined(separator: "\n")
    }

    static func containsManagedClashEntries(_ content: String, companyDomains: [String]) -> Bool {
        content.components(separatedBy: .newlines).contains {
            isManagedClashEntry($0, companyDomains: companyDomains)
        }
    }

    private static func isManagedClashEntry(_ line: String, companyDomains: [String]) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        if compact == "-IP-CIDR,197.19.0.0/16,DIRECT,no-resolve" {
            return true
        }

        return companyDomains.compactMap(normalizedDomain).contains { domain in
            let filter = "+.\(domain)"
            return compact == "-\(filter)"
                || compact == "-'\(filter)'"
                || compact == "-\"\(filter)\""
                || compact == "\(filter):system"
                || compact == "'\(filter)':system"
                || compact == "\"\(filter)\":system"
                || compact == "-DOMAIN-SUFFIX,\(domain),DIRECT"
        }
    }

    static func specificVirtualRouteInterface(
        for ip: String,
        routeOutput: String,
        routingTableOutput: String,
        excluding excludedInterfaces: Set<String> = []
    ) -> String? {
        var values: [String: String] = [:]
        for line in routeOutput.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }

        guard isValidIPv4(ip),
              let interface = values["interface"],
              !excludedInterfaces.contains(interface),
              isVirtualInterface(interface),
              interface == bestSpecificRouteInterface(
                for: ip,
                routingTableOutput: routingTableOutput,
                excluding: excludedInterfaces
              )
        else {
            return nil
        }
        return interface
    }

    static func physicalNetworkServices(from serviceOrder: String) -> [PhysicalNetworkService] {
        var currentService: String?
        var result: [PhysicalNetworkService] = []

        for rawLine in serviceOrder.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("("), let closingParen = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware Port:") {
                let name = line[line.index(after: closingParen)...].trimmingCharacters(in: .whitespaces)
                currentService = name.hasPrefix("*") ? nil : name
                continue
            }

            guard line.hasPrefix("(Hardware Port:"), let currentService else { continue }
            guard let deviceRange = line.range(of: "Device:") else { continue }
            let device = line[deviceRange.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " )"))
            guard !device.isEmpty else { continue }
            result.append(PhysicalNetworkService(name: currentService, device: device))
        }
        return result
    }

    static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard !part.isEmpty, let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }

    private static func bestSpecificRouteInterface(
        for ip: String,
        routingTableOutput: String,
        excluding excludedInterfaces: Set<String>
    ) -> String? {
        guard let ipValue = ipv4Value(ip) else { return nil }
        var best: (prefix: Int, interface: String)?

        for line in routingTableOutput.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let destination = fields.first,
                  let (network, prefix) = cidrRoute(destination),
                  prefix >= 8,
                  let interface = fields.first(where: isVirtualInterface),
                  !excludedInterfaces.contains(interface)
            else {
                continue
            }

            let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
            guard (ipValue & mask) == (network & mask) else { continue }
            if best == nil || prefix > best!.prefix {
                best = (prefix, interface)
            }
        }
        return best?.interface
    }

    private static func cidrRoute(_ value: String) -> (network: UInt32, prefix: Int)? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...32).contains(prefix)
        else {
            return nil
        }
        var octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard !octets.isEmpty, octets.count <= 4, octets.allSatisfy({ $0 <= 255 }) else {
            return nil
        }
        while octets.count < 4 { octets.append(0) }
        let network = octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
        return (network, prefix)
    }

    private static func ipv4Value(_ value: String) -> UInt32? {
        let octets = value.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        return octets.reduce(UInt32(0)) { ($0 << 8) | $1 }
    }

    private static func isVirtualInterface(_ value: String) -> Bool {
        value.hasPrefix("utun")
            || value.hasPrefix("tun")
            || value.hasPrefix("tap")
            || value.hasPrefix("ppp")
            || value.hasPrefix("ipsec")
    }
}
