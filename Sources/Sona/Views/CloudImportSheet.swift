//
//  CloudImportSheet.swift
//  Sona
//
//  云端分享导入弹窗（夸克 / 阿里云盘通用）
//  - 粘贴分享文本后自动识别来源，无需手动选择网盘
//  - 夸克：需要已完成扫码授权；阿里云盘：匿名访问，无需登录
//

import SwiftUI

/// 云端来源
enum CloudSource: String {
    case quark
    case aliyun

    var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .aliyun: return "阿里云盘"
        }
    }

    var icon: String {
        switch self {
        case .quark: return "cloud.fill"
        case .aliyun: return "externaldrive.fill.badge.checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .quark: return Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
        case .aliyun: return Color(red: 0.0, green: 0.48, blue: 1.0)
        }
    }
}

struct CloudImportSheet: View {
    @EnvironmentObject var quarkAuth: QuarkAuthService
    @EnvironmentObject var quarkShare: QuarkShareService
    @EnvironmentObject var aliyunShare: AliyunShareService
    @Environment(\.dismiss) private var dismiss

    @State private var shareText: String = ""

    private var detected: CloudSource? {
        let text = shareText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if AliyunShareService.matches(text) { return .aliyun }
        if text.contains("quark.cn") || text.contains("/~") { return .quark }
        return nil
    }

    private var isBusy: Bool {
        quarkShare.isResolving || aliyunShare.isResolving
    }

    private var currentError: String? {
        aliyunShare.lastError ?? quarkShare.lastError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            hint
            editor
            sourceBadge
            errorBanner
            footer
        }
        .padding(20)
        .frame(width: 540, height: 400)
        .background(.regularMaterial)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 16))
                .foregroundStyle(.tint)
            Text("导入云端分享")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var hint: some View {
        Text("粘贴网盘 APP 复制的整段文本即可（夸克网盘 / 阿里云盘自动识别），会自动提取链接与提取码。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
            TextEditor(text: $shareText)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .scrollContentBackground(.hidden)
            if shareText.isEmpty {
                Text("https://pan.quark.cn/s/... 或 https://www.alipan.com/s/...")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 130)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    /// 自动识别结果提示
    @ViewBuilder
    private var sourceBadge: some View {
        HStack(spacing: 6) {
            if let source = detected {
                Image(systemName: source.icon)
                    .foregroundStyle(source.tint)
                Text("已识别为 \(source.displayName)")
                    .font(.system(size: 11, weight: .medium))
                if source == .quark && !quarkAuth.isLoggedIn {
                    Text("· 需先完成夸克登录授权")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                if source == .aliyun {
                    Text("· 无需登录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("等待输入…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11))
    }

    @ViewBuilder
    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 限流中（独立于错误横幅，蓝紫色，便于区分）
            if aliyunShare.rateLimitedRetryAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(Color(red: 0.0, green: 0.48, blue: 1.0))
                        Text(retryMessage(at: context.date))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            if let err = currentError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// 倒计时文案（由 TimelineView 每秒驱动）
    private func retryMessage(at now: Date) -> String {
        guard let retryAt = aliyunShare.rateLimitedRetryAt else {
            return "阿里云盘限流中…"
        }
        let secs = max(0, Int(retryAt.timeIntervalSince(now).rounded(.up)))
        return "阿里云盘限流中，约 \(secs) 秒后自动重试…"
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                Task { await importShare() }
            } label: {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 90)
                } else {
                    Text("解析并导入")
                        .frame(width: 90)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(shareText.isEmpty || isBusy)
        }
    }

    // MARK: - 导入

    private func importShare() async {
        let text = shareText
        let source = detected

        switch source {
        case .aliyun:
            let playlist = await aliyunShare.resolveShare(text)
            if playlist != nil { dismiss() }
        case .quark:
            guard quarkAuth.isLoggedIn else {
                quarkShare.lastError = "请先完成夸克账号登录（侧边栏「夸克网盘」→ 登录授权）"
                return
            }
            let playlist = await quarkShare.resolveShare(text)
            if playlist != nil { dismiss() }
        case .none:
            quarkShare.lastError = "无法识别网盘来源，请粘贴夸克或阿里云盘的分享链接"
        }
    }
}
