//
//  PasscodeView.swift
//  lara
//
//  Created by ruter on 29.03.26.
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Compression
import Combine

private let passcodeThemeStorageRoot = URL(
    fileURLWithPath: "/var/mobile/.DO-NOT-DELETE-lara/PasscodeThemes",
    isDirectory: true
)

private let passcodeBackupDir = passcodeThemeStorageRoot
    .appendingPathComponent("Originals", isDirectory: true)

struct PasscodeKey: Identifiable {
    let id: String
    let digit: String
    let displayName: String
    
    var sourceFilename: String { "\(id).png" }
}

final class PasscodeThemeManager: ObservableObject {
    static let shared = PasscodeThemeManager()

    @Published var isApplying = false
    @Published var progress: Double = 0
    @Published var message = ""

    private let fm = FileManager.default

    func createDirectoriesIfNeeded() {
        try? fm.createDirectory(
            at: passcodeBackupDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func backupIfNeeded(targetPath: String) {
        createDirectoriesIfNeeded()
        let targetURL = URL(fileURLWithPath: targetPath)
        let backupURL = backupURLFor(targetPath: targetPath)

        guard fm.fileExists(atPath: targetPath) else { return }
        
        if !fm.fileExists(atPath: backupURL.path) {
            try? fm.copyItem(at: targetURL, to: backupURL)
        }
    }

    func restoreBackup(targetPath: String) throws {
        let backupURL = backupURLFor(targetPath: targetPath)
        guard fm.fileExists(atPath: backupURL.path) else { return }
        let data = try Data(contentsOf: backupURL)
        
        let overwrite = laramgr.shared.lara_overwritefile(
            target: targetPath,
            data: data
        )
        
        if !overwrite.ok {
            throw NSError(domain: "PasscodeTheme", code: 1, userInfo: [ NSLocalizedDescriptionKey: overwrite.message ]
            )
        }
    }
    
    func restoreAll(basePath: String, logmsg: ((String) -> Void)? = nil) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: basePath) else {
            throw NSError(domain: "PasscodeTheme", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to enumerate cache"])
        }

        var allTargets: [String] = []
        for case let file as String in enumerator {
            guard file.lowercased().hasSuffix(".png") else { continue }
            let fullPath = "\(basePath)/\(file)"
            let lower = file.lowercased()
            for i in 0...9 {
                if lower.contains("other-2-\(i)--dark") ||
                   lower.contains("-\(i)-") ||
                   lower.contains("_\(i)_") ||
                   lower.contains("_\(i)@") {
                    allTargets.append(fullPath)
                    break
                }
            }
        }

        for path in allTargets {
            do {
                try restoreBackup(targetPath: path)
                logmsg?("restored \(path)")
            } catch {
                logmsg?("failed to restore \(path): \(error.localizedDescription)")
            }
        }
    }

    func applyImage(data: Data, to targetPath: String) throws {
        backupIfNeeded(targetPath: targetPath)
        let overwrite = laramgr.shared.lara_overwritefile(target: targetPath, data: data)

        if !overwrite.ok { throw NSError(domain: "PasscodeTheme", code: 2, userInfo: [NSLocalizedDescriptionKey: overwrite.message]) }
    }

    private func backupURLFor(targetPath: String) -> URL {
        let sanitized = targetPath
            .replacingOccurrences(of: "/", with: "_")
        return passcodeBackupDir
            .appendingPathComponent(sanitized)
    }
}

struct PasscodeView: View {
    @ObservedObject var mgr: laramgr
    
    @State private var selectedKeys: [String: Data] = [:]
    @State private var showImagePicker: String?
    @State private var showFilePicker = false
    @State private var processing = false
    @State private var statusMessage: String = ""
    
    @ObservedObject private var themeManager = IconThemeManager.shared
    @ObservedObject private var passcodeThemeManager = PasscodeThemeManager.shared
    
    let initialImportURL: URL?
    
    init(mgr: laramgr, initialImportURL: URL? = nil) {
        self.mgr = mgr
        self.initialImportURL = initialImportURL
    }
    
