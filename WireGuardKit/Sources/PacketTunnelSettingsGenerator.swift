// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.

import Foundation
import Network
import NetworkExtension

#if SWIFT_PACKAGE
import WireGuardKitC
#endif

/// A type alias for `Result` type that holds a tuple with source and resolved endpoint.
typealias EndpointResolutionResult = Result<(Endpoint, Endpoint), DNSResolutionError>

class PacketTunnelSettingsGenerator {
    let tunnelConfiguration: TunnelConfiguration
    let resolvedEndpoints: [Endpoint?]

    init(tunnelConfiguration: TunnelConfiguration, resolvedEndpoints: [Endpoint?]) {
        self.tunnelConfiguration = tunnelConfiguration
        self.resolvedEndpoints = resolvedEndpoints
    }

    func endpointUapiConfiguration() -> (String, [EndpointResolutionResult?]) {
        var resolutionResults = [EndpointResolutionResult?]()
        var wgSettings = ""

        assert(tunnelConfiguration.peers.count == resolvedEndpoints.count)
        for (peer, resolvedEndpoint) in zip(self.tunnelConfiguration.peers, self.resolvedEndpoints) {
            wgSettings.append("public_key=\(peer.publicKey.hexKey)\n")

            let result = resolvedEndpoint.map(Self.reresolveEndpoint)
            if case .success((_, let resolvedEndpoint)) = result {
                if case .name = resolvedEndpoint.host { assert(false, "Endpoint is not resolved") }
                wgSettings.append("endpoint=\(resolvedEndpoint.stringRepresentation)\n")
            }
            resolutionResults.append(result)
        }

        return (wgSettings, resolutionResults)
    }

