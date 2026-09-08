//
//  AliyunShareService.swift
//  Sona
//
//  阿里云盘分享解析
//  1. 解析分享链接（支持 alipan / aliyundrive 域名、folder 子路径、提取码）
//  2. POST /v2/share_link/get_share_token 匿名换取 share_token
//  3. POST /adrive/v3/file/list 递归列举文件（header: x-share-token）
//  4. 过滤音频格式，生成独立歌单
//  5. 播放时懒解析下载直链（直链仅 10 分钟有效，不能提前批量拿）
//
//  ⚠️ 与夸克不同：阿里云盘分享是**匿名访问**，share_token 可无登录获取，
//     因此本服务不依赖任何登录态，也不需要扫码授权。
//

import Foundation
import SwiftUI

@MainActor
final class AliyunShareService: ObservableObject {
    static let shared = AliyunShareService()

    // MARK: - 公开状态

    /// 多次导入后生成的阿里云盘歌单列表
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isResolving: Bool = false
    /// 限流中等候下一次重试（用于 UI 提示用户）
    @Published private(set) var rateLimitedRetryAt: Date?
    @Published var lastError: String?

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4p", "m4b", "wav",
        "flac", "aac", "ogg", "oga", "opus",
        "amr", "wma", "aiff", "aif"
    ]

    // MARK: - Share Token 缓存

    /// shareId -> (token, 过期时间)；share_token 有效期 2 小时，播放时复用可减少请求
    private var tokenCache: [String: (token: String, expiresAt: Date)] = [:]

    // MARK: - 公开聚合

    var allTracks: [Track] {
        playlists.flatMap { $0.tracks }
    }

    var isEmpty: Bool {
        playlists.isEmpty
    }

    func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    func removePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
    }

    func clearAll() {
        playlists = []
        tokenCache.removeAll()
        lastError = nil
    }

    // MARK: - 日志

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let path = "/tmp/sona_aliyun_import.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 入口

    /// 解析阿里云盘分享文本并生成新歌单
    @discardableResult
    func resolveShare(_ input: String) async -> Playlist? {
        log("=== 开始导入，输入长度 \(input.count) ===")

        if isResolving {
            lastError = "已有导入任务在进行中，请稍候"
            log("拒绝：已有任务进行中")
            return nil
        }

        guard let parsed = Self.parseShare(input) else {
            lastError = AliyunError.invalidShareURL.errorDescription
            log("失败：parseShare 返回 nil，输入前 200 字符：\(input.prefix(200))")
            return nil
        }
        log("解析结果：shareId=\(parsed.shareId) pwd=\(parsed.pwd ?? "nil") folderId=\(parsed.folderId ?? "nil")")

        isResolving = true
        defer { isResolving = false }

        // 1) 换取 share_token
        let shareToken: String
        do {
            shareToken = try await fetchShareToken(shareId: parsed.shareId, pwd: parsed.pwd)
            log("share_token 获取成功")
        } catch let err as AliyunError {
            lastError = err.errorDescription
            log("失败（token）：\(err.errorDescription ?? "")")
            return nil
        } catch {
            lastError = error.localizedDescription
            log("失败（token 其他错误）：\(error.localizedDescription)")
            return nil
        }

        // 2) 获取分享标题（失败也不阻塞，用 share_id 兜底）
        let shareName = await fetchShareName(shareId: parsed.shareId, token: shareToken)
        log("分享标题：\(shareName ?? "无")")

        // 3) 递归列举文件
        let allFiles: [AliyunFile]
        do {
            allFiles = try await listFilesRecursively(
                shareId: parsed.shareId,
                token: shareToken,
                parentFileId: parsed.folderId ?? "root"
            )
        } catch let err as AliyunError {
            lastError = err.errorDescription
            log("失败（list）：\(err.errorDescription ?? "")")
            return nil
        } catch {
            lastError = error.localizedDescription
            log("失败（list 其他错误）：\(error.localizedDescription)")
            return nil
        }

        log("列举文件完成：共 \(allFiles.count) 个文件")
        let audioFiles = allFiles.filter {
            Self.audioExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }
        log("过滤音频后：\(audioFiles.count) 首")
        guard !audioFiles.isEmpty else {
            lastError = AliyunError.noAudioFiles.errorDescription
            return nil
        }

        let tracks = buildTracks(shareId: parsed.shareId, pwd: parsed.pwd, files: audioFiles)
        let baseTitle = (shareName?.isEmpty == false)
            ? shareName!
            : "阿里云盘分享-\(String(parsed.shareId.prefix(6)))"
        let uniqueTitle = makeUniquePlaylistName(baseTitle)

        let playlist = Playlist(
            id: "aliyun-\(parsed.shareId)-\(Int(Date().timeIntervalSince1970))",
            name: uniqueTitle,
            source: .aliyun,
            tracks: tracks
        )
        playlists.append(playlist)
        lastError = nil

        ToastService.shared.show(
            "已导入 \(tracks.count) 首到『\(playlist.name)』",
            icon: "icloud.and.arrow.down.fill",
            tint: Color(red: 0.0, green: 0.48, blue: 1.0)
        )
        log("导入成功：『\(playlist.name)』\(tracks.count) 首")
        return playlist
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

    // MARK: - 解析

    struct ParsedShare {
        let shareId: String
        let pwd: String?
        /// 分享链接中 /folder/<id> 指定的子目录，nil 表示从 root 开始
        let folderId: String?
    }

    /// 解析输入文本中的阿里云盘分享链接与提取码
    static func parseShare(_ input: String) -> ParsedShare? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fullRange = NSRange(location: 0, length: trimmed.utf16.count)

        // 1. 收集所有 http(s) URL，优先阿里云盘域名
        var candidates: [String] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: trimmed, options: [], range: fullRange)
            candidates = matches.compactMap { $0.url?.absoluteString }
        }
        if candidates.isEmpty {
            let pattern = "https?://[^\\s\\u{3000}\\u{FF01}-\\u{FF5E}\\u{2018}\\u{2019}\\u{201C}\\u{201D}\\u{3001}\\u{3002}\\u{FF0C}\\u{FF1B}\\u{FF1A}\\u{FF08}\\u{FF09}\\u{300A}\\u{300B}\\u{3010}\\u{3011}]+"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                regex.enumerateMatches(in: trimmed, options: [], range: fullRange) { match, _, _ in
                    if let match, let r = Range(match.range, in: trimmed) {
                        candidates.append(String(trimmed[r]))
                    }
                }
            }
        }
        if candidates.isEmpty, let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true {
            candidates.append(trimmed)
        }

        let urlString = candidates.first { $0.contains("alipan.com") }
            ?? candidates.first { $0.contains("aliyundrive.com") }
            ?? candidates.first

        guard let urlString, let url = URL(string: urlString) else { return nil }

        // 2. 从路径解析 share_id 与 folder_id
        //    形态：/s/<share_id> 或 /s/<share_id>/folder/<folder_id>
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var shareId: String?
        var folderId: String?

        if let sIndex = parts.firstIndex(where: { $0 == "s" }), sIndex + 1 < parts.count {
            shareId = parts[sIndex + 1]
            if let fIndex = parts.firstIndex(where: { $0 == "folder" }), fIndex + 1 < parts.count {
                folderId = parts[fIndex + 1]
            }
        } else if let qId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "share_id" })?.value {
            shareId = qId
        } else {
            shareId = parts.last
        }

        guard let finalShareId = shareId, !finalShareId.isEmpty else { return nil }

        // 3. 提取码（支持多种写法与全角符号）
        var pwd: String? = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pwd" || $0.name == "share_pwd" })?.value

        if pwd == nil {
            let codePatterns = [
                "提取码[:：]?\\s*([A-Za-z0-9]{4,8})",
                "提取密码[:：]?\\s*([A-Za-z0-9]{4,8})",
                "密码[:：]?\\s*([A-Za-z0-9]{4,8})",
                "访问码[:：]?\\s*([A-Za-z0-9]{4,8})",
                "code[:：]?\\s*([A-Za-z0-9]{4,8})",
                "pwd[:：]?\\s*([A-Za-z0-9]{4,8})"
            ]
            for pattern in codePatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: trimmed, range: fullRange),
                   let r = Range(match.range(at: 1), in: trimmed) {
                    pwd = String(trimmed[r])
                    break
                }
            }
        }

        return ParsedShare(shareId: finalShareId, pwd: pwd, folderId: folderId)
    }

    /// 判断一段文本是否疑似阿里云盘分享（供导入弹窗自动识别来源）
    static func matches(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.contains("alipan.com") || lower.contains("aliyundrive.com")
    }

    // MARK: - 网络层

    private static let apiBaseURL = "https://api.alipan.com"
    private static let webBaseURL = "https://www.alipan.com"

    /// 浏览器 UA（阿里云盘 Web 端）
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// X-Canary 头：声明为 Web 端 share app，用于提升接口限流额度
    private static let canaryHeader = "client=web,app=share,version=v2.3.1"

    private func makeRequest(url: URL, shareToken: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(Self.webBaseURL + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.canaryHeader, forHTTPHeaderField: "X-Canary")
        if let shareToken {
            request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        }
        return request
    }

    /// 统一解析阿里云盘错误响应（code 可能是字符串也可能是数字）
    private func extractError(_ json: [String: Any], fallback: String) -> (code: String, message: String) {
        let codeString: String?
        if let s = json["code"] as? String {
            codeString = s
        } else if let n = json["code"] as? Int {
            codeString = String(n)
        } else if let n = json["status"] as? Int {
            codeString = String(n)
        } else {
            codeString = nil
        }
        let message = (json["message"] as? String)
            ?? (json["error_message"] as? String)
            ?? fallback
        return (codeString ?? "", message)
    }

    /// 匿名换取 share_token（带缓存，有效期 2 小时）
    private func fetchShareToken(shareId: String, pwd: String?) async throws -> String {
        // 命中缓存且未过期则直接复用（留 5 分钟余量）
        if let cached = tokenCache[shareId], cached.expiresAt.timeIntervalSinceNow > 300 {
            log("复用缓存 share_token（剩余 \(Int(cached.expiresAt.timeIntervalSinceNow))s）")
            return cached.token
        }

        let url = URL(string: "\(Self.apiBaseURL)/v2/share_link/get_share_token")!
        var request = makeRequest(url: url, shareToken: nil)

        var body: [String: Any] = ["share_id": shareId]
        if let pwd, !pwd.isEmpty {
            body["share_pwd"] = pwd
        }
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log("get_share_token HTTP \(http.statusCode) 响应：\(snippet)")
            throw AliyunError.shareTokenFailed("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AliyunError.shareTokenFailed("响应非 JSON：\(snippet)")
        }

        if let token = json["share_token"] as? String, !token.isEmpty {
            let expiresIn = (json["expires_in"] as? Int) ?? 7200
            tokenCache[shareId] = (token, Date().addingTimeInterval(TimeInterval(expiresIn)))
            return token
        }

        let err = extractError(json, fallback: "未返回 share_token")
        log("get_share_token 失败 code=\(err.code) message=\(err.message)")

        // 实测错误码形如 "InvalidResource.SharePwd" / "ShareLink.Cancelled" / "NotFound.ShareLink"，
        // 带点号分隔，因此先归一化（去点）再做包含匹配，避免硬编码整串导致漏判。
        let normalized = err.code.replacingOccurrences(of: ".", with: "")
        if normalized.contains("SharePwd") {
            throw (pwd?.isEmpty != false)
                ? AliyunError.sharePwdRequired
                : AliyunError.sharePwdIncorrect
        }
        if normalized.contains("Cancelled")
            || normalized.contains("NotFound")
            || normalized.contains("Expired") {
            throw AliyunError.shareExpired
        }
        throw AliyunError.shareTokenFailed("[\(err.code)] \(err.message)")
    }

    /// 获取分享名称（匿名接口，失败返回 nil，由调用方兜底）
    private func fetchShareName(shareId: String, token: String) async -> String? {
        let url = URL(string: "\(Self.apiBaseURL)/adrive/v3/share_link/get_share_by_anonymous")!
        var request = makeRequest(url: url, shareToken: token)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["share_id": shareId])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["share_name", "share_title", "name", "display_name"] {
            if let value = json[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// 递归列举分享内全部文件，支持 marker 翻页
    private func listFilesRecursively(
        shareId: String,
        token: String,
        parentFileId: String
    ) async throws -> [AliyunFile] {
        var result: [AliyunFile] = []
        var queue: [String] = [parentFileId]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            var marker: String? = nil

            repeat {
                let page = try await listFilesPage(
                    shareId: shareId,
                    token: token,
                    parentFileId: current,
                    marker: marker
                )
                for file in page.items {
                    if file.isFolder {
                        queue.append(file.file_id)
                    } else {
                        result.append(file)
                    }
                }
                marker = page.nextMarker
            } while marker?.isEmpty == false
        }
        return result
    }

    private func listFilesPage(
        shareId: String,
        token: String,
        parentFileId: String,
        marker: String?
    ) async throws -> (items: [AliyunFile], nextMarker: String?) {
        // 阿里云盘对单 IP 短时间请求数有限流（HTTP 429 + BlockException: TooManyRequests）。
        // 遇到 429 时按 5s / 10s / 15s 退避自动重试，最多 3 次；期间通过 rateLimitedRetryAt
        // 暴露下一次重试时刻，让 UI 能提示用户「限流中…」。
        let delays: [TimeInterval] = [5, 10, 15]
        var lastError: Error?

        for attempt in 1...3 {
            do {
                let result = try await performListFilesPage(
                    shareId: shareId,
                    token: token,
                    parentFileId: parentFileId,
                    marker: marker
                )
                rateLimitedRetryAt = nil
                return result
            } catch let err as AliyunError {
                if case .listFailed(let msg) = err,
                   (msg ?? "").contains("HTTP 429"),
                   attempt <= delays.count {
                    let delay = delays[attempt - 1]
                    let nextAt = Date().addingTimeInterval(delay)
                    rateLimitedRetryAt = nextAt
                    log("list 限流中（attempt \(attempt)/3），\(Int(delay))s 后重试")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    rateLimitedRetryAt = nil
                    lastError = err
                    continue
                }
                rateLimitedRetryAt = nil
                throw err
            } catch {
                rateLimitedRetryAt = nil
                throw error
            }
        }
        rateLimitedRetryAt = nil
        throw lastError ?? AliyunError.listFailed("限流重试耗尽，请稍后再试")
    }

    /// 单次 file/list 请求（不带重试）
    private func performListFilesPage(
        shareId: String,
        token: String,
        parentFileId: String,
        marker: String?
    ) async throws -> (items: [AliyunFile], nextMarker: String?) {
        let url = URL(string: "\(Self.apiBaseURL)/adrive/v3/file/list")!
        var request = makeRequest(url: url, shareToken: token)
        request.httpMethod = "POST"

        var body: [String: Any] = [
            "share_id": shareId,
            "parent_file_id": parentFileId,
            "limit": 200,
            "order_by": "name",
            "order_direction": "ASC",
            "marker": marker ?? ""
        ]
        body["image_thumbnail_process"] = "image/resize,w_160/format,jpeg"
        body["video_thumbnail_process"] = "video/snapshot,t_1000,f_jpg,ar_auto,w_300"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log("file/list HTTP \(http.statusCode) 响应：\(snippet)")
            throw AliyunError.listFailed("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AliyunError.listFailed("响应非 JSON")
        }

        guard let items = json["items"] as? [[String: Any]] else {
            let err = extractError(json, fallback: "未返回文件列表")
            log("file/list 失败 code=\(err.code) message=\(err.message)")
            let normalized = err.code.replacingOccurrences(of: ".", with: "")
            if normalized.contains("ShareLinkTokenInvalid") {
                tokenCache.removeValue(forKey: shareId)
                throw AliyunError.listFailed("share_token 已失效，请重试或重新导入")
            }
            throw AliyunError.listFailed("[\(err.code)] \(err.message)")
        }

        let files: [AliyunFile] = items.compactMap { dict in
            guard let fileId = dict["file_id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            return AliyunFile(
                drive_id: dict["drive_id"] as? String,
                file_id: fileId,
                name: name,
                type: dict["type"] as? String,
                size: (dict["size"] as? NSNumber)?.int64Value,
                parent_file_id: dict["parent_file_id"] as? String,
                created_at: dict["created_at"] as? String,
                updated_at: dict["updated_at"] as? String,
                thumbnail: dict["thumbnail"] as? String
            )
        }
        let nextMarker = json["next_marker"] as? String
        return (files, (nextMarker?.isEmpty == false) ? nextMarker : nil)
    }

    // MARK: - 播放直链（懒解析）

    /// 播放时解析下载直链，返回经本地代理包装的可播放 URL
    func resolvePlaybackURL(for track: Track) async throws -> URL {
        guard let shareId = track.aliyunShareId, let fileId = track.aliyunFileId else {
            throw AliyunError.downloadFailed("曲目缺少分享元数据，请重新导入歌单")
        }

        // share_token 可能已过期，这里统一走缓存/重新获取
        let token = try await fetchShareToken(shareId: shareId, pwd: track.aliyunSharePwd)

        let url = URL(string: "\(Self.apiBaseURL)/v2/file/get_share_link_download_url")!
        var request = makeRequest(url: url, shareToken: token)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "share_id": shareId,
            "file_id": fileId,
            "expire_sec": 600
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log("get_share_link_download_url HTTP \(http.statusCode) 响应：\(snippet)")
            throw AliyunError.downloadFailed("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AliyunError.downloadFailed("响应非 JSON")
        }

        let urlString = (json["download_url"] as? String) ?? (json["url"] as? String)
        guard let urlString, !urlString.isEmpty else {
            let err = extractError(json, fallback: "未返回下载直链")
            throw AliyunError.downloadFailed("[\(err.code)] \(err.message)")
        }

        guard let upstreamURL = URL(string: urlString) else {
            throw AliyunError.downloadFailed("直链格式非法")
        }
        // 阿里云盘直链必须带 alipan 的 Referer 才能下载，代理需按来源区分
        guard let playbackURL = LocalStreamProxy.shared.makeProxyURL(
            for: upstreamURL,
            referer: Self.webBaseURL + "/"
        ) else {
            return upstreamURL
        }
        return playbackURL
    }

    // MARK: - 构造 Track

    private func buildTracks(
        shareId: String,
        pwd: String?,
        files: [AliyunFile]
    ) -> [Track] {
        files.enumerated().map { idx, file in
            let title = (file.name as NSString).deletingPathExtension
            let components = title.components(separatedBy: "-")
            let artist = components.count > 1
                ? components.last?.trimmingCharacters(in: .whitespaces)
                : "阿里云盘"

            return Track(
                id: "aliyun-\(shareId)-\(idx)-\(file.file_id)",
                title: title,
                artist: artist ?? "阿里云盘",
                album: "阿里云盘分享",
                duration: 0,
                source: .aliyun,
                url: nil,
                artworkData: nil,
                sizeBytes: file.size,
                aliyunShareId: shareId,
                aliyunFileId: file.file_id,
                aliyunSharePwd: pwd
            )
        }
    }
}
