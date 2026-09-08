//
//  PlayerBarView.swift
//  Sona
//
//  底部浮动播放条
//

import SwiftUI
import AppKit

struct PlayerBarView: View {
    @EnvironmentObject var player: AudioPlayerService

    @State private var isScrubbing: Bool = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            errorBanner
            Divider().opacity(0.18)
            HStack(alignment: .center, spacing: 16) {
                trackInfo
                Spacer(minLength: 8)
                centerControls
                Spacer(minLength: 8)
                volumeControls
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(barBackground)
        }
        .frame(height: 78)
    }

    // MARK: - 错误提示条

    @ViewBuilder
    private var errorBanner: some View {
        if let error = player.playbackError {
            HStack(spacing: 10) {
                Image(systemName: player.playbackErrorNeedsRelogin ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if player.playbackErrorNeedsRelogin {
                    Button {
                        NotificationCenter.default.post(name: .sonaShowQuarkLogin, object: nil)
                    } label: {
                        Label("重新登录", systemImage: "qrcode.viewfinder")
                            .controlSize(.small)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    player.dismissError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.10))
        }
    }

    // MARK: - 曲目信息

    @ViewBuilder
    private var trackInfo: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentTrack?.title ?? "未播放")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(player.currentTrack?.artist ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let source = player.currentTrack?.source {
                        SourceBadge(source: source)
                    }
                    if player.isBuffering {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .frame(width: 200, alignment: .leading)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = player.currentTrack?.artworkData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: identifierGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    Image(systemName: player.currentTrack == nil ? "music.note" : "music.quarternote.3")
                        .foregroundStyle(.white.opacity(0.92))
                        .font(.system(size: 22))
                }
        }
    }

    private var identifierGradient: [Color] {
        guard let id = player.currentTrack?.id else {
            return [.indigo, .blue]
        }
        // 用 id 哈希出一个稳定但多样的色对
        let hue = Double(abs(id.hashValue) % 360) / 360
        return [
            Color(hue: hue, saturation: 0.65, brightness: 0.85),
            Color(hue: (hue + 0.18).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.6)
        ]
    }

    // MARK: - 中央控制

    @ViewBuilder
    private var centerControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 20) {
                Button {
                    player.shuffleEnabled.toggle()
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(player.shuffleEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("随机播放")

                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("上一曲")

                Button {
                    player.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 34, height: 34)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(Color(.windowBackgroundColor))
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "暂停 (空格)" : "播放 (空格)")

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("下一曲")

                Button {
                    cycleRepeat()
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(player.repeatMode.label)
            }

            // 进度条 + 时间
            HStack(spacing: 8) {
                Text(formatTime(isScrubbing ? scrubValue : player.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : player.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing && player.duration > 0 {
                            player.seek(to: scrubValue)
                        }
                    }
                )
                .controlSize(.small)

                Text(formatTime(player.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }
        }
        .frame(width: 420)
    }

    // MARK: - 音量

    @ViewBuilder
    private var volumeControls: some View {
        HStack(spacing: 8) {
            Button {
                player.volume = 0
            } label: {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Slider(value: $player.volume, in: 0...1)
                .frame(width: 90)
                .controlSize(.small)
        }
    }

    // MARK: - 工具

    private var barBackground: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            // 顶部 0.5pt 分割微光
            VStack {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.12), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(height: 0.5)
                Spacer()
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 源角标

struct SourceBadge: View {
    let source: TrackSource

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        switch source {
        case .local: return "本地"
        case .quark: return "夸克"
        case .aliyun: return "阿里"
        }
    }

    private var badgeColor: Color {
        switch source {
        case .local: return Color(red: 10.0 / 255.0, green: 132.0 / 255.0, blue: 1.0)
        case .quark: return Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
        case .aliyun: return Color(red: 0.0, green: 0.48, blue: 1.0)
        }
    }
}
