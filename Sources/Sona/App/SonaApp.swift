//
//  SonaApp.swift
//  Sona
//
//  应用入口、AppDelegate、菜单与快捷键
//

import SwiftUI
import AppKit

@main
struct SonaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = AudioPlayerService.shared
    @StateObject private var library = LocalLibraryService.shared
    @StateObject private var quarkAuth = QuarkAuthService.shared
    @StateObject private var quarkShare = QuarkShareService.shared
    @StateObject private var aliyunShare = AliyunShareService.shared
    @StateObject private var proxy = LocalStreamProxy.shared
    @StateObject private var toast = ToastService.shared

    var body: some Scene {
        WindowGroup("Sona") {
            MainWindowView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(quarkAuth)
                .environmentObject(quarkShare)
                .environmentObject(aliyunShare)
                .environmentObject(proxy)
                .environmentObject(toast)
                .accentColor(Color(red: 0.988, green: 0.235, blue: 0.267)) // #FC3C44 Apple Red
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开音乐文件夹…") {
                    library.pickFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("导入云端分享…") {
                    NotificationCenter.default.post(name: .sonaShowQuarkImport, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("播放") {
                Button(player.isPlaying ? "暂停" : "播放") {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("下一首") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("上一首") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])

                Divider()

                Button(player.shuffleEnabled ? "关闭随机" : "开启随机") {
                    player.shuffleEnabled.toggle()
                }

                Button("切换循环模式") {
                    switch player.repeatMode {
                    case .off: player.repeatMode = .all
                    case .all: player.repeatMode = .one
                    case .one: player.repeatMode = .off
                    }
                }
            }
        }
    }
}

/// NSApplicationDelegate —— 接管激活策略与终止行为
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保即便从 CLI `swift run` 启动也以 .regular 激活
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 提前拉起本地代理（首次构造将异步启动监听）
        _ = LocalStreamProxy.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 关闭代理监听
        // LocalStreamProxy 当前为单例生命周期，未显式 stop
    }
}

// MARK: - 跨组件通知

extension Notification.Name {
    /// 主窗口显示「导入夸克分享」弹窗
    static let sonaShowQuarkImport = Notification.Name("Sona.ShowQuarkImport")

    /// 主窗口显示「夸克登录」弹窗
    static let sonaShowQuarkLogin = Notification.Name("Sona.ShowQuarkLogin")
}