    func uapiConfiguration() -> (String, [EndpointResolutionResult?]) {
        var resolutionResults = [EndpointResolutionResult?]()
        var wgSettings = ""
        wgSettings.append("private_key=\(tunnelConfiguration.interface.privateKey.hexKey)\n")
        if let listenPort = tunnelConfiguration.interface.listenPort {
            wgSettings.append("listen_port=\(listenPort)\n")
        }

        if let junkPacketCount = tunnelConfiguration.interface.junkPacketCount {
            wgSettings.append("jc=\(junkPacketCount)\n")
        }
        if let junkPacketMinSize = tunnelConfiguration.interface.junkPacketMinSize {
            wgSettings.append("jmin=\(junkPacketMinSize)\n")
        }
        if let junkPacketMaxSize = tunnelConfiguration.interface.junkPacketMaxSize {
            wgSettings.append("jmax=\(junkPacketMaxSize)\n")
        }
        if let initPacketJunkSize = tunnelConfiguration.interface.initPacketJunkSize {
            wgSettings.append("s1=\(initPacketJunkSize)\n")
        }
        if let responsePacketJunkSize = tunnelConfiguration.interface.responsePacketJunkSize {
            wgSettings.append("s2=\(responsePacketJunkSize)\n")
        }
        if let cookieReplyPacketJunkSize = tunnelConfiguration.interface.cookieReplyPacketJunkSize {
            wgSettings.append("s3=\(cookieReplyPacketJunkSize)\n")
        }
        if let transportPacketJunkSize = tunnelConfiguration.interface.transportPacketJunkSize {
            wgSettings.append("s4=\(transportPacketJunkSize)\n")
        }
        if let initPacketMagicHeader = tunnelConfiguration.interface.initPacketMagicHeader {
            wgSettings.append("h1=\(initPacketMagicHeader)\n")
        }
        if let responsePacketMagicHeader = tunnelConfiguration.interface.responsePacketMagicHeader {
            wgSettings.append("h2=\(responsePacketMagicHeader)\n")
        }
        if let underloadPacketMagicHeader = tunnelConfiguration.interface.underloadPacketMagicHeader {
            wgSettings.append("h3=\(underloadPacketMagicHeader)\n")
        }
        if let transportPacketMagicHeader = tunnelConfiguration.interface.transportPacketMagicHeader {
            wgSettings.append("h4=\(transportPacketMagicHeader)\n")
        }
        if let specialJunk1 = tunnelConfiguration.interface.specialJunk1 {
            wgSettings.append("i1=\(specialJunk1)\n")
        }
        if let specialJunk2 = tunnelConfiguration.interface.specialJunk2 {
            wgSettings.append("i2=\(specialJunk2)\n")
        }
        if let specialJunk3 = tunnelConfiguration.interface.specialJunk3 {
            wgSettings.append("i3=\(specialJunk3)\n")
        }
        if let specialJunk4 = tunnelConfiguration.interface.specialJunk4 {
            wgSettings.append("i4=\(specialJunk4)\n")
        }
        if let specialJunk5 = tunnelConfiguration.interface.specialJunk5 {
            wgSettings.append("i5=\(specialJunk5)\n")
        }
        if let headerProtectionKey = tunnelConfiguration.interface.headerProtectionKey {
            wgSettings.append("header_protection_key=\(headerProtectionKey.hexKey)\n")
        }
        if let contentPaddingAddition = tunnelConfiguration.interface.contentPaddingAddition,
           !contentPaddingAddition.isEmpty {
            wgSettings.append("content_padding_addition=\(contentPaddingAddition)\n")
        }
        if let rekeyAfterTime = tunnelConfiguration.interface.rekeyAfterTime, !rekeyAfterTime.isEmpty {
            wgSettings.append("rekey_after_time=\(rekeyAfterTime)\n")
        }
        if let rekeyTimeout = tunnelConfiguration.interface.rekeyTimeout, !rekeyTimeout.isEmpty {
            wgSettings.append("rekey_timeout=\(rekeyTimeout)\n")
        }
        if let rejectAfterTime = tunnelConfiguration.interface.rejectAfterTime, !rejectAfterTime.isEmpty {
            wgSettings.append("reject_after_time=\(rejectAfterTime)\n")
        }
        if let keepaliveTimeout = tunnelConfiguration.interface.keepaliveTimeout, !keepaliveTimeout.isEmpty {
            wgSettings.append("keepalive_timeout=\(keepaliveTimeout)\n")
        }
        if let maxHandshakeAttempts = tunnelConfiguration.interface.maxHandshakeAttempts,
           !maxHandshakeAttempts.isEmpty {
            wgSettings.append("max_handshake_attempts=\(maxHandshakeAttempts)\n")
        }
        if let randomTrailers = tunnelConfiguration.interface.randomTrailers, !randomTrailers.isEmpty {
            wgSettings.append("random_trailers=\(Self.uapiBool(randomTrailers))\n")
        }
        if let disableCookies = tunnelConfiguration.interface.disableCookies, !disableCookies.isEmpty {
            wgSettings.append("disable_cookies=\(Self.uapiBool(disableCookies))\n")
        }
        if !tunnelConfiguration.peers.isEmpty {
            wgSettings.append("replace_peers=true\n")
        }
        assert(tunnelConfiguration.peers.count == resolvedEndpoints.count)
        for (peer, resolvedEndpoint) in zip(self.tunnelConfiguration.peers, self.resolvedEndpoints) {
            wgSettings.append("public_key=\(peer.publicKey.hexKey)\n")
            if let preSharedKey = peer.preSharedKey?.hexKey {
                wgSettings.append("preshared_key=\(preSharedKey)\n")
            }

            let result = resolvedEndpoint.map(Self.reresolveEndpoint)
            if case .success((_, let resolvedEndpoint)) = result {
                if case .name = resolvedEndpoint.host { assert(false, "Endpoint is not resolved") }
                wgSettings.append("endpoint=\(resolvedEndpoint.stringRepresentation)\n")
            }
            resolutionResults.append(result)

            let persistentKeepAlive = peer.persistentKeepAlive ?? "0"
            wgSettings.append("persistent_keepalive_interval=\(persistentKeepAlive)\n")
            if !peer.allowedIPs.isEmpty {
                wgSettings.append("replace_allowed_ips=true\n")
                peer.allowedIPs.forEach { wgSettings.append("allowed_ip=\($0.stringRepresentation)\n") }
            }
        }
        return (wgSettings, resolutionResults)
    }

    /// WG VPN: same addresses and MTU, but no routes and no DNS into the tunnel.
    func generatePassthroughNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let mtu = tunnelConfiguration.interface.mtu ?? 0
        networkSettings.mtu = NSNumber(value: mtu == 0 ? 1280 : Int(mtu))

