//
//  AudioPlayerService.swift
//  Sona
//
//  AVPlayer 播放器引擎
//  - 维护播放队列、循环模式、随机模式
//  - 集成 MPNowPlayingInfoCenter 与 MPRemoteCommandCenter 联动系统控制
//

import Foundation
import AVFoundation
import MediaPlayer
import Combine
import AppKit

@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    // MARK: - 公开状态

    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering: Bool = false
    /// 播放失败原因（UI 展示错误提示；nil = 无错误）
    @Published private(set) var playbackError: String?
    /// 最近一次错误是否为夸克登录态问题（用于 UI 提供「重新登录」入口）
    @Published private(set) var playbackErrorNeedsRelogin: Bool = false

    @Published var volume: Double = 0.8 {
        didSet {
            player?.volume = Float(volume)
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            updateNowPlaying()
        }
    }

    @Published var shuffleEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(shuffleEnabled, forKey: Self.shuffleKey)
        }
    }

    @Published var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: Self.repeatKey)
        }
    }

    enum RepeatMode: Int, CaseIterable {
        case off, all, one

        var label: String {
            switch self {
            case .off: return "循环：关闭"
            case .all: return "循环：全部"
            case .one: return "循环：单曲"
            }
        }
    }

    // MARK: - 私有状态

    private static let volumeKey = "Sona.Playback.Volume"
    private static let shuffleKey = "Sona.Playback.Shuffle"
    private static let repeatKey = "Sona.Playback.Repeat"

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyKeepUpObservation: NSKeyValueObservation?

    private var queue: [Track] = []
    private var queueIndex: Int = 0

    private let remoteCommand = MPRemoteCommandCenter.shared()

    // MARK: - 初始化

    private init() {
        // 恢复用户偏好
        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            volume = UserDefaults.standard.double(forKey: Self.volumeKey)
        }
        shuffleEnabled = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        if let raw = UserDefaults.standard.object(forKey: Self.repeatKey) as? Int,
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        setupRemoteCommands()
    }

    // MARK: - 队列控制

    /// 设置播放队列并从指定位置开始
    func setQueue(_ tracks: [Track], startAt index: Int = 0) {
        queue = tracks
        queueIndex = max(0, min(index, max(0, tracks.count - 1)))
        if !queue.isEmpty {
            play(track: queue[queueIndex])
        } else {
            stop()
        }
    }

    /// 将单曲加入下一播放位置
    func playNext(_ track: Track) {
        if queue.isEmpty {
            queue = [track]
            queueIndex = 0
            play(track: track)
        } else {
            queue.insert(track, at: queueIndex + 1)
        }
    }

    // MARK: - 播放控制

    func play(track: Track) {
        playbackError = nil
        playbackErrorNeedsRelogin = false

        // 云端曲目：播放时懒解析直链（直链有时效，夸克还需绑定当前登录态）
        if track.needsCloudResolution {
            currentTrack = track
            isBuffering = true
            Task { [weak self] in
                guard let self else { return }
                do {
                    let url: URL
                    switch track.source {
                    case .aliyun:
                        url = try await AliyunShareService.shared.resolvePlaybackURL(for: track)
                    default:
                        url = try await QuarkShareService.shared.resolvePlaybackURL(for: track)
                    }
                    // 用户可能已切歌
                    guard self.currentTrack?.id == track.id else { return }
                    self.startPlayback(track: track, url: url)
                } catch let err as QuarkError {
                    guard self.currentTrack?.id == track.id else { return }
                    self.isBuffering = false
                    self.playbackError = err.errorDescription
                    self.playbackErrorNeedsRelogin = err.isAuthError
                } catch let err as AliyunError {
                    guard self.currentTrack?.id == track.id else { return }
                    self.isBuffering = false
                    self.playbackError = err.errorDescription
                    self.playbackErrorNeedsRelogin = false
                } catch {
                    guard self.currentTrack?.id == track.id else { return }
                    self.isBuffering = false
                    self.playbackError = error.localizedDescription
                }
            }
            return
        }

        guard let url = track.url else {
            playbackError = "曲目没有可播放的源：\(track.title)"
            return
        }
        startPlayback(track: track, url: url)
    }

    /// 用已解析的 URL 创建 AVPlayer 并开始播放
    private func startPlayback(track: Track, url: URL) {
        cleanupPlayer()
        currentTrack = track
        isBuffering = true

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(volume)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                if item.status == .readyToPlay {
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.isBuffering = false
                    player.play()
                    self.isPlaying = true
                    self.updateNowPlaying()
                } else if item.status == .failed {
                    self.isBuffering = false
                    let reason = item.error?.localizedDescription ?? "未知错误"
                    print("AVPlayer item failed: \(reason)")
                    if self.currentTrack?.id == track.id {
                        switch track.source {
                        case .quark:
                            self.playbackError = "云端播放失败：\(reason)。若反复失败请尝试重新登录夸克账号"
                            self.playbackErrorNeedsRelogin = true
                        case .aliyun:
                            self.playbackError = "云端播放失败：\(reason)。若反复失败请重新导入该阿里云盘分享"
                            self.playbackErrorNeedsRelogin = false
                        case .local:
                            self.playbackError = "播放失败：\(reason)"
                            self.playbackErrorNeedsRelogin = false
                        }
                    }
                }
            }
        }

        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.isBuffering = item.isPlaybackBufferEmpty
            }
        }

        likelyKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                if item.isPlaybackLikelyToKeepUp {
                    self?.isBuffering = false
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    @objc private nonisolated func playerItemDidReachEnd(_ note: Notification) {
        Task { @MainActor in
            self.handleTrackEnd()
        }
    }

    private func handleTrackEnd() {
        switch repeatMode {
        case .one:
            if let track = currentTrack {
                play(track: track)
            }
        case .off, .all:
            if queueIndex + 1 < queue.count {
                next()
            } else if repeatMode == .all {
                queueIndex = 0
                if !queue.isEmpty {
                    play(track: queue[0])
                }
            } else {
                stop()
            }
        }
    }

    /// 关闭错误提示条
    func dismissError() {
        playbackError = nil
        playbackErrorNeedsRelogin = false
    }

    func togglePlayPause() {
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if shuffleEnabled && queue.count > 1 {
            var newIndex = queueIndex
            // 至少循环避免原地
            repeat {
                newIndex = Int.random(in: 0..<queue.count)
            } while newIndex == queueIndex
            queueIndex = newIndex
        } else {
            queueIndex = (queueIndex + 1) % queue.count
        }
        play(track: queue[queueIndex])
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if shuffleEnabled && queue.count > 1 {
            var newIndex = queueIndex
            repeat {
                newIndex = Int.random(in: 0..<queue.count)
            } while newIndex == queueIndex
            queueIndex = newIndex
        } else {
            queueIndex = (queueIndex - 1 + queue.count) % queue.count
        }
        play(track: queue[queueIndex])
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.updateNowPlaying()
            }
        }
        currentTime = seconds
    }

    func stop() {
        cleanupPlayer()
        currentTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func cleanupPlayer() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        likelyKeepUpObservation?.invalidate()
        likelyKeepUpObservation = nil
        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        player?.pause()
        player = nil
    }

    // MARK: - 系统控制中心

    private func setupRemoteCommands() {
        remoteCommand.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player != nil else { return }
                self.player?.play()
                self.isPlaying = true
                self.updateNowPlaying()
            }
            return .success
        }

        remoteCommand.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player != nil else { return }
                self.player?.pause()
                self.isPlaying = false
                self.updateNowPlaying()
            }
            return .success
        }

        remoteCommand.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.togglePlayPause()
            }
            return .success
        }

        remoteCommand.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.queue.isEmpty else { return }
                self.next()
            }
            return .success
        }

        remoteCommand.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.queue.isEmpty else { return }
                self.previous()
            }
            return .success
        }

        remoteCommand.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self.seek(to: event.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if let data = track.artworkData, let image = NSImage(data: data) {
            let targetSize = NSSize(width: 512, height: 512)
            let resized = resizedArtwork(image: image, to: targetSize) ?? image
            let artwork = MPMediaItemArtwork(boundsSize: resized.size) { _ in resized }
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func resizedArtwork(image: NSImage, to size: NSSize) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let resized = NSImage(size: size)
        resized.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size),
                 from: NSRect(origin: .zero, size: rep.size),
                 operation: .copy,
                 fraction: 1.0,
                 respectFlipped: false,
                 hints: nil)
        resized.unlockFocus()
        return resized
    }
}
