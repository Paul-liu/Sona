//
//  LibrarySectionView.swift
//  Sona
//
//  资料库分栏目：本地导入 / 云端导入各自独立成栏
//  - 每栏带独立的小标题、数量、播放全部 / 随机按钮
//  - 行样式与 TrackListView 保持一致
//  - 多次导入时，每个歌单独立成一个栏目
//

import SwiftUI
import AppKit

struct LibrarySectionView: View {
    let title: String
    let systemImage: String
    let accentColor: Color
    let tracks: [Track]

    var onPlayAll: () -> Void
    var onShuffle: () -> Void
    var onDoubleClick: (Int) -> Void
    var emptyHint: String

    @EnvironmentObject var player: AudioPlayerService
    @State private var hoveredID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if tracks.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text(emptyHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        row(index: index, track: track)
                    }
                }
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - 栏目标题

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)

            Text(title)
                .font(.system(size: 16, weight: .semibold))

            Text("\(tracks.count) 首")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())

            Spacer()

            if !tracks.isEmpty {
                HStack(spacing: 8) {
                    Button(action: onShuffle) {
                        Label("随机", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("随机播放本栏全部曲目")

                    Button(action: onPlayAll) {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("顺序播放本栏全部曲目")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    // MARK: - 行

    private func row(index: Int, track: Track) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        let isHovered = hoveredID == track.id
        let isPlayingThis = isCurrent && player.isPlaying

        return HStack(spacing: 0) {
            ZStack {
                if isPlayingThis {
                    EqualizerIndicator()
                } else if isHovered {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(isCurrent ? accentColor : .secondary)
                }
            }
            .frame(width: 56)

            HStack(spacing: 8) {
                if let data = track.artworkData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? accentColor : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)

            Text(track.album)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)

            Text(track.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            SourceBadge(source: track.source)
                .frame(width: 80, alignment: .center)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 28)
        .background(
            Group {
                if isCurrent {
                    accentColor.opacity(0.10)
                } else if isHovered {
                    Color.primary.opacity(0.045)
                } else {
                    Color.clear
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? track.id : (hoveredID == track.id ? nil : hoveredID)
        }
        .onTapGesture(count: 2) {
            onDoubleClick(index)
        }
    }
}

// MARK: - 资料库分栏目总视图

struct LibrarySplitView: View {
    let localPlaylists: [Playlist]
    /// 云端歌单（夸克 + 阿里云盘），按 source 决定图标与配色
    let cloudPlaylists: [Playlist]

    var onPlayAll: (Playlist) -> Void
    var onShuffle: (Playlist) -> Void
    var onDoubleClick: (Playlist, Int) -> Void

    @EnvironmentObject var player: AudioPlayerService

    private var totalLocalTracks: Int {
        localPlaylists.reduce(0) { $0 + $1.tracks.count }
    }

    private var totalCloudTracks: Int {
        cloudPlaylists.reduce(0) { $0 + $1.tracks.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 总标题
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("资料库")
                        .font(.system(size: 26, weight: .bold))
                    Text("本地 \(localPlaylists.count) 个歌单 · \(totalLocalTracks) 首 · 云端 \(cloudPlaylists.count) 个歌单 · \(totalCloudTracks) 首")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 14)

            Divider().opacity(0.15)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    if localPlaylists.isEmpty && cloudPlaylists.isEmpty {
                        EmptyStateView(
                            title: "资料库为空",
                            hint: "在侧边栏导入本地文件夹，或导入夸克 / 阿里云盘分享链接",
                            systemImage: "music.note.list",
                            actionTitle: nil,
                            action: nil
                        )
                        .padding(.top, 60)
                    } else {
                        // 本地歌单：每个歌单独立成栏
                        ForEach(Array(localPlaylists.enumerated()), id: \.element.id) { index, playlist in
                            LibrarySectionView(
                                title: playlist.name,
                                systemImage: "folder.fill",
                                accentColor: Color(red: 10.0 / 255.0, green: 132.0 / 255.0, blue: 1.0),
                                tracks: playlist.tracks,
                                onPlayAll: { onPlayAll(playlist) },
                                onShuffle: { onShuffle(playlist) },
                                onDoubleClick: { onDoubleClick(playlist, $0) },
                                emptyHint: "该文件夹下没有找到音频文件"
                            )

                            if index < localPlaylists.count - 1 || !cloudPlaylists.isEmpty {
                                Divider()
                                    .padding(.horizontal, 28)
                                    .opacity(0.15)
                            }
                        }

                        // 云端歌单：每个歌单独立成栏
                        ForEach(Array(cloudPlaylists.enumerated()), id: \.element.id) { index, playlist in
                            LibrarySectionView(
                                title: playlist.name,
                                systemImage: iconFor(playlist.source),
                                accentColor: accentFor(playlist.source),
                                tracks: playlist.tracks,
                                onPlayAll: { onPlayAll(playlist) },
                                onShuffle: { onShuffle(playlist) },
                                onDoubleClick: { onDoubleClick(playlist, $0) },
                                emptyHint: "该分享中没有找到音频文件"
                            )

                            if index < cloudPlaylists.count - 1 {
                                Divider()
                                    .padding(.horizontal, 28)
                                    .opacity(0.15)
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func iconFor(_ source: TrackSource) -> String {
        switch source {
        case .local: return "folder.fill"
        case .quark: return "icloud.and.arrow.down.fill"
        case .aliyun: return "externaldrive.fill.badge.checkmark"
        }
    }

    private func accentFor(_ source: TrackSource) -> Color {
        switch source {
        case .local: return Color(red: 10.0 / 255.0, green: 132.0 / 255.0, blue: 1.0)
        case .quark: return Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
        case .aliyun: return Color(red: 0.0, green: 0.48, blue: 1.0)
        }
    }
}
