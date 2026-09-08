import Testing
@testable import MergeSASE

@Suite("Network compatibility")
struct NetworkCompatibilityTests {
    @Test func domainNormalizationRejectsShellInputAndInvalidLabels() {
        #expect(NetworkCompatibility.normalizedDomain(" *.Example.COM. ") == "example.com")
        #expect(NetworkCompatibility.normalizedDomain("example.com; touch /tmp/bad") == nil)
        #expect(NetworkCompatibility.normalizedDomain("-bad.example") == nil)
        #expect(NetworkCompatibility.normalizedDomain("bad_.example") == nil)
        #expect(NetworkCompatibility.normalizedDomain("bad*.example") == nil)
        #expect(NetworkCompatibility.normalizedDomain("example.com..") == nil)
        #expect(NetworkCompatibility.normalizedDomain("https://example.com") == nil)
    }

    @Test func systemProxyRequiresEnabledValidEndpoint() {
        let enabled = """
          HTTPEnable : 1
          HTTPPort : 7897
          HTTPProxy : 127.0.0.1
          HTTPSEnable : 1
          HTTPSPort : 7897
          HTTPSProxy : 127.0.0.1
          SOCKSEnable : 1
          SOCKSPort : 7897
          SOCKSProxy : 127.0.0.1
        """
        #expect(NetworkCompatibility.parseSystemHTTPProxy(enabled) == LocalProxyEndpoint(host: "127.0.0.1", port: 7897))
        #expect(NetworkCompatibility.parseSystemHTTPSProxy(enabled) == LocalProxyEndpoint(host: "127.0.0.1", port: 7897))
        #expect(NetworkCompatibility.parseSystemSOCKSProxy(enabled) == LocalProxyEndpoint(host: "127.0.0.1", port: 7897))
        #expect(NetworkCompatibility.parseSystemHTTPProxy(enabled.replacingOccurrences(of: "HTTPEnable : 1", with: "HTTPEnable : 0")) == nil)
        #expect(NetworkCompatibility.parseSystemHTTPProxy(enabled.replacingOccurrences(of: "7897", with: "70000")) == nil)
        #expect(NetworkCompatibility.parseSystemHTTPProxy(enabled.replacingOccurrences(of: "127.0.0.1", with: "::1")) == LocalProxyEndpoint(host: "::1", port: 7897))
    }

    @Test func systemProxyExceptionsAreParsedOnlyFromTheirArray() {
        let output = """
        <dictionary> {
          ExceptionsList : <array> {
            0 : localhost
            1 : *.example.com
          }
          HTTPEnable : 1
          SupplementalMatchDomains : <array> {
            0 : unrelated.example
          }
        }
        """
        #expect(NetworkCompatibility.systemProxyExceptions(output) == ["localhost", "*.example.com"])
    }

    @Test func shadowrocketMustBeConnected() {
        let disconnected = "* (Disconnected) F285 VPN (com.liguangming.Shadowrocket) \"Shadowrocket\" [VPN:com.liguangming.Shadowrocket]"
        let connected = disconnected.replacingOccurrences(of: "(Disconnected)", with: "(Connected)")
        #expect(!NetworkCompatibility.shadowrocketIsConnected(in: disconnected))
        #expect(NetworkCompatibility.shadowrocketIsConnected(in: connected))
        #expect(!NetworkCompatibility.shadowrocketIsConnected(in: disconnected.replacingOccurrences(of: "(Disconnected)", with: "(Connecting)")))
    }

    @Test func connectedCompanyVPNExcludesShadowrocket() {
        let output = """
        * (Connected) AAA VPN (com.liguangming.Shadowrocket) "Shadowrocket" [VPN:com.liguangming.Shadowrocket]
        * (Connected) BBB VPN (cn.com.ruijie.sslvpn) "Ruijie SSLVPN" [VPN:cn.com.ruijie.sslvpn]
        """
        #expect(NetworkCompatibility.connectedVPNNames(in: output) == ["Ruijie SSLVPN"])
    }

    @Test func connectionStatusProvidesTunnelInterface() {
        let output = """
        Connected
        Extended Status <dictionary> {
          InterfaceName : utun7
        }
        """
        #expect(NetworkCompatibility.interfaceName(in: output) == "utun7")
        #expect(NetworkCompatibility.interfaceName(in: "Disconnected") == nil)
    }

