//
//  SidebarView.swift
//  Sona
//
//  左侧侧边栏导航
//  - 本地/云端导入均按歌单展示，歌单名对应文件夹或分享标题
//  - 导入数量不再显示在侧边栏，改由 Toast 提示
//  - 云端分组：每个网盘一个可折叠的纵向分组（便于未来扩展更多网盘）
//
//  ⚠️ 实现说明（曾踩坑）：
//  早期版本使用 `List(selection:)` + `.tag()` 做导航，实际完全不生效：
//   1. `.tag()` 只作用于 List 的「直接行视图」，写在 HStack / VStack 内部
//      的子视图上会被忽略；
//   2. 行内嵌套 `Button` 会吞掉点击，selection 不会变更。
//  因此改为完全手动模式：每行 `onTapGesture` 显式赋值 selection，
//  选中态由自绘 RoundedRectangle 背景呈现，行为 100% 可控。
//

import SwiftUI

/// 云端网盘类型。
/// 未来接入新网盘时：在此枚举加一个 case + 在 `SidebarView.playlists(for:)` 加一个分支即可，
/// 侧边栏会自动多出一个可折叠分组。
enum CloudKind: String, CaseIterable, Identifiable {
    case quark
    case aliyun

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .aliyun: return "阿里云盘"
        }
    }

    var icon: String {
        switch self {
        case .quark: return "icloud"
        case .aliyun: return "externaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .quark: return Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
        case .aliyun: return Color(red: 0.0, green: 0.48, blue: 1.0)
        }
    }

    /// 对应的 TrackSource（用于歌单路由）
    var trackSource: TrackSource {
        switch self {
        case .quark: return .quark
        case .aliyun: return .aliyun
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var library: LocalLibraryService
    @EnvironmentObject var quarkAuth: QuarkAuthService
    @EnvironmentObject var quarkShare: QuarkShareService
    @EnvironmentObject var aliyunShare: AliyunShareService

    @Binding var selection: SidebarSelection?
    @Binding var showQuarkImport: Bool
    @Binding var showQuarkLogin: Bool

    /// 各网盘分组的展开状态（默认全部展开）
    @State private var expanded: Set<CloudKind> = Set(CloudKind.allCases)

    var body: some View {
        List {
            Section {
                NavRow(isSelected: isSelected(.library)) {
                    selection = .library
                } content: {
                    Label("资料库", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                sectionHeader("资料库")
            }

            Section {
                NavRow(isSelected: isSelected(.local)) {
                    selection = .local
                } content: {
                    Label("本地音乐", systemImage: "folder.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ActionButton(
                        icon: "plus.circle.fill",
                        help: "选择音乐文件夹"
                    ) {
                        library.pickFolder()
                    }
                }

                ForEach(library.playlists) { playlist in
                    PlaylistNavRow(
                        playlist: playlist,
                        isSelected: isSelected(.localPlaylist(id: playlist.id)),
                        indent: true
                    ) {
                        selection = .localPlaylist(id: playlist.id)
                    } onRemove: {
                        library.removePlaylist(id: playlist.id)
                        if case .localPlaylist(let id) = selection, id == playlist.id {
                            selection = .local
                        }
                    }
                }
            } header: {
                sectionHeader("本地")
            }

            Section {
                cloudSectionContent
            } header: {
                sectionHeader("云端")
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    // MARK: - 云端分组（纵向可折叠，数据驱动便于扩展）

    @ViewBuilder
    private var cloudSectionContent: some View {
        ForEach(CloudKind.allCases) { kind in
            let isExpanded = expanded.contains(kind)
            let items = playlists(for: kind)

            // 网盘标题行（点击展开/收起）
            CloudDriveRow(
                kind: kind,
                isExpanded: isExpanded,
                status: status(for: kind),
                count: items.count
            ) {
                toggle(kind)
            }

            if isExpanded {
                // 状态行：登录信息 / 免登录说明 / 登录入口
                cloudStatusRow(for: kind)
                    .padding(.leading, 26)

                ForEach(items) { playlist in
                    PlaylistNavRow(
                        playlist: playlist,
                        isSelected: isSelected(playlist.selectionID),
                        indent: true
                    ) {
                        selection = playlist.selectionID
                    } onRemove: {
                        removeCloudPlaylist(playlist)
                    }
                    .padding(.leading, 26)
                }
            }
        }

        // 底部：导入分享链接（所有网盘共用，弹窗自动识别来源）
        HStack(spacing: 4) {
            Button {
                showQuarkImport = true
            } label: {
                Label("导入分享链接…", systemImage: "link.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
    }

    private func playlists(for kind: CloudKind) -> [Playlist] {
        switch kind {
        case .quark: return quarkShare.playlists
        case .aliyun: return aliyunShare.playlists
        }
    }

    private func status(for kind: CloudKind) -> CloudDriveRow.StatusKind {
        switch kind {
        case .quark:
            if !quarkAuth.isLoggedIn || quarkAuth.sessionExpired { return .warning }
            return .ready
        case .aliyun:
            return .ready
        }
    }

    private func toggle(_ kind: CloudKind) {
        if expanded.contains(kind) {
            expanded.remove(kind)
        } else {
            expanded.insert(kind)
        }
    }

    /// 各网盘的状态/操作行
    @ViewBuilder
    private func cloudStatusRow(for kind: CloudKind) -> some View {
        switch kind {
        case .quark:
            HStack(spacing: 6) {
                if quarkAuth.isLoggedIn {
                    if quarkAuth.sessionExpired {
                        Text("登录已过期 · 请重新授权")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    } else if let user = quarkAuth.userName {
                        Text(user)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        quarkAuth.clear()
                        quarkShare.clearAll()
                    } label: {
                        Text("退出登录")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        showQuarkLogin = true
                    } label: {
                        Label("扫码登录", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
        case .aliyun:
            HStack(spacing: 6) {
                Text("免登录 · 匿名访问分享")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
        }
    }

    private func removeCloudPlaylist(_ playlist: Playlist) {
        switch playlist.source {
        case .local:
            library.removePlaylist(id: playlist.id)
        case .quark:
            quarkShare.removePlaylist(id: playlist.id)
            if case .quarkPlaylist(let id) = selection, id == playlist.id {
                selection = .library
            }
        case .aliyun:
            aliyunShare.removePlaylist(id: playlist.id)
            if case .aliyunPlaylist(let id) = selection, id == playlist.id {
                selection = .library
            }
        }
    }

    // MARK: - 选中判定

    private func isSelected(_ candidate: SidebarSelection) -> Bool {
        guard let current = selection else { return false }
        return current == candidate
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - 网盘分组标题行（可折叠）

private struct CloudDriveRow: View {
    enum StatusKind {
        case ready
        case warning
    }

    let kind: CloudKind
    let isExpanded: Bool
    let status: StatusKind
    let count: Int
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
                .animation(.easeOut(duration: 0.15), value: isExpanded)

            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 16, alignment: .center)

            Text(kind.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }

            Circle()
                .fill(status == .ready ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }
}

// MARK: - 通用可点击导航行

/// 手绘选中态的可点击侧边栏行。
/// 不使用 `List(selection:)`，避免 tag 失效 + 行内 Button 吞点击的问题。
private struct NavRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isHovering { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}

/// 行内的小图标按钮（点击不会冒泡到所在行）
private struct ActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 歌单行

private struct PlaylistNavRow: View {
    let playlist: Playlist
    let isSelected: Bool
    /// 是否缩进显示（用于挂在网盘分组下的二级层级）
    var indent: Bool = false
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(accent)
                .frame(width: 16, alignment: .center)

            Text(playlist.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .contextMenu {
            Button("移除歌单", role: .destructive, action: onRemove)
        }
    }

    private var icon: String {
        switch playlist.source {
        case .local: return "folder"
        case .quark: return "icloud"
        case .aliyun: return "externaldrive"
        }
    }

    private var accent: Color {
        switch playlist.source {
        case .local:
            return Color(red: 10.0 / 255.0, green: 132.0 / 255.0, blue: 1.0)
        case .quark:
            return Color(red: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0)
        case .aliyun:
            return Color(red: 0.0, green: 0.48, blue: 1.0)
        }
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isHovering { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}

// MARK: - Playlist → SidebarSelection

extension Playlist {
    /// 按来源映射到对应的侧边栏导航项
    var selectionID: SidebarSelection {
        switch source {
        case .local: return .localPlaylist(id: id)
        case .quark: return .quarkPlaylist(id: id)
        case .aliyun: return .aliyunPlaylist(id: id)
        }
    }
}
