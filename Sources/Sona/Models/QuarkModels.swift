//
//  QuarkModels.swift
//  Sona
//
//  夸克网盘 API 数据模型
//

import Foundation

// MARK: - 文件元数据

/// 夸克网盘文件/文件夹
struct QuarkFile: Codable, Hashable {
    /// 文件 ID
    let fid: String
    /// 文件名
    let file_name: String
    /// 文件类型 0 = 文件夹 / 1 = 文件
    let file_type: Int
    /// 文件大小（字节）
    let size: Int64?
    /// 是否为文件夹
    let dir: Bool?
    /// 创建时间（毫秒）
    let created_at: Int64?
    /// 修改时间（毫秒）
    let updated_at: Int64?
    /// 缩略图 URL
    let thumbnail: String?
    /// 分享文件下载 token
    let share_fid_token: String?
}

// MARK: - 分享信息 / Stoken

struct QuarkStokenRequest: Codable {
    let pwd_id: String
    let passcode: String
}

struct QuarkStokenResponse: Codable {
    let code: Int
    let status: Int?
    let message: String?
    let data: QuarkStokenData?
}

struct QuarkStokenData: Codable {
    let stoken: String?
    let title: String?
    let expired_at: Int64?
}

// MARK: - 文件列表

struct QuarkListRequest: Codable {
    let pwd_id: String
    let stoken: String
    let pdir_fid: String
    let force: Int
    let _fetch: Int
}

struct QuarkListResponse: Codable {
    let code: Int
    let status: Int?
    let message: String?
    let data: QuarkListData?
}

struct QuarkListData: Codable {
    let list: [QuarkFile]?
    let total: Int?
}

// MARK: - 下载直链

struct QuarkDownloadRequest: Codable {
    let pwd_id: String
    let stoken: String
    let fids: [String]
    let fids_token: [String]
}

struct QuarkDownloadResponse: Codable {
    let code: Int
    let status: Int?
    let message: String?
    let data: [QuarkDownloadInfo]?
}

struct QuarkDownloadInfo: Codable {
    let fid: String?
    let file_name: String?
    let size: Int64?
    let download_url: String?
    let backup_download_url: String?
    let expire_time: Int64?
}

// MARK: - 错误类型

enum QuarkError: LocalizedError {
    case invalidShareURL
    case unauthorized
    case sessionExpired
    case stokenFailed(String?)
    case listFailed(String?)
    case downloadFailed(String?)
    case apiFailed(code: Int, message: String)
    case noAudioFiles

    var errorDescription: String? {
        switch self {
        case .invalidShareURL:
            return "无法识别分享链接或缺少 pwd_id"
        case .unauthorized:
            return "夸克账号未登录，请先完成授权"
        case .sessionExpired:
            return "夸克登录已过期，云端直链被拒绝（412）。请在侧边栏「夸克网盘」中退出登录后重新扫码授权"
        case .stokenFailed(let msg):
            return "获取分享 Token 失败：\(msg ?? "未知错误")"
        case .listFailed(let msg):
            return "列举分享文件失败：\(msg ?? "未知错误")"
        case .downloadFailed(let msg):
            return "获取音频直链失败：\(msg ?? "未知错误")"
        case .apiFailed(let code, let message):
            return "接口返回错误 [\(code)]：\(message)"
        case .noAudioFiles:
            return "分享中没有找到任何音频文件"
        }
    }

    /// 是否为登录态问题（UI 据此提示重新登录）
    var isAuthError: Bool {
        switch self {
        case .unauthorized, .sessionExpired: return true
        default: return false
        }
    }
}
