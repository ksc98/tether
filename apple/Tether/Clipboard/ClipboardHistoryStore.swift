//
//  ClipboardHistoryStore.swift
//  Tether
//
//  The clipboard history, kept on disk. Every path that moves clipboard data
//  records here: the Wi-Fi session, Bluetooth deliveries in the background,
//  the Sync Clipboard shortcut, and a tapped notification. Text lives in the
//  index; images are PNG files beside it, referenced by name.
//

import CryptoKit
import Foundation
import Observation
import UIKit

// A clipboard history entry.
struct ClipboardEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    enum ClipboardSource: Codable, Equatable {
        case local(String)
        case remote(String)

        var displayName: String {
            switch self {
            case .local(let name): return name
            case .remote(let name): return name
            }
        }

        var isRemote: Bool {
            if case .remote = self { return true }
            return false
        }
    }

    let id: UUID
    let kind: Kind
    // The text, or for an image a label such as "Image, 1.2 MB".
    let content: String
    // PNG file name under the store's images directory, for an image entry.
    let imageFile: String?
    // SHA-256 of the bytes, for finding a repeat without reading files.
    let digest: String
    let byteCount: Int
    var timestamp: Date
    let source: ClipboardSource

    var isImage: Bool { kind == .image }
}

@MainActor
@Observable
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    // Newest first.
    private(set) var entries: [ClipboardEntry] = []

    static let maxEntries = 200
    static let maxImages = 40
    static let maxImageBytes = 32 * 1024 * 1024

    private let directory: URL
    private let indexURL: URL
    private let imagesDirectory: URL
    private let thumbnails = NSCache<NSString, UIImage>()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("ClipboardHistory", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Adding

    // Records text. A repeat of an entry already in the history moves that
    // entry to the top with a fresh timestamp instead of duplicating it.
    // Returns false when the text was already the newest entry.
    @discardableResult
    func addText(_ text: String, source: ClipboardEntry.ClipboardSource) -> Bool {
        guard !text.isEmpty else { return false }
        let digest = Self.digest(of: Data(text.utf8))
        if let first = entries.first, first.digest == digest {
            return false
        }
        if let index = entries.firstIndex(where: { $0.digest == digest }) {
            var moved = entries.remove(at: index)
            moved.timestamp = Date()
            entries.insert(moved, at: 0)
            save()
            return true
        }
        let entry = ClipboardEntry(
            id: UUID(),
            kind: .text,
            content: text,
            imageFile: nil,
            digest: digest,
            byteCount: text.utf8.count,
            timestamp: Date(),
            source: source
        )
        entries.insert(entry, at: 0)
        prune()
        save()
        return true
    }

    // Records a PNG. Same repeat handling as text.
    @discardableResult
    func addImage(_ png: Data, source: ClipboardEntry.ClipboardSource) -> Bool {
        guard !png.isEmpty, png.count <= Self.maxImageBytes else { return false }
        let digest = Self.digest(of: png)
        if let first = entries.first, first.digest == digest {
            return false
        }
        if let index = entries.firstIndex(where: { $0.digest == digest }) {
            var moved = entries.remove(at: index)
            moved.timestamp = Date()
            entries.insert(moved, at: 0)
            save()
            return true
        }
        let id = UUID()
        let file = "\(id.uuidString).png"
        do {
            try png.write(to: imagesDirectory.appendingPathComponent(file), options: .atomic)
        } catch {
            return false
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(png.count), countStyle: .file)
        let entry = ClipboardEntry(
            id: id,
            kind: .image,
            content: "Image, \(size)",
            imageFile: file,
            digest: digest,
            byteCount: png.count,
            timestamp: Date(),
            source: source
        )
        entries.insert(entry, at: 0)
        prune()
        save()
        return true
    }

    // MARK: - Removing

    func remove(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        deleteFile(of: entries.remove(at: index))
        save()
    }

    func clear() {
        for entry in entries {
            deleteFile(of: entry)
        }
        entries.removeAll()
        thumbnails.removeAllObjects()
        save()
    }

    // MARK: - Reading images

    func imageData(for entry: ClipboardEntry) -> Data? {
        guard let file = entry.imageFile else { return nil }
        return try? Data(contentsOf: imagesDirectory.appendingPathComponent(file))
    }

    // A downscaled copy for list rows, cached.
    func thumbnail(for entry: ClipboardEntry) -> UIImage? {
        guard let file = entry.imageFile else { return nil }
        if let cached = thumbnails.object(forKey: file as NSString) {
            return cached
        }
        guard let data = imageData(for: entry), let full = UIImage(data: data) else { return nil }
        let longest = max(full.size.width, full.size.height)
        let scale = min(1, 600 / max(longest, 1))
        let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let thumb = UIGraphicsImageRenderer(size: size).image { _ in
            full.draw(in: CGRect(origin: .zero, size: size))
        }
        thumbnails.setObject(thumb, forKey: file as NSString)
        return thumb
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([ClipboardEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // Keeps the list and the image files within their caps, dropping the oldest.
    private func prune() {
        while entries.count > Self.maxEntries, let last = entries.last {
            deleteFile(of: last)
            entries.removeLast()
        }
        var images = entries.filter(\.isImage).count
        guard images > Self.maxImages else { return }
        for index in stride(from: entries.count - 1, through: 0, by: -1) where entries[index].isImage {
            deleteFile(of: entries.remove(at: index))
            images -= 1
            if images <= Self.maxImages { break }
        }
    }

    private func deleteFile(of entry: ClipboardEntry) {
        guard let file = entry.imageFile else { return }
        thumbnails.removeObject(forKey: file as NSString)
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(file))
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
