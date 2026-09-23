//
//  ClipboardView.swift
//  Tether
//
//  Clipboard history: text and images from both sides, kept on disk. Tap an
//  entry to put it on this iPhone's clipboard; the context menu sends it to
//  the desktop, shares it or removes it. Send / Get need the Wi-Fi session.
//

import SwiftUI

struct ClipboardView: View {
    @Environment(TetherViewModel.self) private var viewModel
    @State private var query = ""
    @State private var confirmClear = false

    private var entries: [ClipboardEntry] {
        let all = viewModel.clipboardHistory
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.content.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.appState == .connected {
                    Section {
                        HStack(spacing: 12) {
                            clipboardActionButton(
                                title: "Send to Desktop",
                                subtitle: "Copy iPhone clipboard",
                                icon: "arrow.up.circle.fill",
                                color: .teal
                            ) {
                                viewModel.sendClipboard()
                            }

                            clipboardActionButton(
                                title: "Get from Desktop",
                                subtitle: "Fetch desktop clipboard",
                                icon: "arrow.down.circle.fill",
                                color: .indigo
                            ) {
                                viewModel.requestClipboard()
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(entries) { entry in
                            clipboardEntryRow(entry)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.history.remove(entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text("History")
                } footer: {
                    if !viewModel.clipboardHistory.isEmpty {
                        Text("Tap to copy. Swipe left to delete. Kept on this iPhone, \(ClipboardHistoryStore.maxEntries) entries at most.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Search history")
            .navigationTitle("Clipboard")
            .toolbar {
                if !viewModel.clipboardHistory.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            confirmClear = true
                        }
                    }
                }
            }
            .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) {
                    viewModel.history.clear()
                }
            } message: {
                Text("Removes every entry and stored image from this iPhone.")
            }
        }
    }

    // MARK: - Components

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(query.isEmpty ? "No clipboard activity yet" : "No matches")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private func clipboardActionButton(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func copy(_ entry: ClipboardEntry) {
        if entry.isImage {
            if let png = viewModel.history.imageData(for: entry) {
                viewModel.copyImageToLocalClipboard(png)
            }
        } else {
            viewModel.copyToLocalClipboard(entry.content)
        }
    }

    private func clipboardEntryRow(_ entry: ClipboardEntry) -> some View {
        Button {
            copy(entry)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.source.isRemote ? "desktopcomputer" : "iphone")
                    .font(.subheadline)
                    .foregroundStyle(entry.source.isRemote ? .indigo : .teal)
                    .frame(width: 24)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    if entry.isImage {
                        if let image = viewModel.history.thumbnail(for: entry) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel(entry.content)
                        } else {
                            Label(entry.content, systemImage: "photo")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(entry.content)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                    }

                    HStack(spacing: 6) {
                        Text(entry.source.displayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(entry.source.isRemote ? .indigo : .teal)

                        Text("·")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        Text(entry.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if entry.isImage {
                            Text("·")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(entry.content)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies to this iPhone's clipboard")
        .contextMenu {
            Button {
                copy(entry)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            if viewModel.appState == .connected {
                Button {
                    viewModel.sendToDesktop(entry)
                } label: {
                    Label("Send to Desktop", systemImage: "arrow.up.circle")
                }
            }

            if entry.isImage {
                if let png = viewModel.history.imageData(for: entry), let image = UIImage(data: png) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(entry.content, image: Image(uiImage: image))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                ShareLink(item: entry.content) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Divider()

            Button(role: .destructive) {
                viewModel.history.remove(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    ClipboardView()
        .environment(TetherViewModel.previewMock)
        .preferredColorScheme(.dark)
}
