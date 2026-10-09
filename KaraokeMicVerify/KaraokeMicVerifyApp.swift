//
//  KaraokeMicVerifyApp.swift
//  雪宝 K歌麦克风 · 极简验证版 · App 入口
//

import SwiftUI

@main
struct KaraokeMicVerifyApp: App {
    // ★ 启动即开始自动发现盒子（第 18 轮新增）
    //
    // 盒子 IP 由 DHCP 分配会变（实测 .5 → .10），
    // 手动改 IP 容易忘也容易打错。盒子端本来就在每秒广播，
    // 我们监听一下，用户一次配置都不用动。
    @StateObject private var vm = VerifyViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .preferredColorScheme(.dark)     // 强制深色，截图对比更准
                .statusBarHidden(false)
                .onAppear {
                    // 等界面出现再开始扫描，
                    // 避免启动阶段与音频初始化抢资源
                    vm.startDiscovery()
                }
        }
    }
}