    let telephonyOptions = [
        "TelephonyUI-15",
        "TelephonyUI-14",
        "TelephonyUI-13",
        "TelephonyUI-12",
        "TelephonyUI-11",
        "TelephonyUI-10",
        "TelephonyUI-9",
        "TelephonyUI-8"
    ]
    
    let passcodeKeys: [PasscodeKey] = [
        PasscodeKey(id: "0", digit: "0", displayName: "0"),
        PasscodeKey(id: "1", digit: "1", displayName: "1"),
        PasscodeKey(id: "2", digit: "2", displayName: "2"),
        PasscodeKey(id: "3", digit: "3", displayName: "3"),
        PasscodeKey(id: "4", digit: "4", displayName: "4"),
        PasscodeKey(id: "5", digit: "5", displayName: "5"),
        PasscodeKey(id: "6", digit: "6", displayName: "6"),
        PasscodeKey(id: "7", digit: "7", displayName: "7"),
        PasscodeKey(id: "8", digit: "8", displayName: "8"),
        PasscodeKey(id: "9", digit: "9", displayName: "9"),
    ]

    private var passcodeKeyMap: [String: PasscodeKey] { Dictionary(uniqueKeysWithValues: passcodeKeys.map { ($0.id, $0) }) }

    private let passcodeKeyLayout: [String?] = [
        "1", "2", "3",
        "4", "5", "6",
        "7", "8", "9",
        nil, "0", nil
    ]
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Import Theme")) {
                    NavigationLink("Explore") {
                        PasscodeExploreView(mgr: mgr) { url in
                            importPassthmFile(url: url)
                        }
                    }
                    Button { showFilePicker = true } label: {
                        Label("Import .passthm / .zip File", systemImage: "square.and.arrow.down")
                    }
                }
                Section {
                    if passcodeThemeManager.isApplying {
                        VStack(spacing: 10) {
                            ProgressView(value: passcodeThemeManager.progress, total: 1.0)
                            Text(passcodeThemeManager.message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
                        ForEach(Array(passcodeKeyLayout.enumerated()), id: \.offset) { _, keyId in
                            if let keyId,
                               let key = passcodeKeyMap[keyId] {

                                PasscodeKeyButton(key: key, imageData: selectedKeys[key.id], onSelect: { showImagePicker = key.id })
                            } else {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                
                Section(header: Text("Apply")) {
                    Button("Apply Passcode Theme") {
                        applyTheme()
                    }
                    .disabled(selectedKeys.isEmpty || processing || passcodeThemeManager.isApplying)
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .foregroundColor(statusMessage.contains("Error") ? .red : .green)
                            .font(.footnote)
                    }
                }
                
                Section(header: Text("Danger Zone")) {
                    Button("Clear All Keys", role: .destructive) {
                        selectedKeys.removeAll()
                    }
                    Button("Restore Original Icons", role: .destructive) { restoreTheme() }
                    .disabled(processing || passcodeThemeManager.isApplying)
                }
            }
            .headerProminence(.increased)
            .navigationTitle("Passcode Theme")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $showImagePicker) { keyId in
                ImagePicker(imageData: $selectedKeys[keyId])
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [UTType(filenameExtension: "passthm") ?? .zip, .zip],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
        .task {
            if let url = initialImportURL {
                importPassthmFile(url: url)
            }
        }
    }
    
    func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importPassthmFile(url: url)
        case .failure(let error):
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
    
    func importPassthmFile(url: URL) {
        processing = true
        statusMessage = "Importing theme..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                let data = try Data(contentsOf: url)
                let tempDir =
                    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer {
                    try? FileManager.default.removeItem(at: tempDir)
                }
                
                let zipPath = tempDir.appendingPathComponent("theme.zip")
                try data.write(to: zipPath)
                try themeManager.unzipFile(at: zipPath, to: tempDir)
                
                let extractedKeys = try findAndExtractImages(from: tempDir)
                
                DispatchQueue.main.async {
                    for (keyId, imageData) in extractedKeys {
                        selectedKeys[keyId] = imageData
                    }
                    processing = false
                    statusMessage = "Imported \(extractedKeys.count) key(s)"
                }
            } catch {
                DispatchQueue.main.async {
                    processing = false
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    struct ZipEntry {
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let nameLength: Int
        let extraLength: Int
    }

    func readLocalFileEntry(
        data: Data,
        offset: Int
    ) -> ZipEntry? {
        guard offset + 30 <= data.count else { return nil }
        let compressionMethod = data.subdata(in: offset + 8..<offset + 10).withUnsafeBytes { $0.load(as: UInt16.self) }
        let compressedSize = Int(data.subdata(in: offset + 18..<offset + 22).withUnsafeBytes { $0.load(as: UInt32.self) })
        let uncompressedSize = Int(data.subdata(in: offset + 22..<offset + 26).withUnsafeBytes { $0.load(as: UInt32.self) })
        let nameLength = Int(data.subdata(in: offset + 26..<offset + 28).withUnsafeBytes { $0.load(as: UInt16.self) })
        let extraLength = Int(data.subdata(in: offset + 28..<offset + 30).withUnsafeBytes { $0.load(as: UInt16.self) })

        return ZipEntry(
            compressionMethod: compressionMethod,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            nameLength: nameLength,
            extraLength: extraLength
        )
    }
    
    func decompress(
        deflate data: Data,
        originalSize: Int
    ) -> Data? {
        guard originalSize > 0 else { return Data() }
        let destinationBuffer = UnsafeMutablePointer<UInt8>
            .allocate(capacity: originalSize)
        defer { destinationBuffer.deallocate() }
        
        let result = data.withUnsafeBytes { (sourceBuffer: UnsafeRawBufferPointer) -> Int in
            guard let baseAddress = sourceBuffer.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                originalSize,
                baseAddress.assumingMemoryBound(to: UInt8.self),
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        
        return result == originalSize ? Data(bytes: destinationBuffer, count: originalSize) : nil
    }
    
    func findAndExtractImages(from directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return result }
        
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "png" || ext == "jpg" || ext == "jpeg" else { continue }
            
            let filename = fileURL.lastPathComponent.lowercased()
            let fullPath = fileURL.path.lowercased()
            
            if let keyId =
                matchFilenameToKey(filename) ??
                matchFilenameToKey(fullPath) {
                if let imageData = try? Data(contentsOf: fileURL) {
                    result[keyId] = imageData
                }
            }
        }
        
        return result
    }
    
    func matchFilenameToKey(_ filename: String) -> String? {
        let lowercased = filename.lowercased()
        
        for i in 0...9 {
            if lowercased.contains("other-2-\(i)--dark") ||
                lowercased.contains("-\(i)-") ||
                lowercased.contains("-\(i)@") ||
                lowercased.contains("_\(i)_") ||
                lowercased.contains("_\(i)@") ||
                lowercased.contains("/\(i).png") ||
                lowercased.contains("/\(i).jpg") ||
                lowercased.contains("/\(i).jpeg") {
                return String(i)
            }
        }
        
        return nil
    }
    
    func applyTheme() {
        guard mgr.sbxready else {
            statusMessage = "Error: SBX not ready"
            return
        }

        processing = true
        statusMessage = ""

        DispatchQueue.global(qos: .userInitiated).async {
            guard let basePath = resolveTelephonyBasePath() else {
                DispatchQueue.main.async {
                    processing = false
                    statusMessage = "Error: TelephonyUI cache not found"
                }
                return
            }

            let fm = FileManager.default
            guard let enumerator = fm.enumerator(atPath: basePath) else {
                DispatchQueue.main.async {
                    processing = false
                    statusMessage = "Error: failed to enumerate cache"
                }
                return
            }

            var targets: [String: [String]] = [:]

            for case let file as String in enumerator {
                let lower = file.lowercased()
                guard lower.hasSuffix(".png") else { continue }

                for i in 0...9 {
                    if lower.contains("other-2-\(i)--dark") ||
                        lower.contains("-\(i)-") ||
                        lower.contains("_\(i)_") ||
                        lower.contains("_\(i)@") {
                        targets[String(i), default: []].append("\(basePath)/\(file)")
                    }
                }
            }

            let total = max(Double(selectedKeys.count), 1.0)
            var successCount = 0
            var failCount = 0
            var errors: [String] = []

            DispatchQueue.main.async {
                passcodeThemeManager.isApplying = true
                passcodeThemeManager.progress = 0
                passcodeThemeManager.message = "preparing passcode theme..."
            }

            defer {
                DispatchQueue.main.async {
                    processing = false
                    passcodeThemeManager.isApplying = false
                }
            }

            for (index, item) in selectedKeys.enumerated() {
                autoreleasepool {
                    let keyId = item.key
                    let imageData = item.value
                    let matched = targets[keyId] ?? []

                    DispatchQueue.main.async {
                        passcodeThemeManager.progress = Double(index) / total
                        passcodeThemeManager.message = "applying \(keyId)"
                    }

                    if matched.isEmpty {
                        failCount += 1
                        errors.append("no target found for \(keyId)")
                        return
                    }

                    for path in matched {
                        do {
                            try passcodeThemeManager.applyImage(data: imageData, to: path)
                            successCount += 1
                            mgr.logmsg("applied \(keyId) -> \(path)")
                        } catch {
                            failCount += 1
                            errors.append("\(path): \(error.localizedDescription)")
                            mgr.logmsg("failed \(path): \(error.localizedDescription)")
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                passcodeThemeManager.progress = 1.0

                if failCount == 0 {
                    passcodeThemeManager.message = "Done"
                    statusMessage = "applied \(successCount) file(s)"
                } else {
                    passcodeThemeManager.message = "Completed with errors"
                    statusMessage = "applied \(successCount), failed \(failCount)\n\n\(errors.joined(separator: "\n"))"
                }
            }
        }
    }

    func resolveTelephonyBasePath() -> String? {
        for version in telephonyOptions {
            let path = "/var/mobile/Library/Caches/\(version)"

            if sbxdirExists(path: path) {
                mgr.logmsg("TelephonyUI cache: \(path)")
                return path
            }
        }
        
        return nil
    }

    func sbxdirExists(path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: path,
            isDirectory: &isDir
        ) && isDir.boolValue
    }
    
    func restoreTheme() {
        guard mgr.sbxready else {
            statusMessage = "Error: SBX not ready"
            return
        }
        processing = true
        statusMessage = ""

        DispatchQueue.global(qos: .userInitiated).async {
            guard let basePath = resolveTelephonyBasePath() else {
                DispatchQueue.main.async {
                    processing = false
                    statusMessage = "Error: TelephonyUI cache not found"
                }
                return
            }

            do {
                try passcodeThemeManager.restoreAll(basePath: basePath) { msg in
                    mgr.logmsg(msg)
                }
                DispatchQueue.main.async {
                    processing = false
                    statusMessage = "Originals restored"
                }
            } catch {
                DispatchQueue.main.async {
                    processing = false
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct PasscodeKeyButton: View {
    let key: PasscodeKey
    let imageData: Data?
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            GeometryReader { geo in
                ZStack {
                    if let data = imageData,
                       let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: geo.size.width,
                                height: geo.size.width
                            )
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                    }
                }
                .frame(
                    width: geo.size.width,
                    height: geo.size.width
                )
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var imageData: Data?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(
        context: Context
    ) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        
        let picker = PHPickerViewController(
            configuration: config
        )
        
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(
        _ uiViewController: PHPickerViewController,
        context: Context
    ) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            parent.dismiss()
            guard let result = results.first else { return }
            result.itemProvider.loadObject( ofClass: UIImage.self ) {
                [weak self] object, error in
                guard let image = object as? UIImage else { return }
                guard let self else { return }
                let resized = self.resizeImage(
                    image,
                    targetHeight: 202
                )
                if let pngData = resized.pngData() {
                    DispatchQueue.main.async {
                        self.parent.imageData = pngData
                    }
                }
            }
        }

        func resizeImage(
            _ image: UIImage,
            targetHeight: CGFloat
        ) -> UIImage {
            let scale = targetHeight / image.size.height
            let newWidth = image.size.width * scale
            let newSize = CGSize(
                width: newWidth,
                height: targetHeight
            )
            
            let renderer = UIGraphicsImageRenderer( size: newSize )
            return renderer.image { _ in
                image.draw(
                    in: CGRect(
                        origin: .zero,
                        size: newSize
                    )
                )
            }
        }
    }
}
