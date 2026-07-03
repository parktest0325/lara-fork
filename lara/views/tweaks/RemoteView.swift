//
//  RemoteView.swift
//  lara
//
//  Created by ruter on 17.04.26.
//

import SwiftUI
import Darwin

struct RemoteView: View {
    @ObservedObject var mgr: laramgr
    @State private var statusBarTimeFormat: String = "HH:mm"
    @State private var running: Bool = false
    @State private var columns: Int = 5
    @State private var performanceHUD: Int = -1
    @AppStorage("rcdockunlimited") private var rcdockunlimited: Bool = false
    @State private var customProcessName: String = "SpringBoard"
    @State private var customFilePath: String = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
    @State private var customLastResult: String = ""
    @State private var customLastFileData: Data? = nil
    @State private var hsRows: Int = 6
    @State private var hsColumns: Int = 4
    @State private var freakyrunning: Bool = false
    @State private var freakyseq: Int = 0

    private var dockMaxColumns: Int { rcdockunlimited ? 50 : 10 }

    var body: some View {
        List {
            Section {
                TextField("Date format (e.g. HH:mm)", text: $statusBarTimeFormat)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Button {
                    run("Status Bar Time Format") {
                        status_bar_time_format(mgr.sbProc, statusBarTimeFormat)
                        return "status_bar_time_format() done"
                    }
                } label: {
                    Text("Apply")
                }
            } header: {
                Text("Status Bar Time Format")
            } footer: {
                Text("The text automatically updates every MINUTE")
            }

            Section {
                Button {
                    run("Hide Icon Labels") {
                        let hidden = hide_icon_labels(mgr.sbProc)
                        return "hide_icon_labels() -> \(hidden)"
                    }
                } label: {
                    Text("Hide Icon Labels")
                }
            } header: {
                Text("SpringBoard")
            }

            Section {
                Stepper(value: $hsColumns, in: 1...10) {
                    HStack {
                        Text("Home screen columns")
                        Spacer()
                        Text("\(hsColumns)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                
                Stepper(value: $hsRows, in: 1...10) {
                    HStack {
                        Text("Home screen rows")
                        Spacer()
                        Text("\(hsRows)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }

                Button {
                    run("Patch Home Screen Grid \(hsColumns)x\(hsRows)") {
                        return patch_homescreen_grid(mgr.sbProc, Int32(hsColumns), Int32(hsRows))
                            ? "patch_homescreen_grid(\(hsColumns), \(hsRows)) -> ok"
                            : "patch_homescreen_grid(\(hsColumns), \(hsRows)) -> failed"
                    }
                } label: {
                    Text("Apply Home Screen Grid")
                }
            }

            Section {
                Stepper(value: $columns, in: 1...dockMaxColumns) {
                    HStack {
                        Text("Dock columns")
                        Spacer()
                        Text("\(columns)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .onChange(of: rcdockunlimited) { _ in
                    if !rcdockunlimited, columns > 10 {
                        columns = 10
                    }
                }

                Button {
                    run("Apply Dock Columns=\(columns)") {
                        let result = set_dock_icon_count(mgr.sbProc, Int32(columns))
                        return result == 0
                            ? "set_dock_icon_count(\(columns)) -> ok"
                            : "set_dock_icon_count(\(columns)) -> failed (\(result))"
                    }
                } label: {
                    Text("Apply Dock Columns")
                }
            }

            Section {
                Button {
                    run("Enable Upside Down") {
                        let result = enable_upside_down(mgr.sbProc)
                        return result == 0
                            ? "enable_upside_down() -> ok"
                            : "enable_upside_down() -> failed (\(result))"
                    }
                } label: {
                    Text("Enable Upside Down")
                }
            }

            Section {
                Button {
                    run("Enable Floating Dock") {
                        let result = enable_floating_dock(mgr.sbProc)
                        return result == 0
                            ? "enable_floating_dock() -> ok"
                            : "enable_floating_dock() -> failed (\(result))"
                    }
                } label: {
                    Text("Enable Floating Dock")
                }
                
                Button {
                    run("Enable Grid App Switcher") {
                        let result = enable_grid_app_switcher(mgr.sbProc)
                        return result == 0
                            ? "enable_grid_app_switcher() -> ok"
                            : "enable_grid_app_switcher() -> failed (\(result))"
                    }
                } label: {
                    Text("Enable Grid App Switcher (Broken animation)")
                }
                
                Button {
                    run("Enable UIKit Debug Overlay") {
                        let result = enable_debug_overlay(mgr.sbProc)
                        return result == 0
                            ? "enable_debug_overlay() -> ok"
                            : "enable_debug_overlay() -> failed (\(result))"
                    }
                } label: {
                    Text("Enable UIKit Debug Overlay")
                }

                /*
                Button {
                    togglefreakydog()
                } label: {
                    Text(freakyrunning ? "Stop Freaky Dog Overlay" : "Start Freaky Dog Overlay")
                }
                */
            } footer: {
                Text("To use UIKit Debug Overlay, double tap the status bar.")
            }
            
            Section {
                Picker("Performance HUD", selection: $performanceHUD) {
                    Text("Off").tag(-1)
                    Text("Basic").tag(0)
                    Text("Backdrops").tag(1)
                    Text("Particles").tag(2)
                    Text("Full").tag(3)
                    Text("Power").tag(5)
                    Text("EDR").tag(7)
                    Text("Glitches").tag(8)
                    Text("GPU Time").tag(9)
                    Text("Memory Bandwidth").tag(10)
                }
                .onChange(of: performanceHUD) { newValue in
                    set_performance_hud(mgr.sbProc, Int32(newValue))
                }
                .onAppear {
                    if mgr.rcrunning {
                        performanceHUD = Int(get_performance_hud(mgr.sbProc))
                    }
                }
            } footer: {
                Text("These call into SpringBoard via RemoteCall. Keep RemoteCall initialized while running them.")
                
                if !mgr.rcready {
                    Text("RemoteCall is not initialized. How are you here?")
                }
            }
            .disabled(!mgr.rcready || running)
            
            if #available(iOS 17.4, *) {
                Section {
                    Button {
                        mgr.rcinitDaemon(serviceName: "com.apple.xpc.amsaccountsd", process: "amsaccountsd", migbypass: false) { proc in
                            guard let proc else {
                                mgr.logmsg("rc init failed")
                                return
                            }
                            mgr.logmsg("rc init succeeded!")
                            mgr.eligibilitystate = euenabler_overwrite_eligibility(proc) == 0
                            mgr.logmsg("overwrite_eligibility() returned: \(mgr.eligibilitystate! ? "success" : "failure")")
                            proc.destroy()
                        }
                    } label: {
                        HStack {
                            Text("Overwrite eligibility (one time setup)")
                            if let state = mgr.eligibilitystate {
                                Spacer()
                                if state {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .disabled(mgr.eligibilitystate ?? false)
                    
                    Button {
                        mgr.eu1progress = 0.0
                        mgr.eu2progress = 0.0
                        mgr.eu1running = true
                        mgr.eu2running = true
                        mgr.rcinitDaemon(serviceName: "com.apple.managedappdistributiond.xpc", process: "managedappdistributiond", migbypass: false) { proc in
                            guard let proc else {
                                mgr.logmsg("rc init failed")
                                mgr.eu1running = false
                                return
                            }
                            mgr.logmsg("rc init succeeded!")
                            euenabler_override_country_code(proc) { progress in
                                DispatchQueue.main.async {
                                    self.mgr.eu1progress = progress
                                }
                            }
                            proc.destroy()
                            DispatchQueue.main.async {
                                mgr.eu1running = false
                            }
                        }
                        // fix unable to load app info
                        mgr.rcinitDaemon(serviceName: "com.apple.appstorecomponentsd.xpc", process: "appstorecomponentsd", migbypass: false) { proc in
                            guard let proc else {
                                mgr.logmsg("rc init failed")
                                mgr.eu2running = false
                                return
                            }
                            mgr.logmsg("rc init succeeded!")
                            euenabler_override_country_code(proc) { progress in
                                DispatchQueue.main.async {
                                    self.mgr.eu2progress = progress
                                }
                            }
                            proc.destroy()
                            DispatchQueue.main.async {
                                mgr.eu2running = false
                            }
                        }
                    } label: {
                        HStack {
                            if mgr.eu1running || mgr.eu2running {
                                ProgressView(value: (mgr.eu1progress + mgr.eu2progress)/2)
                                    .progressViewStyle(.circular)
                                    .frame(width: 18, height: 18)
                                Text("Running...")
                                Spacer()
                                Text("\(Int((mgr.eu1progress + mgr.eu2progress)/2 * 100))%")
                            } else {
                                Text("Enable Spoof EU Region")
                                Spacer()
                                if mgr.eu1progress + mgr.eu2progress == 2 {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundColor(.green)
                                } else if mgr.dsattempted && mgr.dsfailed {
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                    .disabled(mgr.eu1running || mgr.eu2running || mgr.eu1progress+mgr.eu2progress == 2)
                } footer: {
                    Text("Enables installing of EU/Japan Marketplace apps.")
                }
                .disabled(isdebugged() || mgr.rcrunning || !mgr.rcready)
            }
            
            Section {
                Button {
                    youtube_tweak(mgr.ytProc)
                } label: {
                    Text("Generic Youtube Tweaks")
                }
            }
            
            Section {
                Button {
                    _ = mgr.rccall(name: "exit", args: [0], timeout: 100)
                } label: {
                    Text("Respring")
                }
            } header: {
                Text("Tools")
            }
            
            Section {
                TextField("Process name", text: $customProcessName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("File path", text: $customFilePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1)

                Button {
                    var fetchedData: Data? = nil
                    run("Read File \(customFilePath) via \(customProcessName)") {
                        let result = self.readRemoteFile(process: self.customProcessName, path: self.customFilePath)
                        fetchedData = result.data
                        return result.message
                    } onComplete: { msg in
                        self.customLastResult = msg
                        self.customLastFileData = fetchedData
                    }
                } label: {
                    Text("Read File")
                }

                if !customLastResult.isEmpty {
                    Text(customLastResult)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                if let data = customLastFileData {
                    Text(previewString(for: data))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(10)

                    Button {
                        saveLastFileDataToDocuments()
                    } label: {
                        Text("Save to App Documents")
                    }
                }
            } header: {
                Text("Remote File Reader")
            } footer: {
                Text("Opens, reads, and closes the file inside the target process (so it's read under that process's file access), then copies the bytes back. Read-only — never writes to the remote file.")
            }
            .disabled(!mgr.rcready || running)

            Section {
                HStack(alignment: .top) {
                    AsyncImage(url: URL(string: "https://github.com/khanhduytran0.png")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("Duy Tran")
                            .font(.headline)
                        
                        Text("Responsible for most things related to remotecall.")
                            .font(.subheadline)
                            .foregroundColor(Color.secondary)
                    }
                    
                    Spacer()
                }
                .onTapGesture {
                    if let url = URL(string: "https://github.com/khanhduytran0"),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }
                
                HStack(alignment: .top) {
                    AsyncImage(url: URL(string: "https://github.com/zeroxjf.png")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("0xjf")
                            .font(.headline)
                        
                        Text("Powercuff and SBCustomizer")
                            .font(.subheadline)
                            .foregroundColor(Color.secondary)
                    }
                    
                    Spacer()
                }
                .onTapGesture {
                    if let url = URL(string: "https://github.com/zeroxjf"),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }
                
                HStack(alignment: .top) {
                    AsyncImage(url: URL(string: "https://github.com/Scr-eam.png")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    VStack(alignment: .leading) {
                        Text("Scream")
                            .font(.headline)
                        
                        Text("Fixed Hide Icon Labels")
                            .font(.subheadline)
                            .foregroundColor(Color.secondary)
                    }
                    
                    Spacer()
                }
                .onTapGesture {
                    if let url = URL(string: "https://github.com/Scr-eam"),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("Credits")
            }
        }
        .navigationTitle(Text("Tweaks"))
        .onDisappear {
            if freakyrunning, let proc = mgr.sbProc {
                stopfreakydog(proc)
            }
        }
    }

    private func run(_ name: String, _ work: @escaping () -> String, onComplete: ((String) -> Void)? = nil) {
        guard mgr.rcready, !running else { return }
        running = true
        mgr.logmsg("(rc) \(name)...")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.mgr.logmsg("(rc) \(result)")
                onComplete?(result)
                if self.isRemoteCallFailure(result) {
                    Alertinator.shared.alert(title: "\(name) Failed", body: result)
                }
                self.running = false
            }
        }
    }

    private func isRemoteCallFailure(_ result: String) -> Bool {
        let lowercased = result.lowercased()
        return lowercased.contains("-> -1") ||
            lowercased.contains("-> failed") ||
            lowercased.contains(": failed") ||
            lowercased.contains("failed to")
    }

    private func togglefreakydog() {
        guard mgr.rcready, let proc = mgr.sbProc else { return }

        if freakyrunning {
            stopfreakydog(proc)
            return
        }

        let view = enable_freaky_dog_overlay(proc)
        guard view != 0 else {
            mgr.logmsg("(rc) enable_freaky_dog_overlay() failed")
            return
        }

        let seq = freakyseq + 1
        freakyseq = seq
        freakyrunning = true
        mgr.logmsg("(rc) enable_freaky_dog_overlay() -> 0x\(String(view, radix: 16))")

        let screen = UIScreen.main.bounds
        let maxw = max(Int(screen.width), 200)
        let maxh = max(Int(screen.height), 300)

        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let shouldcontinue = DispatchQueue.main.sync { () -> Bool in
                    self.freakyrunning && self.freakyseq == seq && self.mgr.rcready && self.mgr.sbProc != nil
                }
                if !shouldcontinue {
                    break
                }

                let size = Int.random(in: 110...220)
                let x = Int.random(in: 0...max(maxw - size, 0))
                let y = Int.random(in: 40...max(maxh - size, 40))
                let result = move_freaky_dog_overlay(proc, view, Int32(x), Int32(y), Int32(size), Int32(size))
                if result != 0 {
                    DispatchQueue.main.async {
                        self.mgr.logmsg("(rc) move_freaky_dog_overlay() failed: \(result)")
                        self.stopfreakydog(proc)
                    }
                    break
                }

                usleep(UInt32.random(in: 25000...90000))
            }
        }
    }

    private func stopfreakydog(_ proc: RemoteCall) {
        freakyrunning = false
        freakyseq += 1
        let result = disable_freaky_dog_overlay(proc)
        mgr.logmsg("(rc) disable_freaky_dog_overlay() -> \(result)")
    }

    /// Runs on a background queue (called from inside `run`'s work closure).
    /// Pulled out of the button's `body` expression because the extra guards/
    /// NSString bridging inline was enough to blow up SwiftUI's type-checker.
    private func readRemoteFile(process rawProcess: String, path rawPath: String) -> (message: String, data: Data?) {
        let process = rawProcess.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !process.isEmpty else { return ("custom: missing process name", nil) }
        guard !path.isEmpty else { return ("custom: missing file path", nil) }

        guard let proc = RemoteCall(process: process, useMigFilterBypass: false) else {
            return ("custom: RemoteCall init failed for \(process)", nil)
        }
        defer { proc.destroy() }

        var errorMessage: NSString?
        guard let data = rc_read_remote_file(proc, path, &errorMessage) else {
            let errorText = (errorMessage as String?) ?? "unknown error"
            return ("custom: read failed: \(errorText)", nil)
        }

        return ("custom: read \(path) via \(process) -> \(data.count) bytes", data)
    }

    private func previewString(for data: Data, maxBytes: Int = 2048) -> String {
        let slice = data.prefix(maxBytes)
        let more = data.count > maxBytes ? "\n… (+\(data.count - maxBytes) more bytes)" : ""
        if let text = String(data: slice, encoding: .utf8) {
            return text + more
        }
        let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        return hex + more
    }

    private func saveLastFileDataToDocuments() {
        guard let data = customLastFileData else { return }
        let name = (customFilePath as NSString).lastPathComponent
        let safeName = name.isEmpty ? "remote_file.bin" : name
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dest = docs.appendingPathComponent(safeName)
        do {
            try data.write(to: dest)
            mgr.logmsg("(rc) saved \(data.count) bytes to \(dest.path)")
        } catch {
            mgr.logmsg("(rc) failed to save file: \(error.localizedDescription)")
        }
    }
}
