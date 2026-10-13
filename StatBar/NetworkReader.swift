// Adapted from NetBar's SystemNetworkReader (same author, MIT), without the Wi-Fi
// details that need Location Services.
import Darwin
import Foundation
import SystemConfiguration

// Not Sendable on purpose: the SCDynamicStore session isn't documented as thread-safe,
// so the compiler should object if this ever leaves the main actor.
struct SystemNetworkReader {
    /// One dynamic-store session for the app's lifetime; creating one per read was the
    /// biggest remaining cost of the two-second tick.
    private let store = SCDynamicStoreCreate(nil, "StatBar" as CFString, nil, nil)

    func activeRoute() -> ActiveRoute {
        guard let store,
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any]
        else { return ActiveRoute() }
        let primary = ActiveRoute(
            interfaceName: value["PrimaryInterface"] as? String,
            routerAddress: value["Router"] as? String
        )
        guard primary.interfaceName?.hasPrefix("utun") == true else { return primary }
        return activePhysicalRoute(in: store) ?? primary
    }

    private func activePhysicalRoute(in store: SCDynamicStore) -> ActiveRoute? {
        guard let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString)
            as? [String: Any],
              let serviceOrder = setup["ServiceOrder"] as? [String]
        else { return nil }

        for serviceID in serviceOrder {
            let key = "State:/Network/Service/\(serviceID)/IPv4" as CFString
            guard let service = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                  let interfaceName = service["InterfaceName"] as? String,
                  !interfaceName.hasPrefix("utun"),
                  localIPv4Address(for: interfaceName) != nil
            else { continue }

            return ActiveRoute(
                interfaceName: interfaceName,
                routerAddress: service["Router"] as? String
            )
        }
        return nil
    }

    /// Resolve both fields in one interface enumeration.
    func identity(forBSDName name: String) -> InterfaceIdentity? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for interface in interfaces {
            guard SCNetworkInterfaceGetBSDName(interface) as String? == name else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            let transport: TransportKind
            if type == kSCNetworkInterfaceTypeIEEE80211 as String { transport = .wifi }
            else if type == kSCNetworkInterfaceTypeEthernet as String { transport = .ethernet }
            else { transport = .other }
            return InterfaceIdentity(transport: transport,
                                     displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?)
        }
        return nil
    }

    func localIPv4Address(for interfaceName: String) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: item.pointee.ifa_name) == interfaceName,
                  let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        return nil
    }

    func counters(for interfaceName: String) -> InterfaceCounters? {
        let interfaceIndex = interfaceName.withCString { if_nametoindex($0) }
        guard interfaceIndex != 0 else { return nil }
        var mib = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(interfaceIndex)]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: length,
            alignment: MemoryLayout<if_msghdr2>.alignment
        )
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer, &length, nil, 0) == 0 else { return nil }

        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = buffer.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0, offset + messageLength <= length else { break }

            if header.ifm_type == UInt8(RTM_IFINFO2), messageLength >= MemoryLayout<if_msghdr2>.size {
                let extended = buffer.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if if_indextoname(UInt32(extended.ifm_index), &nameBuffer) != nil {
                    let decodedName = String(
                        decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                    guard decodedName == interfaceName else {
                        offset += messageLength
                        continue
                    }
                    return InterfaceCounters(
                        receivedBytes: extended.ifm_data.ifi_ibytes,
                        sentBytes: extended.ifm_data.ifi_obytes
                    )
                }
            }
            offset += messageLength
        }
        return nil
    }

    func activeEthernetConnections() -> [EthernetConnection] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return interfaces.compactMap { interface in
            guard SCNetworkInterfaceGetInterfaceType(interface) as String? == kSCNetworkInterfaceTypeEthernet as String,
                  let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let media = ethernetMedia(for: name),
                  media.isActive
            else { return nil }

            return EthernetConnection(
                interfaceName: name,
                displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? "Ethernet",
                linkSpeedBitsPerSecond: media.linkSpeedBitsPerSecond,
                localAddress: localIPv4Address(for: name)
            )
        }
        .sorted { $0.interfaceName.localizedStandardCompare($1.interfaceName) == .orderedAscending }
    }

    /// The GlobalProtect tunnel if connected, nil if not; `known` is false when the process
    /// table couldn't be read this time, so callers keep their previous answer instead of
    /// logging a disconnect that didn't happen.
    func globalProtectStatus() -> (known: Bool, tunnel: String?) {
        guard let running = globalProtectServiceIsRunning() else { return (false, nil) }
        guard running else { return (true, nil) }
        return (true, globalProtectTunnel())
    }

    static var isGlobalProtectInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/GlobalProtect.app")
    }

    private func globalProtectTunnel() -> String? {

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("utun"),
                  let address = item.pointee.ifa_addr,
                  Self.isActiveIPv4Tunnel(
                      flags: item.pointee.ifa_flags,
                      addressFamily: address.pointee.sa_family
                  )
            else { continue }
            return name
        }
        return nil
    }

    static func isActiveIPv4Tunnel(flags: UInt32, addressFamily: UInt8) -> Bool {
        let requiredFlags = UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT)
        return flags & requiredFlags == requiredFlags && addressFamily == UInt8(AF_INET)
    }

    private func globalProtectServiceIsRunning() -> Bool? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, 4, nil, &length, nil, 0) == 0 else { return nil }
        // Headroom for processes started between the two calls.
        let capacity = length / MemoryLayout<kinfo_proc>.stride + 32
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        length = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &length, nil, 0) == 0 else { return nil }
        let count = length / MemoryLayout<kinfo_proc>.stride
        return processes.prefix(count).contains { process in
            let executableName = withUnsafePointer(to: process.kp_proc.p_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard executableName == "PanGPS" else { return false }

            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(process.kp_proc.p_pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
                return false
            }
            let executablePath = String(
                decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            return Self.isGlobalProtectService(
                executableName: executableName,
                executablePath: executablePath
            )
        }
    }

    static func isGlobalProtectService(executableName: String, executablePath: String) -> Bool {
        executableName == "PanGPS"
            && executablePath.hasSuffix("/GlobalProtect.app/Contents/Resources/PanGPS")
    }

    private func ethernetMedia(for interfaceName: String) -> (isActive: Bool, linkSpeedBitsPerSecond: UInt64?)? {
        var request = ifmediareq()
        withUnsafeMutableBytes(of: &request.ifm_name) { bytes in
            for (index, byte) in interfaceName.utf8.prefix(Int(IFNAMSIZ) - 1).enumerated() {
                bytes[index] = byte
            }
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        let command = UInt(0xC000_0000)
            | UInt(MemoryLayout<ifmediareq>.size << 16)
            | UInt(105 << 8)
            | 56
        guard ioctl(descriptor, command, &request) == 0 else { return nil }

        let statusIsValid = request.ifm_status & IFM_AVALID != 0
        let isActive = statusIsValid && request.ifm_status & IFM_ACTIVE != 0
        let isEthernet = request.ifm_active & IFM_NMASK == IFM_ETHER
        guard isEthernet else { return nil }
        return (isActive, Self.ethernetLinkSpeed(forMediaWord: request.ifm_active))
    }

    static func ethernetLinkSpeed(forMediaWord mediaWord: Int32) -> UInt64? {
        let subtype = mediaWord & IFM_TMASK
        switch subtype {
        case IFM_10_T, IFM_10_2, IFM_10_5, IFM_10_STP, IFM_10_FL:
            return 10_000_000
        case IFM_100_TX, IFM_100_FX, IFM_100_T4, IFM_100_VG, IFM_100_T2:
            return 100_000_000
        case IFM_1000_SX, IFM_1000_LX, IFM_1000_CX, IFM_1000_T,
             IFM_1000_CX_SGMII, IFM_1000_KX:
            return 1_000_000_000
        case IFM_2500_T:
            return 2_500_000_000
        case IFM_5000_T:
            return 5_000_000_000
        case IFM_10G_SR, IFM_10G_LR, IFM_10G_CX4, IFM_10G_T,
             IFM_10G_KX4, IFM_10G_KR, IFM_10G_CR1, IFM_10G_ER:
            return 10_000_000_000
        case IFM_20G_KR2:
            return 20_000_000_000
        default:
            return nil
        }
    }
}


enum TransportKind: String, Sendable {
    case wifi = "Wi-Fi"
    case ethernet = "Ethernet"
    case other = "Network"
    case none = "No route"

    var symbolName: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector.horizontal"
        case .other: "network"
        case .none: "network.slash"
        }
    }
}

struct ActiveRoute: Equatable, Sendable {
    var interfaceName: String?
    var routerAddress: String?
}

struct InterfaceIdentity: Equatable, Sendable {
    let transport: TransportKind
    let displayName: String?
}

struct EthernetConnection: Equatable, Sendable {
    let interfaceName: String
    let displayName: String
    let linkSpeedBitsPerSecond: UInt64?
    let localAddress: String?
}

struct InterfaceCounters: Equatable, Sendable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}
