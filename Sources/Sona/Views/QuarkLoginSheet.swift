//
//  QuarkLoginSheet.swift
//  Sona
//
//  夸克网盘登录授权弹窗（v2 重新设计）
//  - 严格登录判定：必须同时出现 __pus + __puus（登录后才会下发的会话 Cookie），
//    游客 Cookie（__sdid / __pugs 等）不再误触发"登录成功"
//  - 服务端验证：候选 Cookie 先调 member/info 确认真登录（返回昵称），验证通过才保存
//  - 轮询检测：夸克登录页为 SPA，路由跳转不触发导航代理，用定时器轮询 Cookie
//  - 成功反馈：显示"✅ 登录成功：昵称"停留 2 秒再自动关闭；验证失败保持窗口打开
//

import SwiftUI
import WebKit

struct QuarkLoginSheet: View {
    @EnvironmentObject var quarkAuth: QuarkAuthService
    @Environment(\.dismiss) private var dismiss

    /// 登录流程状态机
    enum LoginPhase: Equatable {
        case loading
        case waitingScan
        case verifying
        case success(nickname: String?)
        case verifyFailed
    }

    @State private var phase: LoginPhase = .loading
    /// 是否已完成登录（完成后再收到候选回调一律忽略）
    @State private var loginFinished = false
    /// 触发 WebView 整体重建 = 重新加载登录页
    @State private var reloadToken = 0
    /// 最近一次上报的候选 Cookie（验证失败时允许用户强制使用）
    @State private var lastCandidateCookie: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                LoginWebView(
                    onCandidate: { cookie in handleCandidate(cookie) },
                    onPageLoaded: {
                        if phase == .loading { phase = .waitingScan }
                    }
                )
                .id(reloadToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .frame(width: 480, height: 720)
        .background(.regularMaterial)
    }

    // MARK: - 候选 Cookie 处理（严格判定 + 服务端验证）

    private func handleCandidate(_ cookie: String) {
        guard !loginFinished, phase != .verifying else { return }
        lastCandidateCookie = cookie
        phase = .verifying
        Task {
            let result = await QuarkAuthService.verifyLoginCookie(cookie)
            guard !loginFinished else { return }
            if result.valid {
                loginFinished = true
                quarkAuth.updateCookie(cookie)
                phase = .success(nickname: result.nickname)
                // 停留 2 秒让用户看清结果，再自动关闭
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                dismiss()
            } else {
                // Cookie 出现了 __pus/__puus 但服务端仍判定游客：
                // 保持窗口打开，用户可选择强制使用当前 Cookie（WebView 已正常显示网盘时可用）
                phase = .verifyFailed
            }
        }
    }

    /// 兜底方案：用户已看到 WebView 登录成功，但服务端校验因风控/UA/参数差异失败时，允许强制保存当前 Cookie
    private func forceAcceptCurrentCookie() {
        guard let cookie = lastCandidateCookie, !cookie.isEmpty else { return }
        loginFinished = true
        quarkAuth.updateCookie(cookie)
        phase = .success(nickname: quarkAuth.userName)
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "icloud.and.arrow.down.fill")
                .foregroundStyle(.tint)
            Text("夸克网盘登录")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                reloadToken += 1
                phase = .loading
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新加载登录页（二维码过期时使用）")
            .disabled(isBusy)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
            .disabled(isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var isBusy: Bool {
        if case .verifying = phase { return true }
        if case .success = phase { return true }
        return false
    }

    // MARK: - 底部状态条

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 6) {
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("正在加载登录页…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

            case .waitingScan:
                Image(systemName: "qrcode")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                Text("请使用手机夸克 App 扫码，或选择手机号登录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("窗口会一直保持打开，登录成功后自动关闭")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

            case .verifying:
                ProgressView()
                    .controlSize(.small)
                Text("已检测到登录，正在验证会话…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

            case .success(let nickname):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                Text(nickname.map { "登录成功：\($0)" } ?? "登录成功")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                Text("正在关闭窗口…")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

            case .verifyFailed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text("检测到登录 Cookie，但服务端验证未通过")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                if lastCandidateCookie != nil {
                    Button {
                        forceAcceptCurrentCookie()
                    } label: {
                        Label("网页已登录，强制使用当前 Cookie", systemImage: "forward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    Text("如上方网页已显示你的网盘文件，点此可跳过服务端校验")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("请点击右上角「重新加载」，刷新二维码后重新扫码")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

// MARK: - WKWebView 封装

private struct LoginWebView: NSViewRepresentable {
    let onCandidate: (String) -> Void
    let onPageLoaded: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://pan.quark.cn/#/list/signin") {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.startPolling(webView: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCandidate: onCandidate, onPageLoaded: onPageLoaded)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCandidate: (String) -> Void
        let onPageLoaded: () -> Void

        /// 上一次上报的候选 Cookie 串（只在变化时上报，避免验证失败后轮询刷屏）
        private var lastReportedCookie: String?
        private var pollTimer: Timer?

        init(onCandidate: @escaping (String) -> Void,
             onPageLoaded: @escaping () -> Void) {
            self.onCandidate = onCandidate
            self.onPageLoaded = onPageLoaded
        }

        deinit {
            pollTimer?.invalidate()
        }

        // MARK: 导航代理（负责页面加载状态；登录检测交给轮询）

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageLoaded()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // 加载失败也通知一次，让视图离开 loading 态
            onPageLoaded()
        }

        // MARK: 轮询检测登录 Cookie

        /// 夸克登录页是 SPA：扫码成功后路由跳转不一定触发导航代理，
        /// 且 Cookie 可能在任意时刻种下，因此用定时器轮询。
        func startPolling(webView: WKWebView) {
            pollTimer?.invalidate()
            let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.checkCookies(webView: webView)
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }

        private func checkCookies(webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let quarkCookies = cookies.filter { cookie in
                    let d = cookie.domain.lowercased()
                    return d.contains("quark.cn") || d.contains("quark.com") || d.contains("uc.cn") || d.contains("uc.com")
                }
                let names = Set(quarkCookies.map(\.name))

                // 严格判定：__pus 与 __puus 只有真正登录成功后才会下发，
                // 仅凭任意 1 个 cookie（如游客的 __sdid / __pugs）判定会导致弹窗秒关。
                guard names.contains("__pus"), names.contains("__puus") else { return }

                let cookieString = quarkCookies
                    .sorted { $0.name < $1.name }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                // 只在候选串变化时上报（验证失败后用户未重新扫码时不重复打服务端）
                guard cookieString != self.lastReportedCookie else { return }
                self.lastReportedCookie = cookieString
                self.onCandidate(cookieString)
            }
        }
    }
}
