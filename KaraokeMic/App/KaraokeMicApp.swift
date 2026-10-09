//
//  KaraokeMicApp.swift
//  雪宝 K歌麦克风 · iOS 端 · App 入口
//

import SwiftUI

@main
struct KaraokeMicApp: App {
    @StateObject private var app = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .preferredColorScheme(.dark)   // 强制深色，这是影院风的前提
        }
    }
}

// MARK: - 主框架（底部标签栏）

struct ContentView: View {
    @EnvironmentObject var app: AppViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("主控台", systemImage: "mic.fill")
            }
            .tag(0)

            NavigationStack {
                StudioView()
            }
            .tabItem {
                Label("混音室", systemImage: "slider.vertical.3")
            }
            .tag(1)

            NavigationStack {
                DeviceView()
            }
            .tabItem {
                Label("设备", systemImage: "tv")
            }
            .badge(app.network.discoveredDevices.isEmpty ? 0 : 1)
            .tag(2)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(3)
        }
        .tint(KaraokeTheme.accentCyan)
        .alert("出错了", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {
                app.errorMessage = nil
            }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }
}
