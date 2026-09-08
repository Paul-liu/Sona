//
//  QuarkAuthService.swift
//  Sona
//
//  夸克网盘账号授权服务
//  - 内嵌 WKWebView 完成扫码 / 手机号登录
//  - 自动捕获 Cookie 并写入 UserDefaults
//  - 调用 /account/info 拉取昵称
//

import Foundation
import WebKit
import AppKit

@MainActor
final class QuarkAuthService: ObservableObject {
    static let shared = QuarkAuthService()

    /// 统一使用夸克 PC 客户端 UA：直链签名与请求头绑定，API 与 CDN 请求必须一致
    nonisolated static let clientUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"

    // MARK: - 公开状态

    @Published private(set) var isLoggedIn: Bool = false
    @Published private(set) var cookie: String?
    @Published private(set) var userName: String?
    /// 登录会话是否已过期（cookie 存在但服务端判定为游客）。nil = 未知
    @Published private(set) var sessionExpired: Bool = false

    // MARK: - 私有

    private let cookieKey = "Sona.Quark.Cookie"
    private let userNameKey = "Sona.Quark.UserName"
    private let cookieUpdatedAtKey = "Sona.Quark.Cookie.UpdatedAt"
    /// 会随 API 响应轮换下发的会话 cookie 名（见 alist #830 机制）
    private static let rotatingCookieNames: Set<String> = ["__puus", "__pus", "__pugs", "__sdid"]

    private init() {
        loadPersisted()
    }

    // MARK: - 持久化

    private func loadPersisted() {
        cookie = UserDefaults.standard.string(forKey: cookieKey)
        userName = UserDefaults.standard.string(forKey: userNameKey)
        isLoggedIn = (cookie?.isEmpty == false)
        sessionExpired = false
        // 启动后异步校验登录会话是否仍有效
        Task { _ = await validateSession() }
    }

    /// 外部直接写入 Cookie（如 WebView 抓取到后）
    func updateCookie(_ newCookie: String) {
        let trimmed = newCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        cookie = trimmed.isEmpty ? nil : trimmed
        isLoggedIn = (cookie != nil)
        sessionExpired = false
        if let cookie {
            UserDefaults.standard.set(cookie, forKey: cookieKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cookieUpdatedAtKey)
            Task {
                _ = await validateSession()
                await refreshUserName()
            }
        } else {
            UserDefaults.standard.removeObject(forKey: cookieKey)
            userName = nil
            UserDefaults.standard.removeObject(forKey: userNameKey)
        }
    }

    func clear() {
        updateCookie("")
    }

