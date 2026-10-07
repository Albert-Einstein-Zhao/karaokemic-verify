//
//  KaraokeMicVerifyApp.swift
//  雪宝 K歌麦克风 · 极简验证版 · App 入口
//

import SwiftUI

@main
struct KaraokeMicVerifyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)     // 强制深色，截图对比更准
                .statusBarHidden(false)
        }
    }
}