    @Test func shadowrocketPortRequiresOwnedListener() {
        let shadowrocket = "tcp4 0 0 127.0.0.1.1087 *.* LISTEN /Applications/Shadowrocket.app/PacketTunnel:1234"
        let clash = "tcp4 0 0 127.0.0.1.7897 *.* LISTEN verge-mihomo:2008"
        #expect(NetworkCompatibility.shadowrocketOwnsListeningPort(1087, netstatOutput: shadowrocket))
        #expect(!NetworkCompatibility.shadowrocketOwnsListeningPort(1087, netstatOutput: shadowrocket.replacingOccurrences(of: ".1087", with: ".10870")))
        #expect(!NetworkCompatibility.shadowrocketOwnsListeningPort(7897, netstatOutput: clash))
        #expect(!NetworkCompatibility.shadowrocketOwnsListeningPort(1087, netstatOutput: "tcp4 0 0 127.0.0.1.1087 127.0.0.1.5000 ESTABLISHED PacketTunnel:1234"))
        #expect(!NetworkCompatibility.shadowrocketOwnsListeningPort(1087, netstatOutput: "tcp4 0 0 127.0.0.1.1087 *.* LISTEN PacketTunnel:1234"))
        #expect(NetworkCompatibility.isShadowrocketExecutablePath("/Applications/Shadowrocket.app/Contents/PlugIns/PacketTunnel.appex/Contents/MacOS/PacketTunnel"))
        #expect(!NetworkCompatibility.isShadowrocketExecutablePath("/Applications/OtherVPN.app/Contents/PlugIns/PacketTunnel"))
    }

    @Test func managedEnvironmentCleanupPreservesUserContent() {
        let content = """
        KEEP=1
        # === 蝉舒宝 managed proxy environment ===
        export HTTP_PROXY=http://127.0.0.1:7897
        # === End 蝉舒宝 managed proxy environment ===
        ALSO_KEEP=2
        """
        #expect(NetworkCompatibility.removingManagedEnvironmentBlocks(from: content) == "KEEP=1\nALSO_KEEP=2")
        #expect(NetworkCompatibility.removingManagedEnvironmentBlocks(from: "# === 蝉舒宝 managed proxy environment ===\nvalue") == nil)
    }

    @Test func managedClashCleanupRemovesOnlyOwnedEntries() {
        let content = """
        fake-ip-filter:
          - '+.example.com'
          - '+.keep.example'
        nameserver-policy:
            '+.example.com': system
        rules:
        - DOMAIN-SUFFIX,example.com,DIRECT
        - IP-CIDR,197.19.0.0/16,DIRECT,no-resolve
        - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
        """
        let cleaned = NetworkCompatibility.removingManagedClashEntries(from: content, companyDomains: ["example.com"])
        #expect(!NetworkCompatibility.containsManagedClashEntries(cleaned, companyDomains: ["example.com"]))
        #expect(cleaned.contains("+.keep.example"))
        #expect(cleaned.contains("10.0.0.0/8"))
    }

    @Test func companyRouteMustBeSpecificAndMustNotUseShadowrocketInterface() {
        let companyRoute = """
           destination: 197.19.0.1
             interface: utun6
                 flags: <UP,HOST,DONE,WASCLONED,IFSCOPE,IFREF>
        """
        let clashHalfInternetRoute = """
           destination: 197.19.0.1
             interface: utun1024
                 flags: <UP,HOST,DONE,WASCLONED,IFSCOPE,IFREF>
        """
        let companyRoutingTable = """
        Destination        Gateway            Flags        Netif
        default            192.168.1.1        UGScg        en0
        197.19.0/16        utun6              USc          utun6
        """
        let clashRoutingTable = """
        Destination        Gateway            Flags        Netif
        0/1                utun1024           USc          utun1024
        128.0/1            utun1024           USc          utun1024
        """
        #expect(NetworkCompatibility.specificVirtualRouteInterface(for: "197.19.0.1", routeOutput: companyRoute, routingTableOutput: companyRoutingTable) == "utun6")
        #expect(NetworkCompatibility.specificVirtualRouteInterface(for: "197.19.0.1", routeOutput: clashHalfInternetRoute, routingTableOutput: clashRoutingTable) == nil)
        #expect(NetworkCompatibility.specificVirtualRouteInterface(for: "197.19.0.1", routeOutput: companyRoute, routingTableOutput: companyRoutingTable, excluding: ["utun6"]) == nil)
        #expect(NetworkCompatibility.specificVirtualRouteInterface(for: "197.19.0.1", routeOutput: "destination: default\ninterface: utun9", routingTableOutput: companyRoutingTable) == nil)
    }

    @Test func physicalServicesExcludeVPNAndDisabledServices() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) *USB LAN
        (Hardware Port: USB LAN, Device: en7)

        (3) Shadowrocket
        (Hardware Port: com.liguangming.Shadowrocket, Device: )
        """
        #expect(NetworkCompatibility.physicalNetworkServices(from: output) == [PhysicalNetworkService(name: "Wi-Fi", device: "en0")])
    }

    @Test func ipv4ValidationChecksOctetRange() {
        #expect(NetworkCompatibility.isValidIPv4("197.19.0.12"))
        #expect(!NetworkCompatibility.isValidIPv4("999.19.0.12"))
        #expect(!NetworkCompatibility.isValidIPv4("1.2.3"))
    }
}
