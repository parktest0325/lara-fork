//
//  LocalFileServer.swift
//  lara
//
//  A tiny read-only HTTP/1.1 server that exposes the device filesystem so the
//  whole thing can be pulled to a computer over the LAN with a browser, curl,
//  or `wget -r -c`. Reuses the app's full-disk FileManager access (same path
//  as the SBX File Manager), streams files with Range/resume support, and can
//  stream a folder as a tar. Read-only: only GET/HEAD are served.
//

import Foundation
import UIKit
import Combine

nonisolated final class LocalFileServer: ObservableObject {
    static let shared = LocalFileServer()

    // Displayed / observed by the UI.
    @Published private(set) var isRunning = false
    @Published private(set) var urlString: String?
    @Published private(set) var port: Int = 0
    @Published private(set) var lastError: String?
    @Published private(set) var password = ""

    let username = "lara"

    private let portRange: ClosedRange<Int> = 8080...8090
    private var listenFD: Int32 = -1
    private var shouldStop = false
    private var acceptThread: Thread?
    private let connQueue = DispatchQueue(label: "party.jailbreak.lara.localserver.conn", attributes: .concurrent)

    // Track whether *we* turned on keepalive so we only turn off what we own.
    private var ownedKeepalive = false

    private init() {
        // A client vanishing mid-stream must not kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Lifecycle

    @MainActor func start() {
        guard !isRunning else { return }
        lastError = nil

        let pw = Self.makePassword()
        guard let (fd, boundPort) = openListener() else {
            // openListener set lastError already.
            return
        }

        listenFD = fd
        shouldStop = false
        password = pw
        port = boundPort

        let ip = netiface.wifiIPv4()
        urlString = ip.map { "http://\($0):\(boundPort)" }
        isRunning = true

        // Keep the app alive during long transfers and stop the screen sleeping.
        if !kaenabled {
            toggleka()
            ownedKeepalive = kaenabled
        }
        UIApplication.shared.isIdleTimerDisabled = true

        laramgr.shared.logmsg("(server) listening on \(urlString ?? "port \(boundPort)")")

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "lara.localserver.accept"
        t.stackSize = 512 * 1024
        acceptThread = t
        t.start()
    }

    @MainActor func stop() {
        guard isRunning else { return }
        shouldStop = true
        if listenFD >= 0 {
            close(listenFD) // unblocks accept()
            listenFD = -1
        }
        acceptThread = nil
        isRunning = false
        urlString = nil
        port = 0

        if ownedKeepalive && kaenabled {
            toggleka()
            ownedKeepalive = false
        }
        UIApplication.shared.isIdleTimerDisabled = false
        laramgr.shared.logmsg("(server) stopped")
    }

    // MARK: - Socket setup

    private func openListener() -> (fd: Int32, port: Int)? {
        for candidate in portRange {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd < 0 { continue }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(candidate).bigEndian
            addr.sin_addr = in_addr(s_addr: in_addr_t(0)) // INADDR_ANY

            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound != 0 {
                close(fd)
                continue
            }
            if listen(fd, 16) != 0 {
                close(fd)
                continue
            }
            return (fd, candidate)
        }

        lastError = "Could not bind a port in \(portRange.lowerBound)-\(portRange.upperBound). Try respringing."
        return nil
    }

    private func acceptLoop() {
        while !shouldStop {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if shouldStop { break }
                continue
            }
            configureClient(client)
            connQueue.async { [weak self] in
                self?.handle(client)
                close(client)
            }
        }
    }

    private func configureClient(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var rcv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
        var snd = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Request handling

    private struct Request {
        let method: String
        let path: String      // percent-decoded absolute filesystem path
        let query: String
        let headers: [String: String]
    }

    private struct DirEntry {
        let name: String
        let isDirectory: Bool
    }

    /// State of the "Use RemoteCall" toggle carried through query params
    /// (`?rc=1&rcproc=<process>`) so it survives folder-to-folder navigation.
    private struct RemoteOptions {
        let enabled: Bool
        let process: String // trimmed; can be empty even when enabled (checkbox on, field not filled yet)
    }

    private func handle(_ fd: Int32) {
        guard let req = readRequest(fd) else {
            _ = sendStatus(fd, 400, "Bad Request")
            return
        }

        // Basic auth over the whole surface (full disk exposure).
        guard authorized(req) else {
            let body = Data("Authentication required.".utf8)
            var head = "HTTP/1.1 401 Unauthorized\r\n"
            head += "WWW-Authenticate: Basic realm=\"lara\"\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            if sendAll(fd, Data(head.utf8)) && req.method != "HEAD" { _ = sendAll(fd, body) }
            return
        }

        guard req.method == "GET" || req.method == "HEAD" else {
            _ = sendStatus(fd, 405, "Method Not Allowed")
            return
        }

        let path = ServerFS.normalize(req.path.isEmpty ? "/" : req.path)
        if ServerFS.isExcluded(path) {
            _ = sendStatus(fd, 403, "Forbidden")
            return
        }

        let headOnly = req.method == "HEAD"
        let rc = remoteOptions(from: req.query)

        if rc.enabled && !rc.process.isEmpty {
            handleRemote(fd, path: path, process: rc.process, headOnly: headOnly)
            return
        }

        var st = stat()
        guard stat(path, &st) == 0 else { // follows symlinks; dangling -> 404
            _ = sendStatus(fd, 404, "Not Found")
            return
        }

        let isDir = (st.st_mode & S_IFMT) == S_IFDIR

        if isDir {
            if req.query.contains("archive=1") {
                serveTar(fd, path: path, headOnly: headOnly)
            } else {
                serveDirectory(fd, path: path, headOnly: headOnly, rc: rc)
            }
        } else {
            serveFile(fd, path: path, size: Int64(st.st_size), headers: req.headers, headOnly: headOnly)
        }
    }

    // MARK: - RemoteCall-backed browsing

    /// Serves a path by opening/reading it inside another process (chosen via
    /// the "Use RemoteCall" checkbox + process name field in the directory
    /// listing UI) instead of this app's own full-disk access. Read-only.
    private func handleRemote(_ fd: Int32, path: String, process: String, headOnly: Bool) {
        guard let proc = RemoteCall(process: process, useMigFilterBypass: false) else {
            _ = sendStatus(fd, 502, "RemoteCall init failed for \(process)")
            return
        }
        defer { proc.destroy() }

        var errorMessage: NSString?
        var isDirectory: ObjCBool = false
        var size: UInt64 = 0
        guard rc_remote_stat(proc, path, &isDirectory, &size, &errorMessage) else {
            _ = sendStatus(fd, 404, "Not Found (via \(process)): \((errorMessage as String?) ?? "stat failed")")
            return
        }

        if isDirectory.boolValue {
            serveRemoteDirectory(fd, proc: proc, path: path, process: process, headOnly: headOnly)
        } else {
            serveRemoteFile(fd, proc: proc, path: path, headOnly: headOnly)
        }
    }

    private func serveRemoteDirectory(_ fd: Int32, proc: RemoteCall, path: String, process: String, headOnly: Bool) {
        var errorMessage: NSString?
        guard let raw = rc_list_remote_directory(proc, path, &errorMessage) as? [[String: Any]] else {
            _ = sendStatus(fd, 502, "RemoteCall directory listing failed: \((errorMessage as String?) ?? "unknown error")")
            return
        }

        let entries = raw.compactMap { dict -> DirEntry? in
            guard let name = dict["name"] as? String else { return nil }
            let full = path == "/" ? "/" + name : path + "/" + name
            if ServerFS.isExcluded(full) { return nil }
            let isDir = (dict["isDirectory"] as? NSNumber)?.boolValue ?? false
            return DirEntry(name: name, isDirectory: isDir)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }

        let html = renderDirectoryHTML(path: path, entries: entries, rc: RemoteOptions(enabled: true, process: process), supportsArchive: false)
        let body = Data(html.utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        guard sendAll(fd, Data(head.utf8)) else { return }
        if headOnly { return }
        _ = sendAll(fd, body)
    }

    private func serveRemoteFile(_ fd: Int32, proc: RemoteCall, path: String, headOnly: Bool) {
        var errorMessage: NSString?
        guard let data = rc_read_remote_file(proc, path, &errorMessage) else {
            _ = sendStatus(fd, 502, "RemoteCall file read failed: \((errorMessage as String?) ?? "unknown error")")
            return
        }

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(Self.contentType(for: path))\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Accept-Ranges: none\r\n"
        head += "Connection: close\r\n\r\n"
        guard sendAll(fd, Data(head.utf8)) else { return }
        if headOnly { return }
        _ = sendAll(fd, data)
    }

    private func authorized(_ req: Request) -> Bool {
        guard let value = req.headers["authorization"] else { return false }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let data = Data(base64Encoded: String(parts[1])),
              let decoded = String(data: data, encoding: .utf8) else { return false }
        return decoded == "\(username):\(password)"
    }

    // MARK: - Responses

    private func serveFile(_ fd: Int32, path: String, size: Int64, headers: [String: String], headOnly: Bool) {
        let fileFD = open(path, O_RDONLY | O_NONBLOCK)
        if fileFD < 0 {
            _ = sendStatus(fd, 403, "Forbidden")
            return
        }
        defer { close(fileFD) }

        // Range: bytes=start-end (single range only).
        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        if let range = headers["range"], let parsed = parseRange(range, size: size) {
            if parsed.start > parsed.end {
                var head = "HTTP/1.1 416 Range Not Satisfiable\r\n"
                head += "Content-Range: bytes */\(size)\r\n"
                head += "Connection: close\r\n\r\n"
                _ = sendAll(fd, Data(head.utf8))
                return
            }
            start = parsed.start
            end = parsed.end
            partial = true
        }

        let length = size == 0 ? 0 : (end - start + 1)
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(Self.contentType(for: path))\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "Connection: close\r\n\r\n"
        guard sendAll(fd, Data(head.utf8)) else { return }
        if headOnly || length == 0 { return }

        if start > 0 { lseek(fileFD, off_t(start), SEEK_SET) }
        var remaining = length
        let chunkSize = 256 * 1024
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while remaining > 0 {
            let want = Int(min(Int64(chunkSize), remaining))
            let n = buf.withUnsafeMutableBytes { read(fileFD, $0.baseAddress, want) }
            if n <= 0 { break }
            if !sendAll(fd, Data(buf.prefix(n))) { return }
            remaining -= Int64(n)
        }
    }

    private func serveTar(_ fd: Int32, path: String, headOnly: Bool) {
        // Size is unknown up front, so close-delimit the body (HTTP/1.0 style).
        let name = (path == "/" ? "root" : (path as NSString).lastPathComponent) + ".tar"
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/x-tar\r\n"
        head += "Content-Disposition: attachment; filename=\"\(name)\"\r\n"
        head += "Connection: close\r\n\r\n"
        guard sendAll(fd, Data(head.utf8)) else { return }
        if headOnly { return }
        TarStream.stream(root: path) { [weak self] data in
            self?.sendAll(fd, data) ?? false
        }
    }

    private func serveDirectory(_ fd: Int32, path: String, headOnly: Bool, rc: RemoteOptions) {
        let html = directoryHTML(path: path, rc: rc)
        let body = Data(html.utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        guard sendAll(fd, Data(head.utf8)) else { return }
        if headOnly { return }
        _ = sendAll(fd, body)
    }

    private func directoryHTML(path: String, rc: RemoteOptions) -> String {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: path))?.sorted { $0.lowercased() < $1.lowercased() } ?? []

        let entries: [DirEntry] = names.compactMap { name in
            let full = path == "/" ? "/" + name : path + "/" + name
            if ServerFS.isExcluded(full) { return nil }
            var st = stat()
            let isDir = stat(full, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            return DirEntry(name: name, isDirectory: isDir)
        }

        return renderDirectoryHTML(path: path, entries: entries, rc: rc, supportsArchive: true)
    }

    /// Shared HTML renderer for both local (FileManager) and RemoteCall-backed
    /// directory listings, so the "Use RemoteCall" toggle and navigation links
    /// behave identically in both modes.
    private func renderDirectoryHTML(path: String, entries: [DirEntry], rc: RemoteOptions, supportsArchive: Bool) -> String {
        let navSuffix = (rc.enabled && !rc.process.isEmpty) ? "?rc=1&rcproc=\(queryEncode(rc.process))" : ""

        var rows = ""
        if path != "/" {
            let parent = ServerFS.normalize(path + "/..")
            rows += "<li><a href=\"\(hrefEncode(parent))\(navSuffix)\">../</a></li>\n"
        }
        for entry in entries {
            let full = path == "/" ? "/" + entry.name : path + "/" + entry.name
            let display = htmlEscape(entry.name) + (entry.isDirectory ? "/" : "")
            let href = hrefEncode(full) + (entry.isDirectory ? "/" : "") + navSuffix
            rows += "<li><a href=\"\(href)\">\(display)</a></li>\n"
        }

        let title = htmlEscape(path)
        let controlForm = remoteControlForm(path: path, rc: rc)

        let hint: String
        if supportsArchive {
            let archiveHref = hrefEncode(path) + "?archive=1"
            hint = """
            <div class="hint">
              <a href="\(archiveHref)">⬇︎ Download this folder as .tar</a><br>
              Pull everything with resume:
              <code>wget -r -np -c --user=\(username) --password=&lt;password&gt; http://HOST:\(port)/</code>
            </div>
            """
        } else {
            hint = """
            <div class="hint">Browsing via RemoteCall as <code>\(htmlEscape(rc.process))</code>. Folder download (.tar) isn't available in this mode.</div>
            """
        }

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          body{font:14px -apple-system,system-ui,sans-serif;margin:1.2rem;max-width:900px}
          h1{font-size:1rem;word-break:break-all}
          ul{list-style:none;padding:0} li{padding:2px 0}
          a{text-decoration:none;color:#0a63c9} a:hover{text-decoration:underline}
          .hint{background:#f4f4f5;border-radius:8px;padding:.6rem .8rem;margin:.6rem 0;color:#444}
          .rcform{background:#eef6ff;border-radius:8px;padding:.6rem .8rem;margin:.6rem 0}
          .rcform input[type=text]{padding:.3rem;min-width:220px}
          code{font-family:ui-monospace,Menlo,monospace}
        </style></head><body>
        <h1>\(title)</h1>
        \(controlForm)
        \(hint)
        <ul>
        \(rows)</ul>
        </body></html>
        """
    }

    private func remoteControlForm(path: String, rc: RemoteOptions) -> String {
        let action = hrefEncode(path)
        let checked = rc.enabled ? " checked" : ""
        let processValue = htmlEscape(rc.process)
        return """
        <form class="rcform" method="GET" action="\(action)">
          <label><input type="checkbox" name="rc" value="1"\(checked) onchange="this.form.submit()"> Use RemoteCall</label>
          <input type="text" name="rcproc" placeholder="Process name (e.g. SpringBoard)" value="\(processValue)">
          <button type="submit">Apply</button>
        </form>
        """
    }

    // MARK: - Low-level IO

    private func readRequest(_ fd: Int32) -> Request? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let cap = 64 * 1024
        while data.count < cap {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let r = data.range(of: Data("\r\n\r\n".utf8)) {
                data = data.subdata(in: data.startIndex..<r.lowerBound)
                break
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2 else { return nil }

        let method = String(tokens[0]).uppercased()
        let rawTarget = String(tokens[1])
        let (rawPath, query) = splitQuery(rawTarget)
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        return Request(method: method, path: decodedPath, query: query, headers: headers)
    }

    @discardableResult
    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress, raw.count > 0 else { return true }
            var sent = 0
            while sent < raw.count {
                let n = send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func sendStatus(_ fd: Int32, _ code: Int, _ text: String) -> Bool {
        let body = Data("\(code) \(text)".utf8)
        var head = "HTTP/1.1 \(code) \(text)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        guard sendAll(fd, Data(head.utf8)) else { return false }
        return sendAll(fd, body)
    }

    // MARK: - Helpers

    private func parseRange(_ header: String, size: Int64) -> (start: Int64, end: Int64)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startStr = spec[spec.startIndex..<dash]
        let endStr = spec[spec.index(after: dash)...]

        if startStr.isEmpty {
            // Suffix range: last N bytes.
            guard let n = Int64(endStr), n > 0 else { return nil }
            let start = max(0, size - n)
            return (start, size - 1)
        }
        guard let start = Int64(startStr) else { return nil }
        let end = endStr.isEmpty ? size - 1 : (Int64(endStr) ?? size - 1)
        return (start, min(end, size - 1))
    }

    private func splitQuery(_ target: String) -> (path: String, query: String) {
        if let q = target.firstIndex(of: "?") {
            return (String(target[target.startIndex..<q]), String(target[target.index(after: q)...]))
        }
        return (target, "")
    }

    private func queryParams(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            guard !pair.isEmpty else { continue }
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = String(parts[0]).replacingOccurrences(of: "+", with: " ")
            let key = rawKey.removingPercentEncoding ?? rawKey
            let rawValue = (parts.count > 1 ? String(parts[1]) : "").replacingOccurrences(of: "+", with: " ")
            result[key] = rawValue.removingPercentEncoding ?? rawValue
        }
        return result
    }

    private func remoteOptions(from query: String) -> RemoteOptions {
        let params = queryParams(query)
        let enabled = params["rc"] == "1"
        let process = (params["rcproc"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteOptions(enabled: enabled, process: process)
    }

    private func hrefEncode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    private func queryEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func makePassword() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<10).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    private static func contentType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "log", "cfg", "conf": return "text/plain; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "json": return "application/json"
        case "xml", "plist": return "application/xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}