        let (ipv4Addresses, ipv6Addresses) = addresses()
        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses.map { $0.destinationAddress }, subnetMasks: ipv4Addresses.map { $0.destinationSubnetMask })
        ipv4Settings.includedRoutes = []
        networkSettings.ipv4Settings = ipv4Settings

        let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses.map { $0.destinationAddress }, networkPrefixLengths: ipv6Addresses.map { $0.destinationNetworkPrefixLength })
        ipv6Settings.includedRoutes = []
        networkSettings.ipv6Settings = ipv6Settings
        return networkSettings
    }

    func generateNetworkSettings(encryptedDNS: EncryptedDNSSettings?) -> NEPacketTunnelNetworkSettings {
        let networkSettings = generateNetworkSettings()
        guard let encryptedDNS = encryptedDNS, encryptedDNS.isUsable else { return networkSettings }
        var servers = tunnelConfiguration.interface.dns.map { $0.stringRepresentation }
        if servers.isEmpty { servers = encryptedDNS.bootstrapServers }
        guard !servers.isEmpty else { return networkSettings }
        let dnsSettings: NEDNSSettings
        switch encryptedDNS.kind {
        case .https:
            let doh = NEDNSOverHTTPSSettings(servers: servers)
            doh.serverURL = URL(string: encryptedDNS.value)
            dnsSettings = doh
        case .tls:
            let dot = NEDNSOverTLSSettings(servers: servers)
            dot.serverName = encryptedDNS.value
            dnsSettings = dot
        }
        dnsSettings.searchDomains = tunnelConfiguration.interface.dnsSearch
        dnsSettings.matchDomains = [""]
        networkSettings.dnsSettings = dnsSettings
        return networkSettings
    }

    func generateNetworkSettings() -> NEPacketTunnelNetworkSettings {
        /* iOS requires a tunnel endpoint, whereas in WireGuard it's valid for
         * a tunnel to have no endpoint, or for there to be many endpoints, in
         * which case, displaying a single one in settings doesn't really
         * make sense. So, we fill it in with this placeholder, which is not
         * a valid IP address that will actually route over the Internet.
         */
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if !tunnelConfiguration.interface.dnsSearch.isEmpty || !tunnelConfiguration.interface.dns.isEmpty {
            let dnsServerStrings = tunnelConfiguration.interface.dns.map { $0.stringRepresentation }
            let dnsSettings = NEDNSSettings(servers: dnsServerStrings)
            dnsSettings.searchDomains = tunnelConfiguration.interface.dnsSearch
            if !tunnelConfiguration.interface.dns.isEmpty {
                dnsSettings.matchDomains = [""] // All DNS queries must first go through the tunnel's DNS
            }
            networkSettings.dnsSettings = dnsSettings
        }

        let mtu = tunnelConfiguration.interface.mtu ?? 0

        /* 0 means automatic MTU. In theory, we should just do
         * `networkSettings.tunnelOverheadBytes = 80` but in
         * practice there are too many broken networks out there.
         * Instead set it to 1280. Boohoo. Maybe someday we'll
         * add a nob, maybe, or iOS will do probing for us.
         */
        if mtu == 0 {
            #if os(iOS)
            networkSettings.mtu = NSNumber(value: 1280)
            #elseif os(macOS)
            networkSettings.tunnelOverheadBytes = 80
            #else
            #error("Unimplemented")
            #endif
        } else {
            networkSettings.mtu = NSNumber(value: mtu)
        }

        let (ipv4Addresses, ipv6Addresses) = addresses()
        let (ipv4IncludedRoutes, ipv6IncludedRoutes) = includedRoutes()
        let (ipv4ExcludedRoutes, ipv6ExcludedRoutes) = excludedRoutes()

        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses.map { $0.destinationAddress }, subnetMasks: ipv4Addresses.map { $0.destinationSubnetMask })
        ipv4Settings.includedRoutes = ipv4IncludedRoutes
        ipv4Settings.excludedRoutes = ipv4ExcludedRoutes
        networkSettings.ipv4Settings = ipv4Settings

        let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses.map { $0.destinationAddress }, networkPrefixLengths: ipv6Addresses.map { $0.destinationNetworkPrefixLength })
        ipv6Settings.includedRoutes = ipv6IncludedRoutes
        ipv6Settings.excludedRoutes = ipv6ExcludedRoutes
        networkSettings.ipv6Settings = ipv6Settings

        return networkSettings
    }

    private func addresses() -> ([NEIPv4Route], [NEIPv6Route]) {
        var ipv4Routes = [NEIPv4Route]()
        var ipv6Routes = [NEIPv6Route]()
        for addressRange in tunnelConfiguration.interface.addresses {
            if addressRange.address is IPv4Address {
                ipv4Routes.append(NEIPv4Route(destinationAddress: "\(addressRange.address)", subnetMask: "\(addressRange.subnetMask())"))
            } else if addressRange.address is IPv6Address {
                /* Big fat ugly hack for broken iOS networking stack: the smallest prefix that will have
                 * any effect on iOS is a /120, so we clamp everything above to /120. This is potentially
                 * very bad, if various network parameters were actually relying on that subnet being
                 * intentionally small. TODO: talk about this with upstream iOS devs.
                 */
                ipv6Routes.append(NEIPv6Route(destinationAddress: "\(addressRange.address)", networkPrefixLength: NSNumber(value: min(120, addressRange.networkPrefixLength))))
            }
        }
        return (ipv4Routes, ipv6Routes)
    }

    private func includedRoutes() -> ([NEIPv4Route], [NEIPv6Route]) {
        var ipv4IncludedRoutes = [NEIPv4Route]()
        var ipv6IncludedRoutes = [NEIPv6Route]()

        for addressRange in tunnelConfiguration.interface.addresses {
            if addressRange.address is IPv4Address {
                let route = NEIPv4Route(destinationAddress: "\(addressRange.maskedAddress())", subnetMask: "\(addressRange.subnetMask())")
                route.gatewayAddress = "\(addressRange.address)"
                ipv4IncludedRoutes.append(route)
            } else if addressRange.address is IPv6Address {
                let route = NEIPv6Route(destinationAddress: "\(addressRange.maskedAddress())", networkPrefixLength: NSNumber(value: addressRange.networkPrefixLength))
                route.gatewayAddress = "\(addressRange.address)"
                ipv6IncludedRoutes.append(route)
            }
        }

        for peer in tunnelConfiguration.peers {
            for addressRange in peer.allowedIPs {
                if addressRange.address is IPv4Address {
                    ipv4IncludedRoutes.append(NEIPv4Route(destinationAddress: "\(addressRange.address)", subnetMask: "\(addressRange.subnetMask())"))
                } else if addressRange.address is IPv6Address {
                    ipv6IncludedRoutes.append(NEIPv6Route(destinationAddress: "\(addressRange.address)", networkPrefixLength: NSNumber(value: addressRange.networkPrefixLength)))
                }
            }
        }
        return (ipv4IncludedRoutes, ipv6IncludedRoutes)
    }

    private func excludedRoutes() -> ([NEIPv4Route], [NEIPv6Route]) {
        var ipv4ExcludedRoutes = [NEIPv4Route]()
        var ipv6ExcludedRoutes = [NEIPv6Route]()
        for endpoint in resolvedEndpoints {
            guard let endpoint = endpoint else { continue }
            switch endpoint.host {
            case .ipv4(let address):
                ipv4ExcludedRoutes.append(NEIPv4Route(destinationAddress: "\(address)", subnetMask: "255.255.255.255"))
            case .ipv6(let address):
                ipv6ExcludedRoutes.append(NEIPv6Route(destinationAddress: "\(address)", networkPrefixLength: NSNumber(value: UInt8(128))))
            default:
                fatalError()
            }
        }

        for peer in tunnelConfiguration.peers {
            for addressRange in peer.excludeIPs {
                if addressRange.address is IPv4Address {
                    ipv4ExcludedRoutes.append(NEIPv4Route(destinationAddress: "\(addressRange.address)", subnetMask: "\(addressRange.subnetMask())"))
                } else if addressRange.address is IPv6Address {
                    ipv6ExcludedRoutes.append(NEIPv6Route(destinationAddress: "\(addressRange.address)", networkPrefixLength: NSNumber(value: addressRange.networkPrefixLength)))
                }
            }
        }

        return (ipv4ExcludedRoutes, ipv6ExcludedRoutes)
    }

    /// Converts awg-quick on/off (and 0/1/true/false) to UAPI 1/0.
    /// amneziawg-go uses strconv.ParseBool and rejects "on"/"off".
    private class func uapiBool(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "1", "true", "t", "yes":
            return "1"
        default:
            return "0"
        }
    }

    private class func reresolveEndpoint(endpoint: Endpoint) -> EndpointResolutionResult {
        return Result { (endpoint, try endpoint.withReresolvedIP()) }
            .mapError { error -> DNSResolutionError in
                // swiftlint:disable:next force_cast
                return error as! DNSResolutionError
            }
    }
}

/// WG VPN: DNS-over-HTTPS / DNS-over-TLS on top of the tunnel's DNS servers.
public struct EncryptedDNSSettings: Codable, Equatable {
    public enum Kind: String, Codable {
        case https
        case tls
    }

    public var kind: Kind
    /// DoH: https URL (e.g. https://cloudflare-dns.com/dns-query). DoT: server name (e.g. one.one.one.one).
    public var value: String
    /// Used when the tunnel configuration has no DNS server of its own.
    public var bootstrapServers: [String]

    public init(kind: Kind, value: String, bootstrapServers: [String] = []) {
        self.kind = kind
        self.value = value
        self.bootstrapServers = bootstrapServers
    }

    public var isUsable: Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .https:
            return trimmed.lowercased().hasPrefix("https://") && URL(string: trimmed) != nil
        case .tls:
            return !trimmed.isEmpty
        }
    }
}
