//
//  MainWindowView.swift
//  Sona
//
//  主窗口 · NavigationSplitView
//

import SwiftUI
import Combine

enum SidebarSelection: Hashable {
    case library
    case local
    case localPlaylist(id: String)
    case quarkPlaylist(id: String)
    case aliyunPlaylist(id: String)
}

struct MainWindowView: View {
    @EnvironmentObject var player: AudioPlayerService
    @EnvironmentObject var library: LocalLibraryService
    @EnvironmentObject var quarkAuth: QuarkAuthService
    @EnvironmentObject var quarkShare: QuarkShareService
    @EnvironmentObject var aliyunShare: AliyunShareService
    @EnvironmentObject var proxy: LocalStreamProxy
    @EnvironmentObject var toast: ToastService

    @State private var selection: SidebarSelection? = .library
    @State private var searchText: String = ""
    @State private var showQuarkImport = false
    @State private var showQuarkLogin = false
    @State private var observers: [AnyCancellable] = []

    var body: some View {
        ZStack {
            // 自适应背景
            backgroundLayer

            NavigationSplitView {
                SidebarView(
                    selection: $selection,
                    showQuarkImport: $showQuarkImport,
                    showQuarkLogin: $showQuarkLogin
                )
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            } detail: {
                detailView
                    // 用 selection 派生 key 强制重建，避免 SwiftUI 复用旧分支导致「点了没反应」
                    .id(selectionKey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .searchable(text: $searchText, prompt: "搜索标题 / 艺人 / 专辑")
            }
            .navigationSplitViewStyle(.balanced)
        }
        .safeAreaInset(edge: .bottom) {
            PlayerBarView()
        }
        .overlay(alignment: .top) {
            toastBanner
        }
        .sheet(isPresented: $showQuarkImport) {
            CloudImportSheet()
        }
        .sheet(isPresented: $showQuarkLogin) {
            QuarkLoginSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sonaShowQuarkImport)) { _ in
            showQuarkImport = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .sonaShowQuarkLogin)) { _ in
            showQuarkLogin = true
        }
        .onChange(of: selection) { _ in
            // 切换歌单时清空搜索词，否则残留关键词会让新歌单看起来「点了没反应」
            if !searchText.isEmpty { searchText = "" }
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    /// detail 视图的重建 key，保证每次切换导航项都会重新渲染
    private var selectionKey: String {
        switch selection {
        case .library: return "library"
        case .local: return "local"
        case .localPlaylist(let id): return "localPlaylist-\(id)"
        case .quarkPlaylist(let id): return "quarkPlaylist-\(id)"
        case .aliyunPlaylist(let id): return "aliyunPlaylist-\(id)"
        case .none: return "none"
        }
    }

    // MARK: - Toast 提示栏

    @ViewBuilder
    private var toastBanner: some View {
        if let toast = toast.current {
            HStack(spacing: 8) {
                Image(systemName: toast.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(toast.tint)
                Text(toast.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
            )
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let track = player.currentTrack,
           let data = track.artworkData,
           let image = NSImage(data: data) {
            // 当前播放曲目封面的极弱泛光氛围层
            // ⚠️ 必须用 GeometryReader 约束尺寸并 downscale：
            // 若直接 aspectRatio(.fill) 不加 frame，图片会以原生尺寸（可能 3000px+）
            // 撑破 ZStack 布局，导致整个窗口界面错位异常。
            GeometryReader { geo in
                Image(nsImage: downscaledArtwork(image))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(
                        width: geo.size.width + 200,
                        height: geo.size.height + 200
                    )
                    .blur(radius: 90)
                    .opacity(0.16)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// 把封面缩到小图再做高斯模糊，避免整窗大图实时模糊拖垮 GPU
    private func downscaledArtwork(
        _ image: NSImage,
        maxPixel: CGFloat = 72
    ) -> NSImage {
        let original = image.size
        guard original.width > maxPixel, original.height > maxPixel else { return image }
        let scale = maxPixel / max(original.width, original.height)
        let target = NSSize(width: original.width * scale, height: original.height * scale)
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .copy,
            fraction: 1.0,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.medium]
        )
        resized.unlockFocus()
        return resized
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .library:
            // 资料库 = 本地 / 云端按歌单分开展示，每个歌单独立播放控制
            LibrarySplitView(
                localPlaylists: filteredLocalPlaylists,
                cloudPlaylists: filteredCloudPlaylists,
                onPlayAll: { playlist in
                    player.setQueue(playlist.tracks, startAt: 0)
                },
                onShuffle: { playlist in
                    player.shuffleEnabled = true
                    player.setQueue(playlist.tracks.shuffled(), startAt: 0)
                },
                onDoubleClick: { playlist, index in
                    player.setQueue(playlist.tracks, startAt: index)
                }
            )
        case .local:
            TrackListView(
                title: "本地音乐",
                subtitle: "\(library.playlists.count) 个歌单 · \(filteredLocal.count) 首",
                tracks: filteredLocal,
                onPlayAll: { player.setQueue(filteredLocal, startAt: 0) },
                onShuffle: {
                    player.shuffleEnabled = true
                    player.setQueue(filteredLocal.shuffled(), startAt: 0)
                },
                onDoubleClick: { index in
                    player.setQueue(filteredLocal, startAt: index)
                },
                emptyTitle: "尚无本地音乐",
                emptyHint: "点击侧边栏「本地音乐」旁的 ＋ 选择文件夹"
            )
        case .localPlaylist(let id):
            if let playlist = library.playlist(id: id) {
                let tracks = filteredTracks(for: playlist.tracks)
                TrackListView(
                    title: playlist.name,
                    subtitle: "\(tracks.count) 首 · 本地歌单",
                    tracks: tracks,
                    onPlayAll: { player.setQueue(tracks, startAt: 0) },
                    onShuffle: {
                        player.shuffleEnabled = true
                        player.setQueue(tracks.shuffled(), startAt: 0)
                    },
                    onDoubleClick: { index in
                        player.setQueue(tracks, startAt: index)
                    },
                    emptyTitle: "歌单为空",
                    emptyHint: "该文件夹下没有找到音频文件"
                )
            } else {
                EmptyStateView(
                    title: "歌单不存在",
                    hint: "该本地歌单可能已被移除",
                    systemImage: "folder.badge.questionmark",
                    actionTitle: nil,
                    action: nil
                )
            }
        case .quarkPlaylist(let id):
            if let playlist = quarkShare.playlist(id: id) {
                let tracks = filteredTracks(for: playlist.tracks)
                TrackListView(
                    title: playlist.name,
                    subtitle: "\(tracks.count) 首 · 夸克云端歌单",
                    tracks: tracks,
                    onPlayAll: { player.setQueue(tracks, startAt: 0) },
                    onShuffle: {
                        player.shuffleEnabled = true
                        player.setQueue(tracks.shuffled(), startAt: 0)
                    },
                    onDoubleClick: { index in
                        player.setQueue(tracks, startAt: index)
                    },
                    emptyTitle: "分享内无音频",
                    emptyHint: "该分享链接中没有找到音频文件"
                )
            } else {
                EmptyStateView(
                    title: "歌单不存在",
                    hint: "该夸克歌单可能已被移除",
                    systemImage: "icloud.slash",
                    actionTitle: nil,
                    action: nil
                )
            }
        case .aliyunPlaylist(let id):
            aliyunPlaylistView(id: id)
        case .none:
            EmptyStateView(
                title: "选择分类",
                hint: "在左侧选择「资料库」或任意歌单",
                systemImage: "music.note.list",
                actionTitle: nil,
                action: nil
            )
        }
    }

    /// 阿里云盘歌单页（与夸克同构，仅数据源与文案不同）
    @ViewBuilder
    private func aliyunPlaylistView(id: String) -> some View {
        if let playlist = aliyunShare.playlist(id: id) {
            let tracks = filteredTracks(for: playlist.tracks)
            TrackListView(
                title: playlist.name,
                subtitle: "\(tracks.count) 首 · 阿里云盘歌单",
                tracks: tracks,
                onPlayAll: { player.setQueue(tracks, startAt: 0) },
                onShuffle: {
                    player.shuffleEnabled = true
                    player.setQueue(tracks.shuffled(), startAt: 0)
                },
                onDoubleClick: { index in
                    player.setQueue(tracks, startAt: index)
                },
                emptyTitle: "分享内无音频",
                emptyHint: "该分享链接中没有找到音频文件"
            )
        } else {
            EmptyStateView(
                title: "歌单不存在",
                hint: "该阿里云盘歌单可能已被移除",
                systemImage: "externaldrive.badge.questionmark",
                actionTitle: nil,
                action: nil
            )
        }
    }

    // MARK: - 过滤

    private var filteredLocal: [Track] {
        filter(tracks: library.allTracks)
    }

    private var filteredLocalPlaylists: [Playlist] {
        library.playlists.map { playlist in
            var copy = playlist
            copy.tracks = filter(tracks: playlist.tracks)
            return copy
        }
    }

    private var filteredQuarkPlaylists: [Playlist] {
        quarkShare.playlists.map { playlist in
            var copy = playlist
            copy.tracks = filter(tracks: playlist.tracks)
            return copy
        }
    }

    /// 资料库页的云端歌单（夸克在前，阿里云盘在后）
    private var filteredCloudPlaylists: [Playlist] {
        filteredQuarkPlaylists + filteredAliyunPlaylists
    }

    private var filteredAliyunPlaylists: [Playlist] {
        aliyunShare.playlists.map { playlist in
            var copy = playlist
            copy.tracks = filter(tracks: playlist.tracks)
            return copy
        }
    }

    private func filteredTracks(for tracks: [Track]) -> [Track] {
        filter(tracks: tracks)
    }

    private func filter(tracks: [Track]) -> [Track] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText) ||
            $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - 通用空态

struct EmptyStateView: View {
    let title: String
    let hint: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(hint)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
