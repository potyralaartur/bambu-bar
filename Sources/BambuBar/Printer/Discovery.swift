import Darwin
import Foundation

/// A printer that announced itself on the local network.
struct DiscoveredPrinter: Identifiable, Equatable {
    var id: String { serial }
    var serial: String
    var host: String
    var name: String
    var modelCode: String
    var firmware: String?
    /// "lan" (LAN Only mode) or "cloud".
    var connectMode: String?
    var lastSeen: Date

    var modelName: String { PrinterModel.name(for: modelCode, serial: serial) }
}

/// Listens for the SSDP-style NOTIFY packets Bambu printers broadcast on UDP 2021 (and answers to an M-SEARCH),
/// so the printer can be picked from a list and its IP address followed when DHCP changes it.
final class PrinterDiscovery {
    var onFound: ((DiscoveredPrinter) -> Void)?

    private var sockets: [Int32] = []
    private var running = false
    private let queue = DispatchQueue(label: "dev.rolottr.BambuBar.discovery")

    func start() {
        guard !running else { return }
        running = true
        for port: UInt16 in [2021, 1990] + Self.mockPorts {
            guard let fd = Self.openSocket(port: port) else { continue }
            sockets.append(fd)
            let source = fd
            Thread.detachNewThread { [weak self] in self?.listen(on: source) }
        }
        search()
    }

    /// The mock fleet announces itself on a port of its own (scripts/fleet), so the copy of Bambu Bar in daily
    /// use, also bound to 2021, doesn't take its unicast packets.
    private static var mockPorts: [UInt16] {
        guard CommandLine.arguments.contains("--emulator") else { return [] }
        return [2121]
    }

    func stop() {
        running = false
        for fd in sockets { close(fd) }
        sockets.removeAll()
    }

    /// Asks every printer to answer now instead of waiting for its next broadcast (they announce every ~30 s).
    func search() {
        // Sent from a listening socket: printers answer unicast to the port the search came from.
        guard let fd = sockets.first else { return }
        queue.async {
            let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: urn:bambulab-com:device:3dprinter:1\r\n\r\n"
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            for (address, port) in [("239.255.255.250", UInt16(2021)), ("239.255.255.250", 1990), ("255.255.255.255", 2021)] {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                inet_pton(AF_INET, address, &addr.sin_addr)
                _ = message.withCString { ptr in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    private static func openSocket(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); return nil }
        var group = ip_mreq()
        inet_pton(AF_INET, "239.255.255.250", &group.imr_multiaddr)
        group.imr_interface.s_addr = INADDR_ANY
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &group, socklen_t(MemoryLayout<ip_mreq>.size))
        return fd
    }

    private func listen(on fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while running {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            if n <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return
            }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            let sender = String(cString: ip)
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            if let printer = Self.parse(text, sender: sender) {
                DispatchQueue.main.async { [weak self] in self?.onFound?(printer) }
            }
        }
    }

    static func parse(_ text: String, sender: String) -> DiscoveredPrinter? {
        guard text.hasPrefix("NOTIFY") || text.hasPrefix("HTTP/1.1 200") else { return nil }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["nt"]?.contains("bambulab") == true || headers["st"]?.contains("bambulab") == true,
              let serial = headers["usn"], !serial.isEmpty else { return nil }
        let host = headers["location"].flatMap { $0.isEmpty ? nil : $0 } ?? sender
        return DiscoveredPrinter(serial: serial, host: host, name: headers["devname.bambu.com"] ?? serial,
                                 modelCode: headers["devmodel.bambu.com"] ?? "", firmware: headers["devversion.bambu.com"],
                                 connectMode: headers["devconnect.bambu.com"], lastSeen: Date())
    }
}
