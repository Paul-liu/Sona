//
//  LocalLibraryService.swift
//  Sona
//
//  本地音乐扫描与 ID3 元数据提取
//  - 通过 Security-Scoped Bookmark 持久化授权
//  - 基于 AVAsset 异步提取标题/艺人/专辑/封面/时长
//  - 支持多次导入：每次导入生成以文件夹命名的独立歌单
//

import Foundation
import AVFoundation
import AppKit
import Combine

@MainActor
final class LocalLibraryService: ObservableObject {
    static let shared = LocalLibraryService()

    // MARK: - 公开状态

    /// 多次导入后生成的本地歌单列表
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var authorizationStatus: AuthorizationStatus = .notAuthorized

    enum AuthorizationStatus: Equatable {
        case notAuthorized
        case authorized
        case denied
    }

    // MARK: - 私有

    private let bookmarksKey = "Sona.LocalLibrary.Bookmarks"
    /// 当前持有访问权的 scoped URL，key 为 playlist id
    private var activeSecurityScopedURLs: [String: URL] = [:]

    private let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4p", "m4b", "m4r",
        "wav", "aiff", "aif", "aifc",
        "flac", "alac",
        "ogg", "oga",
        "aac", "opus", "amr", "wma"
    ]

    // MARK: - 书签持久化结构

    private struct BookmarkEntry: Codable {
        let id: String
        let bookmark: Data
        let name: String
        let path: String
    }

    private init() {
        Task { await restoreFromBookmarks() }
    }

    deinit {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - 公开聚合

    /// 全部本地曲目（所有歌单聚合，供资料库/搜索使用）
    var allTracks: [Track] {
        playlists.flatMap { $0.tracks }
    }

    /// 本地是否有任意歌单
    var hasPlaylists: Bool {
        !playlists.isEmpty
    }

    // MARK: - 用户操作

    /// 弹出选择文件夹面板，导入为新歌单
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择音乐文件夹"
        panel.message = "Sona 将为该目录创建一个以文件夹命名的歌单"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "导入"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await importFolder(url: url)
            }
        }
    }

    /// 根据 ID 查找歌单
    func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// 移除指定歌单并释放对应安全域授权
    func removePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        activeSecurityScopedURLs[id]?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURLs.removeValue(forKey: id)
        saveBookmarks()
    }

    /// 主动清除全部授权
    func clearAuthorization() {
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
        playlists = []
        authorizationStatus = .notAuthorized
        UserDefaults.standard.removeObject(forKey: bookmarksKey)
    }

    // MARK: - 导入与扫描

    private func importFolder(url: URL) async {
        let baseName = url.lastPathComponent
        let uniqueName = makeUniquePlaylistName(baseName)
        let playlistID = "local-\(UUID().uuidString)"

        let didStart = url.startAccessingSecurityScopedResource()
        guard didStart else {
            authorizationStatus = .denied
            return
        }
        activeSecurityScopedURLs[playlistID] = url
        authorizationStatus = .authorized

        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            appendBookmark(
                BookmarkEntry(
                    id: playlistID,
                    bookmark: bookmark,
                    name: uniqueName,
                    path: url.path
                )
            )
        } catch {
            print("保存书签失败：\(error.localizedDescription)")
        }

        let playlist = Playlist(
            id: playlistID,
            name: uniqueName,
            source: .local,
            tracks: []
        )
        playlists.append(playlist)

        await scan(url: url, playlistID: playlistID)

        if let final = self.playlist(id: playlistID) {
            ToastService.shared.show("已导入 \(final.tracks.count) 首到『\(final.name)』")
        }
    }

    private func makeUniquePlaylistName(_ base: String) -> String {
        let existing = Set(playlists.map { $0.name })
        guard existing.contains(base) else { return base }
        var counter = 2
        while true {
            let candidate = "\(base) \(counter)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    private func scan(url: URL, playlistID: String) async {
        isScanning = true
        defer { isScanning = false }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            updatePlaylist(id: playlistID, tracks: [])
            return
        }

        var found: [Track] = []
        var processed = 0

        while let rawObject = enumerator.nextObject() {
            guard let fileURL = rawObject as? URL else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }

            let track = await extractTrack(from: fileURL, playlistID: playlistID)
            found.append(track)
            processed += 1

            if processed % 25 == 0 {
                updatePlaylist(id: playlistID, tracks: sortedTracks(found))
            }
        }

        updatePlaylist(id: playlistID, tracks: sortedTracks(found))
    }

    private func sortedTracks(_ tracks: [Track]) -> [Track] {
        tracks.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func updatePlaylist(id: String, tracks: [Track]) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].tracks = tracks
    }

    private func extractTrack(from url: URL, playlistID: String) async -> Track {
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "未知艺人"
        var album = "未知专辑"
        var artworkData: Data?
        var duration: TimeInterval = 0

        let asset = AVURLAsset(url: url)
        do {
            let (commonMetadata, durationTime) = try await asset.load(.commonMetadata, .duration)
            duration = durationTime.seconds.isFinite ? durationTime.seconds : 0

            for item in commonMetadata {
                guard let key = item.commonKey?.rawValue else { continue }
                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    if let value = try? await item.load(.stringValue) { title = value }
                case AVMetadataKey.commonKeyArtist.rawValue:
                    if let value = try? await item.load(.stringValue) { artist = value }
                case AVMetadataKey.commonKeyAlbumName.rawValue:
                    if let value = try? await item.load(.stringValue) { album = value }
                case AVMetadataKey.commonKeyArtwork.rawValue:
                    if let data = try? await item.load(.dataValue) {
                        artworkData = data
                    }
                default:
                    break
                }
            }

            if artworkData == nil {
                let formats = try await asset.load(.availableMetadataFormats)
                for format in formats {
                    let items = try await asset.loadMetadata(for: format)
                    for item in items {
                        if let key = item.key as? String, key.uppercased().contains("APIC") {
                            if let data = try? await item.load(.dataValue) {
                                artworkData = data
                                break
                            }
                        }
                    }
                    if artworkData != nil { break }
                }
            }
        } catch {
            print("元数据读取失败 [\(url.lastPathComponent)]: \(error.localizedDescription)")
        }

        let size = (try? fileSize(at: url)) ?? 0

        return Track(
            id: "\(playlistID)-\(url.path)",
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            source: .local,
            url: url,
            artworkData: artworkData,
            sizeBytes: size
        )
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - 书签持久化

    private func loadBookmarks() -> [BookmarkEntry] {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey) else { return [] }
        do {
            return try JSONDecoder().decode([BookmarkEntry].self, from: data)
        } catch {
            print("读取书签列表失败：\(error.localizedDescription)")
            return []
        }
    }

    private func saveBookmarks() {
        var entries: [BookmarkEntry] = []
        for playlist in playlists {
            guard let url = activeSecurityScopedURLs[playlist.id] else { continue }
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                entries.append(BookmarkEntry(
                    id: playlist.id,
                    bookmark: bookmark,
                    name: playlist.name,
                    path: url.path
                ))
            } catch {
                print("重新保存书签失败 [\(playlist.name)]：\(error.localizedDescription)")
            }
        }
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        } catch {
            print("保存书签列表失败：\(error.localizedDescription)")
        }
    }

    private func appendBookmark(_ entry: BookmarkEntry) {
        var entries = loadBookmarks()
        entries.append(entry)
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        } catch {
            print("追加书签失败：\(error.localizedDescription)")
        }
    }

    private func restoreFromBookmarks() async {
        let entries = loadBookmarks()
        guard !entries.isEmpty else { return }

        authorizationStatus = .authorized
        for entry in entries {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: entry.bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    print("Bookmark 已过期 [\(entry.name)]，将在用户操作时刷新")
                }
                guard url.startAccessingSecurityScopedResource() else {
                    print("无法获得安全域访问权 [\(entry.name)]")
                    continue
                }
                activeSecurityScopedURLs[entry.id] = url

                let playlist = Playlist(
                    id: entry.id,
                    name: entry.name,
                    source: .local,
                    tracks: []
                )
                playlists.append(playlist)

                await scan(url: url, playlistID: entry.id)
            } catch {
                print("恢复书签失败 [\(entry.name)]：\(error.localizedDescription)")
            }
        }
    }
}
