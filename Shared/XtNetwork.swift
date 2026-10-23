// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS — port of the Android xt/XtNetwork.kt
//
// Network helpers that deliberately go around the tunnel. Every request here is pinned to the
// physical interface (Wi-Fi / cellular / wired) with Network.framework, and DNS lookups are scoped
// to that interface with DNS-SD, so a dead tunnel can never swallow them.

import Foundation
import Network
import Security

struct XtLookupResult {
    var system: [String] = []
    var doh: [String] = []
    var error: String?

    var all: [String] { XtIp.unique(system + doh) }
}

enum XtNetError: Error, LocalizedError {
    case message(String)
    case timeout
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .timeout: return "hết thời gian chờ"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

/// The current non-tunnel network.
struct PhysicalPath {
    var interface: NWInterface?
    var satisfied: Bool
    var description: String

    static let none = PhysicalPath(interface: nil, satisfied: false, description: "none")

    init(interface: NWInterface?, satisfied: Bool, description: String) {
        self.interface = interface
        self.satisfied = satisfied
        self.description = description
    }

    init(_ path: NWPath) {
        let physicalTypes: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        let physical = path.availableInterfaces.first { physicalTypes.contains($0.type) }
        self.interface = physical
        self.satisfied = path.status == .satisfied && physical != nil
        self.description = physical.map { "\($0.name) (\($0.type))" } ?? "none"
    }

    var interfaceIndex: UInt32 { interface.map { UInt32($0.index) } ?? 0 }
}

/// Keeps track of the physical network and reports changes.
final class PhysicalNetworkMonitor {
    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
    private let queue = DispatchQueue(label: "com.wgvpn.physical-path")
    private let lock = NSLock()
    private var path = PhysicalPath.none
    private var started = false

    var current: PhysicalPath {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    func start(onChange: @escaping (PhysicalPath, PhysicalPath) -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] nwPath in
            guard let self = self else { return }
            let new = PhysicalPath(nwPath)
            self.lock.lock()
            let old = self.path
            self.path = new
            self.lock.unlock()
            if old.description != new.description || old.satisfied != new.satisfied {
                onChange(old, new)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }

    /// One-shot lookup of the physical path.
    static func currentPath(timeout: TimeInterval = 2) async -> PhysicalPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
            let queue = DispatchQueue(label: "com.wgvpn.physical-path.once")
            let once = OnceBox<PhysicalPath> { path in
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.pathUpdateHandler = { nwPath in once.fire(PhysicalPath(nwPath)) }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.fire(.none) }
        }
    }
}

/// Runs its action at most once, from whichever thread gets there first.
final class OnceBox<T> {
    private let lock = NSLock()
    private var done = false
    private let action: (T) -> Void

    init(_ action: @escaping (T) -> Void) {
        self.action = action
    }

    func fire(_ value: T) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        action(value)
    }
}

enum XtNetwork {
    private struct DohResolver {
        let ip: String
        let serverName: String
        let path: String
    }

    private static let dohResolvers = [
        DohResolver(ip: "1.1.1.1", serverName: "cloudflare-dns.com", path: "/dns-query"),
        DohResolver(ip: "8.8.8.8", serverName: "dns.google", path: "/resolve"),
    ]

