//
//  TarStream.swift
//  lara
//
//  Streaming ustar (tar) writer for the local file server. Walks a directory
//  tree and pushes tar bytes through a write callback so nothing is staged on
//  disk — a multi-GB folder streams straight to the socket. Symlinks are
//  stored as symlink entries (never followed) so there are no traversal loops.
//

import Foundation

/// Shared policy for what the server is willing to expose. Used by both the
/// tar writer and the HTTP directory listing so they agree on exclusions.
nonisolated enum ServerFS {
    /// Paths we never read: /dev is full of device nodes that block on read,
    /// and /private/var/vm is the swap/sleep image (multi-GB of noise).
    static func isExcluded(_ path: String) -> Bool {
        let p = normalize(path)
        let blocked = ["/dev", "/private/var/vm"]
        for b in blocked {
            if p == b || p.hasPrefix(b + "/") { return true }
        }
        return false
    }

    /// Collapse `//` and resolve `.`/`..` textually (no filesystem access), so
    /// a request for `/a/../dev` can't slip past `isExcluded`.
    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var out: [String] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch comp {
            case ".": continue
            case "..":
                if !out.isEmpty { out.removeLast() }
            default:
                out.append(String(comp))
            }
        }
        let joined = out.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }
}

nonisolated enum TarStream {
    private static let blockSize = 512
    private static let readChunk = 256 * 1024

    /// Stream a tar archive of everything under `root`.
    /// `write` returns false when the client has gone away — we stop promptly.
    /// Entry names are stored relative to the filesystem root (leading `/`
    /// removed), so extracting recreates the tree under the current directory.
    static func stream(root: String, write: (Data) -> Bool) {
        let normalizedRoot = ServerFS.normalize(root)
        _ = walk(path: normalizedRoot, write: write)
        // Two zero blocks mark the end of the archive.
        _ = write(Data(count: blockSize * 2))
    }

    /// Returns false to signal the caller should abort (socket write failed).
    private static func walk(path: String, write: (Data) -> Bool) -> Bool {
        if ServerFS.isExcluded(path) { return true }

        var st = stat()
        guard lstat(path, &st) == 0 else { return true } // vanished/unreadable: skip

        let type = st.st_mode & S_IFMT
        switch type {
        case S_IFDIR:
            // Emit a directory entry (except for "/" itself, which has no name).
            if path != "/" {
                if !emitHeader(path: path, st: st, typeflag: 0x35 /* '5' */, linkTarget: nil, size: 0, write: write) {
                    return false
                }
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return true // unreadable directory: skip its contents
            }
            for name in names.sorted() {
                let child = path == "/" ? "/" + name : path + "/" + name
                if !walk(path: child, write: write) { return false }
            }
            return true

        case S_IFLNK:
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? ""
            return emitHeader(path: path, st: st, typeflag: 0x32 /* '2' */, linkTarget: target, size: 0, write: write)

        case S_IFREG:
            return emitFile(path: path, st: st, write: write)

        default:
            // Sockets, FIFOs, char/block devices — skip.
            return true
        }
    }

    private static func emitFile(path: String, st: stat, write: (Data) -> Bool) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 { return true } // can't read it: skip entirely (no header)
        defer { close(fd) }

        let declared = Int64(st.st_size)
        if !emitHeader(path: path, st: st, typeflag: 0x30 /* '0' */, linkTarget: nil, size: declared, write: write) {
            return false
        }

        var remaining = declared
        var buf = [UInt8](repeating: 0, count: readChunk)
        while remaining > 0 {
            let want = Int(min(Int64(readChunk), remaining))
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n <= 0 {
                // Read failed/short: pad the rest with zeros so the declared
                // size still matches and the archive stays valid.
                break
            }
            if !write(Data(buf.prefix(n))) { return false }
            remaining -= Int64(n)
        }
        if remaining > 0 {
            if !writeZeros(Int(remaining), write: write) { return false }
        }

        // Pad the data to a 512-byte boundary.
        let pad = (blockSize - Int(declared % Int64(blockSize))) % blockSize
        if pad > 0 {
            if !writeZeros(pad, write: write) { return false }
        }
        return true
    }

    // MARK: - Header construction

    private static func emitHeader(path: String, st: stat, typeflag: UInt8, linkTarget: String?, size: Int64, write: (Data) -> Bool) -> Bool {
        // Stored name: path relative to filesystem root.
        var name = String(path.drop(while: { $0 == "/" }))
        if typeflag == 0x35 && !name.isEmpty { name += "/" } // dirs end in '/'

        // GNU long-name / long-link extensions when fields overflow 100 bytes.
        if Array(name.utf8).count > 100 {
            if !emitLongBlock(payload: name, typeflag: 0x4C /* 'L' */, write: write) { return false }
        }
        if let link = linkTarget, Array(link.utf8).count > 100 {
            if !emitLongBlock(payload: link, typeflag: 0x4B /* 'K' */, write: write) { return false }
        }

        let header = buildHeader(name: name, st: st, typeflag: typeflag, linkTarget: linkTarget, size: size)
        return write(header)
    }

    /// A GNU `@LongLink` block carries a name/linkname longer than 100 bytes.
    private static func emitLongBlock(payload: String, typeflag: UInt8, write: (Data) -> Bool) -> Bool {
        let bytes = Array(payload.utf8)
        var fake = stat()
        fake.st_mode = 0o644
        let header = buildHeader(name: "././@LongLink", st: fake, typeflag: typeflag, linkTarget: nil, size: Int64(bytes.count + 1))
        if !write(header) { return false }

        var data = Data(bytes)
        data.append(0) // NUL-terminate the payload
        let pad = (blockSize - (data.count % blockSize)) % blockSize
        if pad > 0 { data.append(Data(count: pad)) }
        return write(data)
    }

    private static func buildHeader(name: String, st: stat, typeflag: UInt8, linkTarget: String?, size: Int64) -> Data {
        var buf = [UInt8](repeating: 0, count: blockSize)

        putString(name, at: 0, len: 100, into: &buf)                              // name
        putOctal(UInt64(st.st_mode & 0o7777), at: 100, len: 8, into: &buf)        // mode
        putOctal(UInt64(st.st_uid), at: 108, len: 8, into: &buf)                  // uid
        putOctal(UInt64(st.st_gid), at: 116, len: 8, into: &buf)                  // gid
        putSize(UInt64(size), at: 124, len: 12, into: &buf)                       // size
        putOctal(UInt64(bitPattern: Int64(st.st_mtimespec.tv_sec)), at: 136, len: 12, into: &buf) // mtime
        buf[156] = typeflag                                                       // typeflag
        if let link = linkTarget { putString(link, at: 157, len: 100, into: &buf) } // linkname

        // ustar magic + version.
        putString("ustar", at: 257, len: 6, into: &buf)
        buf[263] = 0x30; buf[264] = 0x30 // "00"

        // Checksum: sum all bytes with the checksum field treated as spaces.
        for i in 148..<156 { buf[i] = 0x20 }
        var sum = 0
        for b in buf { sum += Int(b) }
        // Convention: 6 octal digits, NUL, space.
        let chk = String(format: "%06o", sum & 0o777777)
        putString(chk, at: 148, len: 6, into: &buf)
        buf[154] = 0
        buf[155] = 0x20

        return Data(buf)
    }

    // MARK: - Field encoders

    private static func putString(_ s: String, at off: Int, len: Int, into buf: inout [UInt8]) {
        let bytes = Array(s.utf8)
        let n = min(bytes.count, len)
        for i in 0..<n { buf[off + i] = bytes[i] }
        // Remaining bytes stay zero (fields are NUL-padded).
    }

    /// Octal numeric field: `len-1` octal digits, right-justified, then NUL.
    private static func putOctal(_ value: UInt64, at off: Int, len: Int, into buf: inout [UInt8]) {
        let digits = len - 1
        let s = String(value, radix: 8)
        let padded = s.count >= digits ? String(s.suffix(digits)) : String(repeating: "0", count: digits - s.count) + s
        putString(padded, at: off, len: digits, into: &buf)
        buf[off + len - 1] = 0
    }

    /// Size field: octal when it fits, otherwise GNU base-256 (high bit set,
    /// big-endian value) so files larger than 8GB still encode correctly.
    private static func putSize(_ value: UInt64, at off: Int, len: Int, into buf: inout [UInt8]) {
        let maxOctal: UInt64 = (UInt64(1) << (3 * (len - 1))) - 1 // len-1 octal digits
        if value <= maxOctal {
            putOctal(value, at: off, len: len, into: &buf)
            return
        }
        buf[off] = 0x80
        var v = value
        var i = off + len - 1
        while i > off {
            buf[i] = UInt8(v & 0xFF)
            v >>= 8
            i -= 1
        }
    }

    private static func writeZeros(_ count: Int, write: (Data) -> Bool) -> Bool {
        var left = count
        while left > 0 {
            let n = min(left, readChunk)
            if !write(Data(count: n)) { return false }
            left -= n
        }
        return true
    }
}
