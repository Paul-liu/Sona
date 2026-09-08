//
//  Track.swift
//  Sona
//
//  单曲数据模型 · 本地与夸克云端共用
//

import Foundation

/// 音频来源
enum TrackSource: String, Codable, Hashable {
    case local   // 本地音乐
    case quark   // 夸克云端
    case aliyun  // 阿里云盘
}

/// 单曲数据模型
///
/// - `id`：本地使用 `file://` 路径，夸克使用 `quark-<pwdId>-<index>` 形式保证唯一。
/// - `url`：本地为文件 URL，夸克为本地代理 `http://127.0.0.1:<port>/?u=<b64>` 形式。
/// - `artworkData`：内嵌封面 PNG/JPEG 字节，可空。
struct Track: Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var source: TrackSource
    var url: URL?
    var artworkData: Data?
    var sizeBytes: Int64?

    // MARK: 夸克云端元数据（播放时懒解析直链，避免直链/登录态过期）
    /// 分享 ID（pwd_id）
    var quarkPwdId: String?
    /// 分享会话 Token
    var quarkStoken: String?
    /// 文件 ID
    var quarkFid: String?
    /// 分享文件下载 Token
    var quarkShareFidToken: String?

    // MARK: 阿里云盘元数据
    /// 分享 ID（share_id）
    var aliyunShareId: String?
    /// 文件 ID（file_id）
    var aliyunFileId: String?
    /// 分享提取码（可空；用于 share_token 过期后重新换取）
    var aliyunSharePwd: String?

    init(
        id: String,
        title: String,
        artist: String = "未知艺人",
        album: String = "未知专辑",
        duration: TimeInterval = 0,
        source: TrackSource,
        url: URL?,
        artworkData: Data? = nil,
        sizeBytes: Int64? = nil,
        quarkPwdId: String? = nil,
        quarkStoken: String? = nil,
        quarkFid: String? = nil,
        quarkShareFidToken: String? = nil,
        aliyunShareId: String? = nil,
        aliyunFileId: String? = nil,
        aliyunSharePwd: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.source = source
        self.url = url
        self.artworkData = artworkData
        self.sizeBytes = sizeBytes
        self.quarkPwdId = quarkPwdId
        self.quarkStoken = quarkStoken
        self.quarkFid = quarkFid
        self.quarkShareFidToken = quarkShareFidToken
        self.aliyunShareId = aliyunShareId
        self.aliyunFileId = aliyunFileId
        self.aliyunSharePwd = aliyunSharePwd
    }

    /// 是否为需要懒解析直链的云端曲目（每次播放时重新解析，直链与凭据均有时效）
    var needsCloudResolution: Bool {
        switch source {
        case .quark: return quarkFid != nil
        case .aliyun: return aliyunFileId != nil
        case .local: return false
        }
    }

    /// 兼容旧调用点
    var needsQuarkResolution: Bool {
        source == .quark && quarkFid != nil
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Track {
    /// 时长格式化 `mm:ss`
    var formattedDuration: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// 文件大小人性化
    var formattedSize: String {
        guard let bytes = sizeBytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