    /// Looks up `source`: a hostname (system DNS on the physical network + optional DoH) or an
    /// http(s) URL returning an IP.
    ///
    /// DoH is skipped when the system answer already confirms an address in `current` and the tunnel
    /// is not failing (`forceDoh` false): it could not change the outcome.
    static func lookup(_ source: String, useDoh: Bool, current: [String], forceDoh: Bool, path: PhysicalPath) async -> XtLookupResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            do {
                let ips = try await fetchIps(from: trimmed, path: path)
                return ips.isEmpty ? XtLookupResult(error: "không có IP trong phản hồi") : XtLookupResult(system: ips)
            } catch {
                return XtLookupResult(error: describe(error))
            }
        }
        if XtIp.isIPLiteral(trimmed) {
            return XtLookupResult(system: [XtIp.normalize(trimmed)])
        }
        let host = XtIp.stripBrackets(trimmed)
        var error: String?
        var system = [String]()
        do {
            system = try await resolveSystem(host, interfaceIndex: path.interfaceIndex)
        } catch let e {
            error = describe(e)
        }
        let systemConfirmsCurrent = !system.isEmpty && system.contains { current.contains($0) }
        var doh = [String]()
        if useDoh && (forceDoh || !systemConfirmsCurrent) {
            do {
                doh = try await resolveDoh(host, path: path)
            } catch let e {
                if error == nil { error = describe(e) }
            }
        }
        return XtLookupResult(system: system, doh: doh, error: system.isEmpty && doh.isEmpty ? error : nil)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        if let e = error as? NWError { return e.debugDescription }
        return error.localizedDescription
    }

    // MARK: - DNS

    /// Resolves `host` with the DNS servers of the given interface (0 = any), bypassing the tunnel.
    static func resolveSystem(_ host: String, interfaceIndex: UInt32, timeout: TimeInterval = 5) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DNSSDLookup(host: host, interfaceIndex: interfaceIndex, timeout: timeout) { result in
                continuation.resume(with: result)
            }.start()
        }
    }

    /// DNS-over-HTTPS lookup (Cloudflare, then Google) over the physical network.
    static func resolveDoh(_ host: String, path: PhysicalPath) async throws -> [String] {
        var lastError: Error?
        for resolver in dohResolvers {
            do {
                let v4 = try await dohQuery(resolver, host: host, type: "A", path: path)
                let v6 = (try? await dohQuery(resolver, host: host, type: "AAAA", path: path)) ?? []
                return XtIp.unique(v4 + v6)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? XtNetError.message("DoH thất bại")
    }

    private static func dohQuery(_ resolver: DohResolver, host: String, type: String, path: PhysicalPath) async throws -> [String] {
        let name = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
        let response = try await MiniHTTP.request(
            host: resolver.ip, port: 443, tls: true, tlsServerName: resolver.serverName,
            path: "\(resolver.path)?name=\(name)&type=\(type)", hostHeader: resolver.serverName,
            accept: "application/dns-json", interface: path.interface
        )
        guard (200..<300).contains(response.status) else { throw XtNetError.http(response.status) }
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw XtNetError.message("DoH: phản hồi không hợp lệ")
        }
        let wanted = type == "A" ? 1 : 28
        let answers = json["Answer"] as? [[String: Any]] ?? []
        return answers.compactMap { answer -> String? in
            guard (answer["type"] as? NSNumber)?.intValue == wanted, let data = answer["data"] as? String,
                  XtIp.isIPLiteral(data) else { return nil }
            return XtIp.normalize(data)
        }
    }

    private static func fetchIps(from urlString: String, path: PhysicalPath) async throws -> [String] {
        guard let url = URL(string: urlString) else { throw XtNetError.message("URL không hợp lệ") }
        let response = try await MiniHTTP.get(url, accept: "text/plain", interface: path.interface, followRedirects: 3)
        guard (200..<300).contains(response.status) else { throw XtNetError.http(response.status) }
        return XtIp.extractIps(String(decoding: response.body, as: UTF8.self))
    }

    // MARK: - Reachability

    /// Plain internet access over the physical network. A captive portal never passes.
    static func internetReachable(path: PhysicalPath) async -> Bool {
        if let url = URL(string: "http://captive.apple.com/hotspot-detect.html"),
           let response = try? await MiniHTTP.get(url, accept: "text/html", interface: path.interface),
           response.status == 200,
           String(decoding: response.body, as: UTF8.self).contains("Success") {
            return true
        }
        for check in ["https://connectivitycheck.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204"] {
            if let url = URL(string: check),
               let response = try? await MiniHTTP.get(url, accept: "*/*", interface: path.interface),
               response.status == 204 {
                return true
            }
        }
        return false
    }

    /// TCP connect to ip:port over the physical network.
    static func tcpReachable(_ ip: String, port: Int, path: PhysicalPath, timeout: TimeInterval = 4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let interface = path.interface { parameters.requiredInterface = interface }
        parameters.prohibitedInterfaceTypes = [.other]
        let connection = NWConnection(host: NWEndpoint.Host(XtIp.stripBrackets(ip)), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "com.wgvpn.tcp-probe")
        return await withCheckedContinuation { continuation in
            let once = OnceBox<Bool> { value in
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.fire(true)
                case .failed, .waiting, .cancelled: once.fire(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.fire(false) }
        }
    }

    /// ICMP echo over the physical network (unprivileged datagram ICMP socket).
    static func ping(_ ip: String, path: PhysicalPath, attempts: Int = 3, timeoutMs: Int32 = 2_000) async -> Bool {
        let index = path.interfaceIndex
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ICMPPing.ping(XtIp.stripBrackets(ip), interfaceIndex: index, attempts: attempts, timeoutMs: timeoutMs))
            }
        }
    }
}

// MARK: - DNS-SD scoped lookup

/// getaddrinfo-like lookup bound to one interface's DNS configuration.
private final class DNSSDLookup {
    private let host: String
    private let interfaceIndex: UInt32
    private let timeout: TimeInterval
    private let completion: (Result<[String], Error>) -> Void
    private let queue = DispatchQueue(label: "com.wgvpn.dnssd")
    private var ref: DNSServiceRef?
    private var addresses = [String]()
    private var gotV4 = false
    private var gotV6 = false
    private var finished = false
    private var keepAlive: DNSSDLookup?

