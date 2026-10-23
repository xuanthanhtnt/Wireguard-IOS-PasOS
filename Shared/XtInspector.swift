// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS — endpoint inspection shared by the extension and the app
// (port of inspectTunnel() in the Android ServerWatchdogCoordinator)

import Foundation
import Network

struct EndpointChange: Equatable {
    var peerKey: String
    var port: Int
    var staticEndpoint: Bool
    var oldIps: [String]
    var newIp: String
    var source: String

    var endpointString: String { XtIp.formatEndpoint(ip: newIp, port: port) }
}

struct Inspection {
    var statuses: [EndpointStatus] = []
    var changes: [EndpointChange] = []
}

extension Endpoint {
    /// Hostname or IP literal, without brackets.
    var hostString: String {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        @unknown default: return "\(host)"
        }
    }

    var portNumber: Int { Int(port.rawValue) }
}

enum XtInspector {
    /// Looks up the server address of every peer.
    ///
    /// - Parameters:
    ///   - currentIps: the IPs a peer is using right now (empty when unknown).
    ///   - knownIps: fallback "current" IPs remembered while paused.
    ///   - failing: the tunnel cannot reach its server; trust public DNS over a stale local cache.
    static func inspect(
        config: TunnelConfiguration,
        tunnelId: String,
        tunnelName: String,
        settings: XtSettings,
        currentIps: (PeerConfiguration) -> [String],
        knownIps: [String: [String]] = [:],
        failing: Bool,
        path: PhysicalPath
    ) async -> Inspection {
        var inspection = Inspection()
        for peer in config.peers {
            guard let endpoint = peer.endpoint else { continue }
            let peerKey = peer.publicKey.base64Key
            let host = endpoint.hostString
            let isStatic = endpoint.hasHostAsIPAddress()
            let configured = settings.ipSources[tunnelId]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source: String? = isStatic ? ((configured?.isEmpty ?? true) ? nil : configured) : XtIp.stripBrackets(host)
            var current = currentIps(peer)
            if current.isEmpty {
                current = (knownIps[peerKey] ?? []).map { XtIp.normalize($0) }
            }
            guard let lookupSource = source else {
                inspection.statuses.append(EndpointStatus(
                    tunnelId: tunnelId, tunnelName: tunnelName, peerKey: peerKey, endpointHost: host,
                    source: nil, currentIps: current, resolvedIps: [], checkedAt: Date()
                ))
                continue
            }
            let lookup = await XtNetwork.lookup(lookupSource, useDoh: settings.useDoh, current: current, forceDoh: failing, path: path)
            // The server is unreachable on the address the local DNS still returns, while public DNS
            // already knows another one: trust public DNS. Never done while the tunnel is healthy, so
            // LAN / split-horizon DNS setups are not affected.
            let staleLocalDns = failing && !lookup.doh.isEmpty && !current.isEmpty && current.allSatisfy { !lookup.doh.contains($0) }
            let status = EndpointStatus(
                tunnelId: tunnelId, tunnelName: tunnelName, peerKey: peerKey, endpointHost: host,
                source: lookupSource, currentIps: current, resolvedIps: lookup.all, checkedAt: Date(),
                error: lookup.error, staleLocalDns: staleLocalDns
            )
            inspection.statuses.append(status)
            if status.changed {
                let candidates = staleLocalDns ? lookup.doh : lookup.all.filter { !current.contains($0) }
                if let newIp = XtIp.pickPreferred(candidates, current: current) {
                    inspection.changes.append(EndpointChange(
                        peerKey: peerKey, port: endpoint.portNumber, staticEndpoint: isStatic,
                        oldIps: current, newIp: newIp, source: lookupSource
                    ))
                }
            }
        }
        return inspection
    }

    /// Returns `config` with the given peer endpoints ("ip:port" by base64 public key) replaced.
    static func applying(_ endpoints: [String: String], to config: TunnelConfiguration) -> TunnelConfiguration {
        guard !endpoints.isEmpty else { return config }
        let peers = config.peers.map { peer -> PeerConfiguration in
            guard let value = endpoints[peer.publicKey.base64Key], let endpoint = Endpoint(from: value) else { return peer }
            var copy = peer
            copy.endpoint = endpoint
            return copy
        }
        return TunnelConfiguration(name: config.name, interface: config.interface, peers: peers)
    }
}
