// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var watchdog: WatchdogController

    var body: some View {
        ZStack {
            TabView(selection: $model.selectedTab) {
                TunnelsScreen()
                    .tabItem { Label("Tunnel", systemImage: "network") }
                    .tag(AppModel.Tab.tunnels)
                NavigationStack {
                    WatchdogScreen()
                }
                .tabItem { Label("Giám sát", systemImage: "waveform.path.ecg") }
                .badge(watchdog.pause != nil ? Text("!") : nil)
                .tag(AppModel.Tab.watchdog)
                SettingsScreen()
                    .tabItem { Label("Cài đặt", systemImage: "gearshape") }
                    .tag(AppModel.Tab.settings)
                AboutScreen()
                    .tabItem { Label("Giới thiệu", systemImage: "info.circle") }
                    .tag(AppModel.Tab.about)
            }
            .tint(.wgAccent)

            if lock.locked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .alert("WG VPN", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            Color.wgNavy.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.wgAccent)
                Text("WG VPN đang khóa").font(.title2.bold()).foregroundStyle(.white)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Mở khóa bằng \(lock.biometryName)", systemImage: "faceid")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.wgAccent)
            }
        }
        .task { await lock.unlock() }
    }
}