    init(host: String, interfaceIndex: UInt32, timeout: TimeInterval, completion: @escaping (Result<[String], Error>) -> Void) {
        self.host = host
        self.interfaceIndex = interfaceIndex
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        queue.async {
            self.keepAlive = self
            var sdRef: DNSServiceRef?
            let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates) | DNSServiceFlags(kDNSServiceFlagsTimeout)
            let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4) | DNSServiceProtocol(kDNSServiceProtocol_IPv6)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = DNSServiceGetAddrInfo(&sdRef, flags, self.interfaceIndex, protocols, self.host, { _, flags, _, errorCode, _, address, _, context in
                guard let context = context else { return }
                let lookup = Unmanaged<DNSSDLookup>.fromOpaque(context).takeUnretainedValue()
                lookup.handle(flags: flags, errorCode: errorCode, address: address)
            }, context)
            guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let sdRef = sdRef else {
                self.finish(.failure(XtNetError.message("DNS lỗi \(status)")))
                return
            }
            self.ref = sdRef
            DNSServiceSetDispatchQueue(sdRef, self.queue)
            self.queue.asyncAfter(deadline: .now() + self.timeout) {
                if self.addresses.isEmpty {
                    self.finish(.failure(XtNetError.timeout))
                } else {
                    self.finish(.success(self.addresses))
                }
            }
        }
    }

    private func handle(flags: DNSServiceFlags, errorCode: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        let family = address.map { Int32($0.pointee.sa_family) }
        switch errorCode {
        case DNSServiceErrorType(kDNSServiceErr_NoError):
            if let address = address, let ip = Self.ipString(address) {
                if !addresses.contains(ip) { addresses.append(ip) }
            }
            markFamily(family)
        case DNSServiceErrorType(kDNSServiceErr_NoSuchRecord):
            markFamily(family)
        case DNSServiceErrorType(kDNSServiceErr_NoSuchName):
            finish(.failure(XtNetError.message("không tồn tại tên miền \(host)")))
            return
        case DNSServiceErrorType(kDNSServiceErr_Timeout):
            finish(addresses.isEmpty ? .failure(XtNetError.timeout) : .success(addresses))
            return
        default:
            finish(addresses.isEmpty ? .failure(XtNetError.message("DNS lỗi \(errorCode)")) : .success(addresses))
            return
        }
        let moreComing = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
        if gotV4 && gotV6 && !moreComing {
            if addresses.isEmpty {
                finish(.failure(XtNetError.message("không có địa chỉ IP cho \(host)")))
            } else {
                finish(.success(addresses))
            }
        }
    }

    private func markFamily(_ family: Int32?) {
        switch family {
        case AF_INET: gotV4 = true
        case AF_INET6: gotV6 = true
        default:
            gotV4 = true
            gotV6 = true
        }
    }

    private func finish(_ result: Result<[String], Error>) {
        guard !finished else { return }
        finished = true
        if let ref = ref {
            DNSServiceRefDeallocate(ref)
            self.ref = nil
        }
        completion(result)
        keepAlive = nil
    }

    static func ipString(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        case AF_INET6:
            var sin6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard inet_ntop(AF_INET6, &sin6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        default:
            return nil
        }
        let ip = XtIp.normalize(String(cString: buffer))
        // Negative answers carry an all-zero address
        if ip == "0.0.0.0" || ip == "::" { return nil }
        return ip
    }
}

// MARK: - Minimal HTTP client pinned to an interface

struct MiniHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
}

enum MiniHTTP {
    static func get(_ url: URL, accept: String, interface: NWInterface?, timeout: TimeInterval = 6, followRedirects: Int = 0) async throws -> MiniHTTPResponse {
        var current = url
        var redirectsLeft = followRedirects
        while true {
            guard let scheme = current.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = current.host else {
                throw XtNetError.message("URL không hợp lệ")
            }
            let tls = scheme == "https"
            let port = UInt16(current.port ?? (tls ? 443 : 80))
            var path = current.path.isEmpty ? "/" : current.path
            if let query = current.query { path += "?\(query)" }
            let hostHeader = (host.contains(":") ? "[\(host)]" : host) + (current.port.map { ":\($0)" } ?? "")
            let response = try await request(
                host: host, port: port, tls: tls, tlsServerName: XtIp.isIPLiteral(host) ? nil : host,
                path: path, hostHeader: hostHeader, accept: accept, interface: interface, timeout: timeout
            )
            if [301, 302, 303, 307, 308].contains(response.status), redirectsLeft > 0,
               let location = response.headers["location"], let next = URL(string: location, relativeTo: current) {
                redirectsLeft -= 1
                current = next.absoluteURL
                continue
            }
            return response
        }
    }

