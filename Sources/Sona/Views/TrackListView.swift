//
//  TrackListView.swift
//  Sona
//
//  歌曲列表 · 表格风格 + 跳动均衡器 + 悬浮高亮
//

import SwiftUI
import AppKit

struct TrackListView: View {
    let title: String
    let subtitle: String
    let tracks: [Track]

    var onPlayAll: (() -> Void)? = nil
    var onShuffle: (() -> Void)? = nil

    let onDoubleClick: (Int) -> Void
    let emptyTitle: String
    let emptyHint: String

    @EnvironmentObject var player: AudioPlayerService
    @State private var hoveredID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            columnHeader
            Divider().opacity(0.15)
            content
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !tracks.isEmpty {
                HStack(spacing: 10) {
                    if let onShuffle {
                        Button(action: onShuffle) {
                            Label("随机播放", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("随机打乱全部曲目并开始播放")
                    }
                    if let onPlayAll {
                        Button(action: onPlayAll) {
                            Label("播放全部", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("从第一首开始顺序播放")
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    // MARK: - 列头

    @ViewBuilder
    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: 56, alignment: .center)
            Text("标题")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("艺人")
                .frame(width: 200, alignment: .leading)
            Text("专辑")
                .frame(width: 200, alignment: .leading)
            Text("时长")
                .frame(width: 70, alignment: .trailing)
            Text("来源")
                .frame(width: 90, alignment: .center)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if tracks.isEmpty {
            EmptyStateView(
                title: emptyTitle,
                hint: emptyHint,
                systemImage: "music.note.list",
                actionTitle: nil,
                action: nil
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        row(index: index, track: track)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(index: Int, track: Track) -> some View {
        let isCurrent = player.currentTrack?.id == track.id
        let isHovered = hoveredID == track.id
        let isPlayingThis = isCurrent && player.isPlaying

        HStack(spacing: 0) {
            // # 列：当前播放显示跳动均衡器，悬浮显示播放小三角
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
                        .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                }
            }
            .frame(width: 56)

            // 标题
            HStack(spacing: 8) {
                if let data = track.artworkData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(track.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 艺人
            Text(track.artist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)

            // 专辑
            Text(track.album)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)

            // 时长
            Text(track.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            // 来源
            SourceBadge(source: track.source)
                .frame(width: 90, alignment: .center)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 28)
        .background(rowBackground(isCurrent: isCurrent, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? track.id : (hoveredID == track.id ? nil : hoveredID)
        }
        .onTapGesture(count: 2) {
            onDoubleClick(index)
        }
        .contextMenu {
            Button("立即播放") {
                onDoubleClick(index)
            }
            if track.source == .quark {
                Button("打开夸克网盘") {
                    if let url = URL(string: "https://pan.quark.cn/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func rowBackground(isCurrent: Bool, isHovered: Bool) -> some View {
        Group {
            if isCurrent {
                Color.accentColor.opacity(0.10)
            } else if isHovered {
                Color.primary.opacity(0.045)
            } else {
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isCurrent)
    }
}

// MARK: - 均衡器动画

struct EqualizerIndicator: View {
    @State private var heights: [CGFloat] = [8, 14, 10]
    @State private var tick: Int = 0
    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: heights[i])
                    .animation(.easeInOut(duration: 0.28), value: heights[i])
            }
        }
        .frame(width: 14, height: 14)
        .onReceive(timer) { _ in
            // 产生新的随机高度组合（保证相邻两帧明显不同）
            tick = (tick + 1) % 100
            heights = [
                CGFloat.random(in: 5...13),
                CGFloat.random(in: 6...14),
                CGFloat.random(in: 4...12)
            ]
        }
    }
}