    /// Cookie 最后更新时间
    var cookieUpdatedAt: Date? {
        let value = UserDefaults.standard.double(forKey: cookieUpdatedAtKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    // MARK: - 会话维护

    /// 校验登录会话是否有效（调用 /config，401 即过期）
    @discardableResult
    func validateSession() async -> Bool {
        guard let cookie, !cookie.isEmpty else {
            sessionExpired = false
            return false
        }
        var request = URLRequest(url: URL(string: "https://pc-api.uc.cn/1/clouddrive/config?pr=ucpro&fr=pc")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue(Self.clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            mergeSessionCookies(from: http)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let code = json["code"] as? Int ?? json["status"] as? Int ?? -1
                let valid = (http.statusCode == 200 && code == 0)
                sessionExpired = !valid
                if valid {
                    Task { await refreshUserName() }
                }
                return valid
            }
            sessionExpired = true
            return false
        } catch {
            // 网络异常不判定过期
            return !sessionExpired
        }
    }

    /// 从 API 响应中捕获轮换的会话 cookie（__puus/__pus 等）并合并持久化。
    /// 机制参考 alist #830：直链签名与请求 cookie 绑定，cookie 轮换后必须同步更新。
    func mergeSessionCookies(from response: HTTPURLResponse) {
        guard let currentCookie = cookie else { return }
        // HTTPURLResponse 会把多个 Set-Cookie 合并为逗号分隔的单个头
        let headerValue = (response.allHeaderFields["Set-Cookie"] as? String)
            ?? (response.allHeaderFields["set-cookie"] as? String)
            ?? response.value(forHTTPHeaderField: "Set-Cookie")
        guard let headerValue, !headerValue.isEmpty else { return }

        var updated: [String: String] = [:]
        for name in Self.rotatingCookieNames {
            // 匹配 "<name>=<value>;"（value 内不含分号）
            guard let regex = try? NSRegularExpression(pattern: "\(name)=([^;]+)") else { continue }
            let range = NSRange(headerValue.startIndex..., in: headerValue)
            if let match = regex.firstMatch(in: headerValue, range: range),
               let r = Range(match.range(at: 1), in: headerValue) {
                let value = String(headerValue[r]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    updated[name] = value
                }
            }
        }
        guard !updated.isEmpty else { return }

        // 合并进现有 cookie（覆盖同名项，保留其余项）
        var parts: [String] = currentCookie
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("=") }
        for (name, value) in updated {
            parts.removeAll { existing in
                existing.hasPrefix("\(name)=")
            }
            parts.append("\(name)=\(value)")
        }
        let merged = parts.joined(separator: "; ")
        if merged != currentCookie {
            cookie = merged
            UserDefaults.standard.set(merged, forKey: cookieKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cookieUpdatedAtKey)
            print("[Quark] session cookies merged: \(updated.keys.sorted().joined(separator: ","))")
        }
    }

    /// 标记登录会话已过期（由分享解析服务在检测到游客直链 / 401 时调用）
    func markSessionExpired() {
        sessionExpired = true
    }

    // MARK: - 抓取

    /// 从 WKHTTPCookieStore 抓取所有夸克相关 Cookie 并保存
    func captureCookies(from store: WKHTTPCookieStore) async {
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        let quarkCookies = cookies.filter { cookie in
            let d = cookie.domain.lowercased()
            return d.contains("quark.cn") || d.contains("quark.com") || d.contains("drive.quark") || d.contains("uc.cn") || d.contains("uc.com")
        }
        guard !quarkCookies.isEmpty else { return }
        let cookieString = quarkCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        updateCookie(cookieString)
    }

    // MARK: - 登录候选验证（不写入状态）

    /// 用候选 Cookie 向夸克服务端验证是否为有效登录会话（防止把游客 Cookie 误存为登录态）。
    /// 返回 (是否有效, 昵称)。静态且不修改任何已保存状态，供登录弹窗在扫码期间反复调用。
    /// 备注：夸克不同登录态对 member/info / config / account/info 的可见性不同，这里同时探测多个端点，任一返回 code=0 即视为有效。
    nonisolated static func verifyLoginCookie(_ cookieString: String) async -> (valid: Bool, nickname: String?) {
        guard !cookieString.isEmpty else { return (false, nil) }

        let logPath = "/tmp/sona_quark_verify.log"
        var logLines: [String] = ["[QuarkVerify] --- \(Date()) ---"]
        let cookieKeys = cookieString
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: "=").first ?? "?" }
            .filter { !$0.isEmpty }
        logLines.append("[QuarkVerify] candidate cookie keys: \(cookieKeys.joined(separator: ","))")

        // 按可信度排序：member/info 能返回昵称；config 是通用登录态校验；account/info 兜底
        let endpoints: [(name: String, url: String, extraParams: String)] = [
            ("member/info", "https://pc-api.uc.cn/1/clouddrive/member/info", "?pr=ucpro&fr=pc&fetch_subscribe=true&fetch_identity=true"),
            ("config", "https://pc-api.uc.cn/1/clouddrive/config", "?pr=ucpro&fr=pc"),
            ("account/info", "https://pc-api.uc.cn/1/clouddrive/account/info", "?pr=ucpro&fr=pc")
        ]

        for (name, base, params) in endpoints {
            guard let url = URL(string: base + params) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
            request.setValue(clientUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                logLines.append("[QuarkVerify] \(name) http=\(http?.statusCode ?? -1) body=\(body.prefix(400))")

                guard http?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let code = json["code"] as? Int else {
                    continue
                }
                guard code == 0 else {
                    logLines.append("[QuarkVerify] \(name) code=\(code) rejected")
                    continue
                }

                var nickname: String?
                if let dataObj = json["data"] as? [String: Any] {
                    nickname = dataObj["nickname"] as? String
                        ?? dataObj["userName"] as? String
                        ?? dataObj["username"] as? String
                }
                logLines.append("[QuarkVerify] \(name) accepted nickname=\(nickname ?? "nil")")
                writeVerifyLog(logLines, to: logPath)
                return (true, nickname)
            } catch {
                logLines.append("[QuarkVerify] \(name) error=\(error.localizedDescription)")
            }
        }

        logLines.append("[QuarkVerify] all endpoints rejected candidate")
        writeVerifyLog(logLines, to: logPath)
        return (false, nil)

        func writeVerifyLog(_ lines: [String], to path: String) {
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 用户信息

    private func refreshUserName() async {
        guard let cookie else { return }
        guard let url = URL(string: "https://pan.quark.cn/account/info") else { return }
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue(Self.clientUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any] {
                let nickname = dataObj["nickname"] as? String
                    ?? dataObj["userName"] as? String
                    ?? dataObj["username"] as? String
                if let nickname {
                    userName = nickname
                    UserDefaults.standard.set(nickname, forKey: userNameKey)
                }
            }
        } catch {
            print("[Quark] refreshUserName failed: \(error.localizedDescription)")
        }
    }
}
