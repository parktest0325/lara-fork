import SwiftUI

private struct DarkBoardExploreAlert: Identifiable {
    let id = UUID()
    let message: String
}

struct DarkBoardExploreView: View {
    @ObservedObject private var gallery = IconThemeGalleryManager.shared
    @ObservedObject private var themes = IconThemeManager.shared

    @State private var filter: IconThemeGalleryFilter = .random
    @State private var searchTerm = ""
    @State private var alert: DarkBoardExploreAlert?
    @State private var displayedThemes: [GalleryTheme] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                filterBar
                content
            }
            .padding()
        }
        .navigationTitle("Explore")
        .searchable(text: $searchTerm, prompt: "Search themes or authors")
        .refreshable {
            await gallery.loadThemes(forceRefresh: true)
            updateDisplayedThemes()
        }
        .task {
            if gallery.themes.isEmpty {
                await gallery.loadThemes()
            }
            updateDisplayedThemes()
        }
        .onChange(of: searchTerm)     { _ in updateDisplayedThemes() }
        .onChange(of: filter)         { _ in updateDisplayedThemes() }
        .onChange(of: gallery.themes) { _ in updateDisplayedThemes() }
        .alert(item: $alert) { a in
            Alert(title: Text("Theme Gallery"), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    private func updateDisplayedThemes() {
        displayedThemes = gallery.filteredThemes(searchTerm: searchTerm, filter: filter)
    }

    private var filterBar: some View {
        HStack {
            Menu {
                ForEach(IconThemeGalleryFilter.allCases) { candidate in
                    Button {
                        filter = candidate
                    } label: {
                        if filter == candidate {
                            Label(candidate.rawValue, systemImage: "checkmark")
                        } else {
                            Text(candidate.rawValue)
                        }
                    }
                }
            } label: {
                Label(filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }
            Spacer()
            if gallery.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = gallery.loadError, gallery.themes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Could not load the Cowabunga gallery.")
                    .font(.headline)
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task {
                        await gallery.loadThemes(forceRefresh: true)
                        updateDisplayedThemes()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        } else if displayedThemes.isEmpty && gallery.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading themes...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else if displayedThemes.isEmpty {
            Text("No themes matched your search.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            LazyVStack(spacing: 14) {
                ForEach(displayedThemes) { theme in
                    GalleryThemeCard(theme: theme, previewURL: gallery.previewURL(for: theme), isImported: themes.theme(named: theme.name) != nil, isDownloading: gallery.isDownloading(theme)) {
                        Task {
                            do {
                                try await gallery.downloadAndImport(theme)
                                alert = DarkBoardExploreAlert(message: "Imported \(theme.name).")
                            } catch {
                                alert = DarkBoardExploreAlert(message: error.localizedDescription)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct GalleryThemeCard: View {
    let theme: GalleryTheme
    let previewURL: URL?
    let isImported: Bool
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let previewURL {
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 180)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    default:
                        previewPlaceholder
                    }
                }
            } else {
                previewPlaceholder
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(theme.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(theme.contact.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isImported {
                        Text("Imported")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }
                Text(theme.description)

                Button {
                    Task { await onDownload() }
                } label: {
                    HStack {
                        if isDownloading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: isImported
                                  ? "arrow.triangle.2.circlepath"
                                  : "arrow.down.circle")
                        }

                        Text(isImported ? "Reimport Theme" : "Import Theme")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading)
                .contentShape(Rectangle())
            }
            .padding()
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var previewPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [.gray.opacity(0.35), .gray.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "app.dashed")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 180).frame(maxWidth: .infinity)
    }
}