    static func request(host: String, port: UInt16, tls: Bool, tlsServerName: String?, path: String, hostHeader: String,
                        accept: String, interface: NWInterface?, timeout: TimeInterval = 6, maxBytes: Int = 64 * 1024) async throws -> MiniHTTPResponse {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        let parameters: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            if let name = tlsServerName {
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, name)
            }
            parameters = NWParameters(tls: tlsOptions, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        if let interface = interface { parameters.requiredInterface = interface }
        parameters.prohibitedInterfaceTypes = [.other]
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw XtNetError.message("cổng không hợp lệ") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "com.wgvpn.http")
        let request = "GET \(path) HTTP/1.0\r\nHost: \(hostHeader)\r\nUser-Agent: WG VPN\r\nAccept: \(accept)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"

        let buffer = DataBuffer()
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            let once = OnceBox<Result<Data, Error>> { result in
                connection.cancel()
                continuation.resume(with: result)
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let data = data { buffer.append(data) }
                    if buffer.count > maxBytes || isComplete {
                        once.fire(.success(buffer.data))
                    } else if let error = error {
                        once.fire(buffer.count == 0 ? .failure(error) : .success(buffer.data))
                    } else {
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error = error { once.fire(.failure(error)) } else { receive() }
                    })
                case .failed(let error):
                    once.fire(.failure(error))
                case .waiting(let error):
                    once.fire(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.fire(.failure(XtNetError.timeout)) }
        }
        return try parse(raw)
    }

    private final class DataBuffer {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage.count
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private static func parse(_ raw: Data) throws -> MiniHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else { throw XtNetError.message("phản hồi HTTP không hợp lệ") }
        let head = String(decoding: raw[..<range.lowerBound], as: UTF8.self)
        var body = Data(raw[range.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw XtNetError.message("phản hồi HTTP không hợp lệ") }
        var headers = [String: String]()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = dechunk(body)
        }
        return MiniHTTPResponse(status: status, headers: headers, body: body)
    }

    private static func dechunk(_ data: Data) -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: crlf) else { break }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            output.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return output
    }
}

// MARK: - ICMP

private enum ICMPPing {
    private static let ipBoundIf: Int32 = 25      // IP_BOUND_IF
    private static let ipv6BoundIf: Int32 = 125   // IPV6_BOUND_IF

    static func ping(_ ip: String, interfaceIndex: UInt32, attempts: Int, timeoutMs: Int32) -> Bool {
        let isV6 = XtIp.isIPv6(ip)
        let fd = socket(isV6 ? AF_INET6 : AF_INET, SOCK_DGRAM, isV6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if interfaceIndex != 0 {
            var index = interfaceIndex
            _ = setsockopt(fd, isV6 ? IPPROTO_IPV6 : IPPROTO_IP, isV6 ? ipv6BoundIf : ipBoundIf,
                           &index, socklen_t(MemoryLayout<UInt32>.size))
        }

        var storage = sockaddr_storage()
        var length: socklen_t
        if isV6 {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            guard ip.withCString({ inet_pton(AF_INET6, $0, &sin6.sin6_addr) }) == 1 else { return false }
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: sin6, as: sockaddr_in6.self) }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            guard ip.withCString({ inet_pton(AF_INET, $0, &sin.sin_addr) }) == 1 else { return false }
            withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: sin, as: sockaddr_in.self) }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }

        let identifier = UInt16.random(in: 1...UInt16.max)
        for sequence in 0..<attempts {
            var packet = [UInt8](repeating: 0, count: 8 + 24)
            packet[0] = isV6 ? 128 : 8
            packet[4] = UInt8(identifier >> 8)
            packet[5] = UInt8(identifier & 0xff)
            packet[6] = UInt8((sequence >> 8) & 0xff)
            packet[7] = UInt8(sequence & 0xff)
            let payload = Array("WG VPN server watchdog!!".utf8)
            for i in 0..<min(payload.count, 24) { packet[8 + i] = payload[i] }
            if !isV6 {
                let sum = checksum(packet)
                packet[2] = UInt8(sum >> 8)
                packet[3] = UInt8(sum & 0xff)
            }
            let sent = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, packet, packet.count, 0, address, length)
                }
            }
            guard sent > 0 else { continue }

            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                guard poll(&pfd, 1, remaining) > 0 else { break }
                var reply = [UInt8](repeating: 0, count: 1500)
                let received = recv(fd, &reply, reply.count, 0)
                guard received > 0 else { break }
                var offset = 0
                if !isV6, reply[0] >> 4 == 4 {
                    offset = Int(reply[0] & 0x0f) * 4
                }
                guard received > offset else { continue }
                let type = reply[offset]
                if (isV6 && type == 129) || (!isV6 && type == 0) {
                    return true
                }
            }
        }
        return false
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }
}
