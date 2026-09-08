//
//  QuarkShareService.swift
//  Sona
//
//  夸克分享解析
//  1. 正则提取分享 URL 与文本中的提取码
//  2. POST /clouddrive/share/sharepage/token 获取 stoken
//  3. GET  /clouddrive/share/sharepage/detail 列举文件（递归子目录）
//  4. 过滤音频格式
//  5. POST /clouddrive/file/download 获取直链
//  6. 构造 Track（URL 走 LocalStreamProxy）
//
//  支持多次导入：每次解析生成独立歌单，以分享标题命名
//

import Foundation
import SwiftUI

@MainActor
final class QuarkShareService: ObservableObject {
    static let shared = QuarkShareService()

    // MARK: - 公开状态

    /// 多次导入后生成的夸克歌单列表
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isResolving: Bool = false
    @Published var lastError: String?

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4p", "m4b", "wav",
        "flac", "aac", "ogg", "oga", "opus",
        "amr", "wma", "aiff", "aif"
    ]

    // MARK: - 公开聚合

    /// 全部夸克曲目（所有歌单聚合，供资料库/搜索使用）
    var allTracks: [Track] {
        playlists.flatMap { $0.tracks }
    }

    /// 当前是否没有任何夸克歌单
    var isEmpty: Bool {
        playlists.isEmpty
    }

    /// 根据 ID 查找歌单
    func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// 移除指定歌单
    func removePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
    }

    func clearAll() {
        playlists = []
        lastError = nil
    }

    // MARK: - 入口

    /// 诊断日志：写入 /tmp/sona_quark_import.log 方便定位导入失败
    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let path = "/tmp/sona_quark_import.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 解析分享文本（URL 或带提取码的文本），并将音频列表追加为新歌单
    /// - Returns: 成功时返回新建歌单
    @discardableResult
    func resolveShare(_ input: String) async -> Playlist? {
        log("=== 开始导入，输入长度 \(input.count) ===")
        // 并发锁：避免用户在 UI 已禁用按钮的情况下仍触发并发请求（如快捷键连按）
        if isResolving {
            lastError = "已有导入任务在进行中，请稍候"
            log("拒绝：已有任务进行中")
            return nil
        }
        guard QuarkAuthService.shared.isLoggedIn else {
            lastError = "请先完成夸克账号登录"
            log("失败：未登录")
            return nil
        }
        guard let parsed = Self.parseShare(input) else {
            lastError = "无法识别分享链接或缺少 pwd_id"
            log("失败：parseShare 返回 nil，输入前 200 字符：\(input.prefix(200))")
            return nil
        }
        log("解析结果：pwdId=\(parsed.pwdId ?? "nil") pwd=\(parsed.pwd ?? "nil") shortCode=\(parsed.shortCode ?? "nil")")

        var pwdId = parsed.pwdId
        if pwdId == nil, let shortCode = parsed.shortCode {
            log("无标准链接，尝试解析短链 /~\(shortCode)~/")
            pwdId = await resolveShortCode(shortCode)
            log("短链解析结果：pwdId=\(pwdId ?? "nil")")
        }
        guard let finalPwdId = pwdId, !finalPwdId.isEmpty else {
            lastError = "无法识别分享链接或缺少 pwd_id"
            log("失败：pwdId 为空")
            return nil
        }

        isResolving = true
        defer { isResolving = false }

        // 1) 获取 stoken
        let stoken: String
        let shareTitle: String?
        do {
            let result = try await fetchStoken(pwdId: finalPwdId, pwd: parsed.pwd)
            stoken = result.stoken
            shareTitle = result.title
            log("stoken 获取成功，分享标题：\(shareTitle ?? "无")")
        } catch let err as QuarkError {
            lastError = err.errorDescription
            log("失败（stoken）：\(err.errorDescription ?? "")")
            return nil
        } catch {
            lastError = error.localizedDescription
            log("失败（stoken 其他错误）：\(error.localizedDescription)")
            return nil
        }

        // 2) 列举文件；若 14001（stoken 在 list 之前被作废）则重新拉一次 stoken 后重试
        let allFiles: [QuarkFile]
        do {
            allFiles = try await listFilesRecursively(
                pwdId: finalPwdId,
                stoken: stoken,
                pdirFid: "0"
            )
        } catch let err as QuarkError {
            if case .apiFailed(code: 14001, _) = err {
                log("list 报 14001「非法 token」，重新拉取 stoken 后重试")
                do {
                    let retry = try await fetchStoken(pwdId: finalPwdId, pwd: parsed.pwd)
                    let files = try await listFilesRecursively(
                        pwdId: finalPwdId,
                        stoken: retry.stoken,
                        pdirFid: "0"
                    )
                    allFiles = files
                    log("stoken 重拉后 list 成功：\(files.count) 个文件")
                } catch {
                    lastError = (error as? QuarkError)?.errorDescription ?? error.localizedDescription
                    log("stoken 重拉后仍失败：\(lastError ?? "")")
                    return nil
                }
            } else {
                lastError = err.errorDescription
                log("失败（list）：\(err.errorDescription ?? "")")
                return nil
            }
        } catch {
            lastError = error.localizedDescription
            log("失败（list 其他错误）：\(error.localizedDescription)")
            return nil
        }

        log("列举文件完成：共 \(allFiles.count) 个文件")
        let audioFiles = allFiles.filter {
            Self.audioExtensions.contains(
                ($0.file_name as NSString).pathExtension.lowercased()
            )
        }
        log("过滤音频后：\(audioFiles.count) 首")
        guard !audioFiles.isEmpty else {
            lastError = QuarkError.noAudioFiles.errorDescription
            return nil
        }

        // 直链有效期仅数小时且与登录态绑定，改为播放时懒解析；
        // 导入阶段只保留文件元数据（更快，也避免批量请求触发风控）
        let tracks = buildTracks(
            pwdId: finalPwdId,
            stoken: stoken,
            files: audioFiles
        )

        let baseTitle = shareTitle?.isEmpty == false
            ? shareTitle!
            : "夸克分享-\(String(finalPwdId.prefix(6)))"
        let uniqueTitle = makeUniquePlaylistName(baseTitle)

        // 同一分享多次导入也生成不同 ID，确保可形成多个歌单
        let playlist = Playlist(
            id: "quark-\(finalPwdId)-\(Int(Date().timeIntervalSince1970))",
            name: uniqueTitle,
            source: .quark,
            tracks: tracks
        )
        playlists.append(playlist)
        lastError = nil

        ToastService.shared.show(
            "已导入 \(tracks.count) 首到『\(playlist.name)』",
            icon: "icloud.and.arrow.down.fill",
            tint: Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
        )
        log("导入成功：『\(playlist.name)』\(tracks.count) 首")
        return playlist
    }

    /// 解析夸克短链（/~xxxx~/ 形式）为 pwd_id
    /// 通过访问 https://pan.quark.cn/t/<code> 跟随重定向获取最终分享链接
    private func resolveShortCode(_ code: String) async -> String? {
        guard let url = URL(string: "https://pan.quark.cn/t/\(code)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(QuarkAuthService.clientUserAgent, forHTTPHeaderField: "User-Agent")

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let finalURL = http.url else { return nil }
        log("短链最终 URL：\(finalURL.absoluteString)（HTTP \(http.statusCode)）")

        let comps = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)
        if let queryPwdId = comps?.queryItems?.first(where: { $0.name == "pwd_id" })?.value {
            return queryPwdId
        }
        let parts = finalURL.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.count >= 2 && parts[0] == "s" {
            return parts.last
        }
        return nil
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

    /// 播放时解析单曲直链（懒解析），返回经本地代理包装的可播放 URL
    func resolvePlaybackURL(for track: Track) async throws -> URL {
        guard let cookie = QuarkAuthService.shared.cookie else {
            throw QuarkError.unauthorized
        }
        guard let pwdId = track.quarkPwdId,
              let stoken = track.quarkStoken,
              let fid = track.quarkFid else {
            throw QuarkError.downloadFailed("曲目缺少分享元数据，请重新导入歌单")
        }

        let infos = try await fetchDownloadURLs(
            pwdId: pwdId,
            stoken: stoken,
            files: [QuarkFile(
                fid: fid,
                file_name: track.title,
                file_type: 1,
                size: track.sizeBytes,
                dir: false,
                created_at: nil,
                updated_at: nil,
                thumbnail: nil,
                share_fid_token: track.quarkShareFidToken
            )]
        )
        guard let info = infos.first else {
            throw QuarkError.downloadFailed("下载接口未返回该文件")
        }
        let urlString = info.download_url ?? info.backup_download_url
        guard let urlString, !urlString.isEmpty else {
            throw QuarkError.downloadFailed("下载接口未返回直链")
        }

        // 游客直链（登录态失效时服务端降级下发）会被 CDN 一律 412 拒绝，
        // 必须提示用户重新登录，避免播放器无提示失败
        if urlString.contains("-guest-") {
            QuarkAuthService.shared.markSessionExpired()
            throw QuarkError.sessionExpired
        }

        guard let upstreamURL = URL(string: urlString) else {
            throw QuarkError.downloadFailed("直链格式非法")
        }
        // 显式传夸克 Referer，与阿里云盘区分（直链签名与 Referer 绑定）
        guard let playbackURL = LocalStreamProxy.shared.makeProxyURL(
            for: upstreamURL,
            referer: Self.shareBaseURL + "/"
        ) else {
            return upstreamURL
        }
        _ = cookie
        return playbackURL
    }

    // MARK: - 解析

    struct ParsedShare {
        let pwdId: String?
        let pwd: String?
        let title: String?
        /// 夸克 APP 短链码（/~xxxx~/ 形式中的 xxxx），无标准 URL 时用于兜底解析
        let shortCode: String?
    }

    /// 解析输入文本中的链接与提取码
    /// 支持：纯 URL、夸克 APP 复制的整段文本、带/不带提取码、URL 含 query 参数、短链码兜底
    static func parseShare(_ input: String) -> ParsedShare? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fullRange = NSRange(location: 0, length: trimmed.utf16.count)

        // 1. 提取所有 http(s) URL，优先夸克域名的链接
        var urlString: String?
        var candidates: [String] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: trimmed, options: [], range: fullRange)
            candidates = matches.compactMap { $0.url?.absoluteString }
        }
        // 兜底：正则从文本里抓 URL（处理 NSDataDetector 漏掉的边角情况）
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
        // 再兜底：输入本身可能就是 URL
        if candidates.isEmpty, let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true {
            candidates.append(trimmed)
        }

        // 优先 pan.quark.cn，其次任意 quark 域，最后任意 URL
        urlString = candidates.first { $0.contains("pan.quark.cn") }
            ?? candidates.first { $0.lowercased().contains("quark") }
            ?? candidates.first

        // 2. 提取短链码：/~xxxx~/（无标准 URL 时兜底）
        var shortCode: String?
        if let regex = try? NSRegularExpression(pattern: "/~([A-Za-z0-9]+)~/"),
           let match = regex.firstMatch(in: trimmed, range: fullRange),
           let r = Range(match.range(at: 1), in: trimmed) {
            shortCode = String(trimmed[r])
        }

        // 3. 解析 pwd_id 与 pwd
        var pwdId: String?
        var pwd: String?
        if let urlString, let url = URL(string: urlString) {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            pwdId = comps?.queryItems?.first(where: { $0.name == "pwd_id" })?.value
            pwd = comps?.queryItems?.first(where: { $0.name == "pwd" })?.value

            // 路径中可能直接含 pwd_id：`/s/xxxxxx`
            if pwdId == nil || pwdId?.isEmpty == true {
                let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
                pwdId = parts.last
            }
        }

        // 4. 提取码可能出现在文本里，支持多种写法与全角符号
        if pwd == nil {
            let codePatterns = [
                "提取码[:：]?\\s*([A-Za-z0-9]{2,8})",
                "密码[:：]?\\s*([A-Za-z0-9]{2,8})",
                "提取密码[:：]?\\s*([A-Za-z0-9]{2,8})",
                "访问码[:：]?\\s*([A-Za-z0-9]{2,8})",
                "code[:：]?\\s*([A-Za-z0-9]{2,8})",
                "passcode[:：]?\\s*([A-Za-z0-9]{2,8})"
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

        guard pwdId != nil || shortCode != nil else { return nil }
        return ParsedShare(pwdId: pwdId, pwd: pwd, title: nil, shortCode: shortCode)
    }

    // MARK: - 网络层

    private static let baseURL = "https://drive-pc.quark.cn"
    private static let apiBaseURL = "https://pc-api.uc.cn"
    private static let shareBaseURL = "https://pan.quark.cn"

    /// 通用请求头（不含 Referer，Referer 必须由各接口按 pwd_id 显式设置，
    /// 否则夸克会判定 Referer 与 stoken 不一致并返回 14001 "非法 token"）
    private var commonHeaders: [String: String] {
        [
            "User-Agent": QuarkAuthService.clientUserAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
    }

    /// 生成具体分享页的 Referer（用于 stoken / detail / download 接口）
    private func shareReferer(pwdId: String) -> String {
        "\(Self.shareBaseURL)/s/\(pwdId)"
    }

    private func makeRequest(url: URL, cookie: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        for (key, value) in commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    /// 错误响应诊断：返回 code / message 及原始文本片段
    private func diagnose(_ data: Data, fallback: String) -> QuarkError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code = json["code"] as? Int ?? json["status"] as? Int ?? -1
            let msg = (json["message"] as? String) ?? fallback
            return .apiFailed(code: code, message: msg)
        }
        let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
        return .apiFailed(code: -1, message: "\(fallback)（原始响应：\(snippet)）")
    }

    /// 获取 stoken（带重试：夸克偶发 412 风控，等 1.5 秒后自动重试一次）
    private func fetchStoken(pwdId: String, pwd: String?) async throws -> (stoken: String, title: String?) {
        var lastError: Error?
        for attempt in 0..<2 {
            if attempt > 0 {
                log("stoken 第 \(attempt) 次尝试失败（\(lastError.map(String.init(describing:)) ?? "")），1.5 秒后重试")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            do {
                return try await performStokenRequest(pwdId: pwdId, pwd: pwd)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? QuarkError.stokenFailed("未知错误")
    }

    private func performStokenRequest(pwdId: String, pwd: String?) async throws -> (stoken: String, title: String?) {
        guard let cookie = QuarkAuthService.shared.cookie else {
            throw QuarkError.unauthorized
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var components = URLComponents(string: "\(Self.baseURL)/1/clouddrive/share/sharepage/token")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "__dt", value: "\(Int.random(in: 100...999))"),
            URLQueryItem(name: "__t", value: "\(timestamp)")
        ]
        guard let url = components.url else {
            throw QuarkError.stokenFailed("无法构造 token URL")
        }

        var request = makeRequest(url: url, cookie: cookie)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Referer 必须指向具体分享页，否则夸克会判定 token 与页面不匹配并返回 14001
        request.setValue(shareReferer(pwdId: pwdId), forHTTPHeaderField: "Referer")

        let body: [String: Any] = [
            "pwd_id": pwdId,
            "passcode": pwd ?? "",
            "support_visit_limit_private_share": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // 检查 HTTP 状态码（412 = 夸克风控，body 非 JSON，旧代码直接解码会报乱码错误）
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let hint = http.statusCode == 412 ? "（触发夸克风控，稍后重试）" : ""
            throw QuarkError.stokenFailed("HTTP \(http.statusCode)\(hint)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw QuarkError.stokenFailed("响应非 JSON：\(snippet)")
        }
        let code = json["code"] as? Int ?? json["status"] as? Int ?? -1
        guard code == 0 else {
            let msg = (json["message"] as? String) ?? "stoken 为空"
            throw QuarkError.apiFailed(code: code, message: msg)
        }
        guard let dataDict = json["data"] as? [String: Any],
              let stoken = dataDict["stoken"] as? String, !stoken.isEmpty else {
            throw QuarkError.stokenFailed("stoken 为空")
        }
        let title = dataDict["title"] as? String
        return (stoken, title)
    }

    /// 递归获取分享内全部文件（扁平化返回），支持目录遍历与单目录翻页
    private func listFilesRecursively(
        pwdId: String,
        stoken: String,
        pdirFid: String
    ) async throws -> [QuarkFile] {
        var result: [QuarkFile] = []
        var queue: [String] = [pdirFid]
        let pageSize = 50

        while !queue.isEmpty {
            let currentFid = queue.removeFirst()
            var page = 1
            while true {
                let pageFiles = try await listFilesPage(
                    pwdId: pwdId,
                    stoken: stoken,
                    pdirFid: currentFid,
                    page: page
                )
                for file in pageFiles {
                    if file.dir == true || file.file_type == 0 {
                        queue.append(file.fid)
                    } else {
                        result.append(file)
                    }
                }
                // 不足一页说明该目录已翻完
                if pageFiles.count < pageSize { break }
                page += 1
            }
        }
        return result
    }

    private func listFilesPage(
        pwdId: String,
        stoken: String,
        pdirFid: String,
        page: Int
    ) async throws -> [QuarkFile] {
        guard let cookie = QuarkAuthService.shared.cookie else {
            throw QuarkError.unauthorized
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var components = URLComponents(string: "\(Self.baseURL)/1/clouddrive/share/sharepage/detail")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "pwd_id", value: pwdId),
            URLQueryItem(name: "stoken", value: stoken),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "_page", value: "\(page)"),
            URLQueryItem(name: "_size", value: "50"),
            URLQueryItem(name: "_fetch_banner", value: "0"),
            URLQueryItem(name: "_fetch_share", value: "0"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_sort", value: "file_type:asc,updated_at:desc"),
            URLQueryItem(name: "__dt", value: "\(Int.random(in: 100...999))"),
            URLQueryItem(name: "__t", value: "\(timestamp)")
        ]
        guard let url = components.url else {
            throw QuarkError.listFailed("无法构造 detail URL")
        }

        var request = makeRequest(url: url, cookie: cookie)
        request.httpMethod = "GET"
        // 关键：Referer 必须指向具体分享页，否则夸克会判定 token 与页面不一致返回 14001
        request.setValue(shareReferer(pwdId: pwdId), forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log("listFilesPage HTTP \(http.statusCode) pdirFid=\(pdirFid) page=\(page) 响应：\(snippet)")
            throw diagnose(data, fallback: "HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(QuarkListResponse.self, from: data)
        guard decoded.code == 0 else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log("listFilesPage code=\(decoded.code) pdirFid=\(pdirFid) page=\(page) message=\(decoded.message ?? "") 响应：\(snippet)")
            throw diagnose(data, fallback: decoded.message ?? "detail 接口返回错误")
        }
        return decoded.data?.list ?? []
    }

    private func fetchDownloadURLs(
        pwdId: String,
        stoken: String,
        files: [QuarkFile]
    ) async throws -> [QuarkDownloadInfo] {
        guard let cookie = QuarkAuthService.shared.cookie else {
            throw QuarkError.unauthorized
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var components = URLComponents(string: "\(Self.apiBaseURL)/1/clouddrive/file/download")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "__dt", value: "\(Int.random(in: 240...260) * 60_000)"),
            URLQueryItem(name: "__t", value: "\(timestamp)")
        ]
        guard let url = components.url else {
            throw QuarkError.downloadFailed("无法构造 download URL")
        }

        var request = makeRequest(url: url, cookie: cookie)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 同样使用具体分享页 Referer，避免下载接口被反爬
        request.setValue(shareReferer(pwdId: pwdId), forHTTPHeaderField: "Referer")

        let fids = files.map { $0.fid }
        let fidsToken = files.map { $0.share_fid_token ?? "" }
        let body: [String: Any] = [
            "pwd_id": pwdId,
            "stoken": stoken,
            "fids": fids,
            "fids_token": fidsToken
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            // 捕获响应中轮换下发的会话 cookie（__puus 等），保持后续请求与直链签名一致
            QuarkAuthService.shared.mergeSessionCookies(from: http)
            if http.statusCode != 200 {
                throw diagnose(data, fallback: "HTTP \(http.statusCode)")
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuarkError.downloadFailed("下载接口返回非 JSON")
        }
        let code = json["code"] as? Int ?? json["status"] as? Int ?? -1
        let msg = json["message"] as? String
        guard code == 0 else {
            // 31001 = require login：登录会话已失效
            if code == 31001 {
                QuarkAuthService.shared.markSessionExpired()
                throw QuarkError.sessionExpired
            }
            throw QuarkError.downloadFailed(msg ?? "下载接口 code=\(code)")
        }

        let rawList: [[String: Any]]
        if let list = json["data"] as? [[String: Any]] {
            rawList = list
        } else if let dict = json["data"] as? [String: Any], let list = dict["list"] as? [[String: Any]] {
            rawList = list
        } else {
            throw QuarkError.downloadFailed("下载接口未返回文件列表")
        }

        return rawList.map { dict in
            QuarkDownloadInfo(
                fid: dict["fid"] as? String,
                file_name: dict["file_name"] as? String,
                size: (dict["size"] as? NSNumber)?.int64Value
                    ?? (dict["size"] as? Int).map(Int64.init),
                download_url: dict["download_url"] as? String,
                backup_download_url: dict["backup_download_url"] as? String,
                expire_time: (dict["expire_time"] as? NSNumber)?.int64Value
            )
        }
    }

    // MARK: - 构造 Track

    private func buildTracks(
        pwdId: String,
        stoken: String,
        files: [QuarkFile]
    ) -> [Track] {
        var tracks: [Track] = []

        for (idx, file) in files.enumerated() {
            let title = (file.file_name as NSString).deletingPathExtension
            let artistComponents = title.components(separatedBy: "-")
            let artist = artistComponents.count > 1
                ? artistComponents.last?.trimmingCharacters(in: .whitespaces)
                : "夸克云端"

            tracks.append(Track(
                id: "quark-\(pwdId)-\(idx)-\(file.fid)-\(Int(Date().timeIntervalSince1970))",
                title: title,
                artist: artist ?? "夸克云端",
                album: "夸克分享",
                duration: 0,
                source: .quark,
                url: nil,
                artworkData: nil,
                sizeBytes: file.size,
                quarkPwdId: pwdId,
                quarkStoken: stoken,
                quarkFid: file.fid,
                quarkShareFidToken: file.share_fid_token
            ))
        }
        return tracks
    }
}
