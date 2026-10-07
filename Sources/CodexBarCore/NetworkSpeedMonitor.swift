import Darwin
import Foundation
import SystemConfiguration

public struct NetworkSpeed: Equatable, Sendable {
    public let uploadBytesPerSecond: Double
    public let downloadBytesPerSecond: Double

    public init(uploadBytesPerSecond: Double, downloadBytesPerSecond: Double) {
        self.uploadBytesPerSecond = max(0, uploadBytesPerSecond)
        self.downloadBytesPerSecond = max(0, downloadBytesPerSecond)
    }

    public static let zero = NetworkSpeed(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)

    public static func compact(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1_000 { return "\(Int(value))B/s" }
        if value < 1_000_000 { return String(format: "%.0fK/s", value / 1_000) }
        if value < 10_000_000 { return String(format: "%.1fM/s", value / 1_000_000) }
        if value < 1_000_000_000 { return String(format: "%.0fM/s", value / 1_000_000) }
        return String(format: "%.1fG/s", value / 1_000_000_000)
    }
}

/// Reads the kernel byte counters of macOS's primary network interface.
/// Sampling this interface avoids counting VPN/tunnel traffic a second time.
public final class NetworkSpeedMonitor {
    private struct Sample {
        let interface: String
        let received: UInt64
        let sent: UInt64
        let time: TimeInterval
    }

    private var previous: Sample?
    private var recent: [NetworkSpeed] = []

    public init() {}

    public func sample() -> NetworkSpeed {
        guard let current = readSample() else {
            previous = nil
            recent.removeAll()
            return .zero
        }
        defer { previous = current }
        guard let previous,
              previous.interface == current.interface,
              current.time > previous.time,
              current.time - previous.time < 30,
              current.received >= previous.received,
              current.sent >= previous.sent else {
            recent.removeAll()
            return .zero
        }
        let elapsed = current.time - previous.time
        let latest = NetworkSpeed(
            uploadBytesPerSecond: Double(current.sent - previous.sent) / elapsed,
            downloadBytesPerSecond: Double(current.received - previous.received) / elapsed
        )
        recent.append(latest)
        if recent.count > 3 { recent.removeFirst() }
        return NetworkSpeed(
            uploadBytesPerSecond: recent.map(\.uploadBytesPerSecond).reduce(0, +) / Double(recent.count),
            downloadBytesPerSecond: recent.map(\.downloadBytesPerSecond).reduce(0, +) / Double(recent.count)
        )
    }

    private func readSample() -> Sample? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else { return nil }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let item = cursor {
            let address = item.pointee.ifa_addr
            if String(cString: item.pointee.ifa_name) == primary,
               address?.pointee.sa_family == UInt8(AF_LINK),
               let raw = item.pointee.ifa_data {
                let counters = raw.assumingMemoryBound(to: if_data.self).pointee
                return Sample(interface: primary,
                              received: UInt64(counters.ifi_ibytes),
                              sent: UInt64(counters.ifi_obytes),
                              time: ProcessInfo.processInfo.systemUptime)
            }
            cursor = item.pointee.ifa_next
        }
        return nil
    }
}
