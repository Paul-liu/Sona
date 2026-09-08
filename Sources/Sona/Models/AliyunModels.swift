//
//  AliyunModels.swift
//  Sona
//
//  阿里云盘分享 API 数据模型
//
//  接口（均为匿名可访问，无需登录）：
//   1. POST /v2/share_link/get_share_token          → share_token
//   2. POST /adrive/v3/file/list                    → 分享内文件（header: x-share-token）
//   3. POST /v2/file/get_share_link_download_url    → 下载直链
//

import Foundation

// MARK: - 文件元数据

/// 阿里云盘分享内文件/文件夹
struct AliyunFile: Codable, Hashable {
    /// 所属空间 ID
    let drive_id: String?
    /// 文件 ID
    let file_id: String
    /// 文件名
    let name: String
    /// "file" / "folder"
    let type: String?
    /// 文件大小（字节）
    let size: Int64?
    /// 父目录 ID
    let parent_file_id: String?
    /// 创建时间
    let created_at: String?
    /// 修改时间
    let updated_at: String?
    /// 缩略图
    let thumbnail: String?

    var isFolder: Bool {
        type == "folder"
    }
}

// MARK: - Share Token

struct AliyunShareTokenRequest: Codable {
    let share_id: String
    let share_pwd: String?
}

struct AliyunShareTokenResponse: Codable {
    let share_token: String?
    let expire_time: String?
    let expires_in: Int?
    /// 错误码（阿里云盘返回字符串 code，如 "InvalidResource.SharePwd"）
    let code: String?
    let message: String?
    /// 部分接口返回数字 code
    let status: Int?
}

// MARK: - 文件列表

struct AliyunFileListResponse: Codable {
    let items: [AliyunFile]?
    let next_marker: String?
    let code: String?
    let message: String?
    /// 部分接口返回数字 code
    let status: Int?
}

// MARK: - 下载直链

struct AliyunDownloadResponse: Codable {
    let download_url: String?
    let url: String?
    let expiration: String?
    let size: Int64?
    let code: String?
    let message: String?
    let status: Int?
}

// MARK: - 错误类型

enum AliyunError: LocalizedError {
    case invalidShareURL
    case sharePwdRequired
    case sharePwdIncorrect
    case shareTokenFailed(String?)
    case listFailed(String?)
    case downloadFailed(String?)
    case noAudioFiles
    case shareExpired

    var errorDescription: String? {
        switch self {
        case .invalidShareURL:
            return "无法识别阿里云盘分享链接（缺少 share_id）"
        case .sharePwdRequired:
            return "该分享需要提取码，请在文本中一并粘贴（如「提取码：xxxx」）"
        case .sharePwdIncorrect:
            return "提取码不正确，请核对后重试"
        case .shareTokenFailed(let msg):
            return "获取分享 Token 失败：\(msg ?? "未知错误")"
        case .listFailed(let msg):
            return "列举分享文件失败：\(msg ?? "未知错误")"
        case .downloadFailed(let msg):
            return "获取音频直链失败：\(msg ?? "未知错误")"
        case .noAudioFiles:
            return "分享中没有找到任何音频文件"
        case .shareExpired:
            return "分享已失效或已被分享者取消"
        }
    }
}
