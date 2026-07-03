//
//  netiface.swift
//  lara
//
//  Local file server: figure out the device's LAN address so the UI can show
//  a URL the user can hit from their computer.
//

import Foundation

enum netiface {
    /// Returns the device's IPv4 address on the LAN, preferring the Wi-Fi
    /// interface (en0). Falls back to any non-loopback IPv4 interface.
    /// Returns nil when the device has no usable IPv4 address (e.g. no Wi-Fi).
    static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }

            let flags = Int32(cur.pointee.ifa_flags)
            // Interface must be up and running, and not loopback.
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
            guard r == 0 else { continue }
            let ip = String(cString: host)
            if ip.isEmpty { continue }

            let name = String(cString: cur.pointee.ifa_name)
            if name == "en0" {
                // Wi-Fi is the best guess for a local transfer; take it and stop.
                preferred = ip
                break
            } else if fallback == nil {
                fallback = ip
            }
        }

        return preferred ?? fallback
    }
}
