// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var adapter: WireGuardAdapter = {
        WireGuardAdapter(with: self) { level, message in
            switch level {
            case .error: XtLog.error("wg: \(message)")
            case .verbose: XtLog.debug("wg: \(message)")
            }
        }
    }()

    private var watchdog: ServerWatchdog?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let source = (options?[WGVPNKeys.startSource] as? String).flatMap(StartSource.init(rawValue:))
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let text = proto.providerConfiguration?[WGVPNKeys.wgQuickConfig] as? String else {
            XtLog.error("Start failed: no saved configuration")
            completionHandler(TunnelStartError.invalidConfiguration)
            return
        }
        let name = (proto.providerConfiguration?[WGVPNKeys.tunnelName] as? String) ?? "WG VPN"
        let tunnelId = (proto.providerConfiguration?[WGVPNKeys.tunnelId] as? String) ?? name
        let config: TunnelConfiguration
        do {
            config = try TunnelConfiguration(fromWgQuickConfig: text, called: name)
        } catch {
            XtLog.error("Start failed: invalid configuration (\(error))")
            completionHandler(TunnelStartError.invalidConfiguration)
            return
        }

        XtLog.info("Starting tunnel \(name) (source: \(source?.rawValue ?? "system"), kill switch: \(proto.includeAllNetworks))")
        let mode = ServerWatchdog.startMode(tunnelId: tunnelId, source: source)
        let prepared = ServerWatchdog.prepare(config: config, tunnelId: tunnelId)

        if let data = proto.providerConfiguration?[WGVPNKeys.encryptedDNS] as? Data,
           let dns = try? JSONDecoder().decode(EncryptedDNSSettings.self, from: data), dns.isUsable {
            adapter.encryptedDNS = dns
        }

        let startConfig = XtInspector.applying(prepared.overrides, to: prepared.base)
        adapter.start(tunnelConfiguration: startConfig) { [weak self] adapterError in
            guard let self = self else { return }
            if let adapterError = adapterError {
                let error = Self.map(adapterError)
                XtLog.error("Start failed: \(error.errorDescription ?? error.rawValue)")
                XtStore.shared.setLastError(.init(tunnelId: tunnelId, message: error.errorDescription ?? "", at: Date()))
                completionHandler(error)
                return
            }
            XtStore.shared.setLastError(nil)
            XtLog.info("Tunnel interface is \(self.adapter.interfaceName ?? "unknown")")
            let dog = ServerWatchdog(
                provider: self, adapter: self.adapter, tunnelId: tunnelId, tunnelName: name,
                prepared: prepared, killSwitch: proto.includeAllNetworks, mode: mode
            )
            self.watchdog = dog
            dog.start()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        XtLog.info("Stopping tunnel, reason \(reason.rawValue)")
        watchdog?.stop()
        watchdog = nil
        XtStore.shared.setRuntime(nil)
        adapter.stop { error in
            if let error = error { XtLog.error("Failed to stop WireGuard adapter: \(error)") }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let completionHandler = completionHandler else { return }
        if messageData.count == 1 && messageData[0] == 0 {
            adapter.getRuntimeConfiguration { settings in
                completionHandler(settings?.data(using: .utf8))
            }
            return
        }
        guard let message = try? JSONDecoder().decode(XtCommandMessage.self, from: messageData) else {
            completionHandler(nil)
            return
        }
        completionHandler(watchdog?.handle(message.command))
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        watchdog?.deviceWillSleep()
        completionHandler()
    }

    override func wake() {
        watchdog?.deviceDidWake()
    }

    private static func map(_ error: WireGuardAdapterError) -> TunnelStartError {
        switch error {
        case .cannotLocateTunnelFileDescriptor: return .couldNotDetermineFileDescriptor
        case .dnsResolution: return .dnsResolutionFailure
        case .setNetworkSettings: return .couldNotSetNetworkSettings
        case .startWireGuardBackend: return .couldNotStartBackend
        case .invalidState: return .couldNotStartBackend
        }
    }
}
