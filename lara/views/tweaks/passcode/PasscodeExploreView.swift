//
//  PasscodeExploreView.swift
//  lara
//
//  Created by neonmodder123 on 20/05/2026.
//

import SwiftUI

struct PasscodeExploreView: View {
    @ObservedObject var mgr: laramgr
    @ObservedObject private var gallery = PasscodeGalleryManager.shared

    @State private var searchTerm = ""
    @State private var alertMessage: String?
    var onImport: ((URL) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    @State private var showRepoMgr = false
    
    private func handleDownload(_ theme: PasscodeGalleryTheme) async {
        do {
            try await gallery.downloadAndImport(theme)
            let dest = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(theme.name + ".passthm")
            onImport?(dest)
            dismiss()
        } catch { alertMessage = error.localizedDescription }
    }

    private var displayed: [PasscodeGalleryTheme] {
        guard !searchTerm.isEmpty else { return gallery.themes }
        let q = searchTerm.lowercased()
        return gallery.themes.filter {
            $0.name.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.contact.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(displayed) { theme in
                    PasscodeGalleryCard(
                        theme: theme,
                        previewURL: gallery.previewURL(for: theme),
                        isDownloading: gallery.isDownloading(theme)
                    ) { Task { await handleDownload(theme) } }
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showRepoMgr = true
                } label: {
                    Image(systemName: "shippingbox")
                }
            }
        }
        .sheet(isPresented: $showRepoMgr) {
            PasscodeRepoView()
        }
        .navigationTitle("Explore Passcode Themes")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchTerm, prompt: "Search themes or authors")
        .refreshable { await gallery.loadThemes(forceRefresh: true) }
        .task { if gallery.themes.isEmpty { await gallery.loadThemes() } }
        .alert("Passcode Themes", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(alertMessage ?? "") }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading themes…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Could not load themes.")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Retry") { Task { await gallery.loadThemes(forceRefresh: true) } }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct PasscodeGalleryCard: View {
    let theme: PasscodeGalleryTheme
    let previewURL: URL?
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let previewURL {
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case .success(let img):
                        img
                            .resizable()
                            .interpolation(.low)
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .background(Color.black.opacity(0.001))
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(theme.name).font(.headline).lineLimit(1)
                        Text(theme.contact.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                if !theme.description.isEmpty {
                    Text(theme.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(action: onDownload) {
                    HStack {
                        if isDownloading { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "arrow.down.circle") }
                        Text("Import Theme")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
            }
            .padding()
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [.gray.opacity(0.35), .gray.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "lock.rectangle.stack")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
    }
}
