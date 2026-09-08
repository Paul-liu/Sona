//
//  ToastService.swift
//  Sona
//
//  全局轻量提示（HUD）
//  - 用于导入完成、扫描完成等需要告知用户但不阻断操作的场景
//

import SwiftUI

@MainActor
final class ToastService: ObservableObject {
    static let shared = ToastService()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let icon: String
        let tint: Color
    }

    @Published private(set) var current: Toast?

    private var hideTask: DispatchWorkItem?

    private init() {}

    /// 显示一条 3 秒后自动消失的提示
    func show(
        _ message: String,
        icon: String = "checkmark.circle.fill",
        tint: Color = Color(red: 34.0 / 255.0, green: 197.0 / 255.0, blue: 94.0 / 255.0)
    ) {
        hideTask?.cancel()
        current = Toast(message: message, icon: icon, tint: tint)

        let task = DispatchWorkItem { [weak self] in
            self?.current = nil
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: task)
    }
}
