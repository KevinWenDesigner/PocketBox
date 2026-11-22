import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var playerManager: PlayerEngineManager
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                LiveHomeView()
                    .tabItem {
                        Label("直播", systemImage: "tv")
                    }
                    .tag(0)

                VodHomeView()
                    .tabItem {
                        Label("点播", systemImage: "film")
                    }
                    .tag(1)

                LibraryView()
                    .tabItem {
                        Label("历史收藏", systemImage: "clock.arrow.circlepath")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("源与设置", systemImage: "slider.horizontal.3")
                    }
                    .tag(3)
            }

            if playerManager.currentMedia != nil && !playerManager.isPlayerPresented {
                VStack(spacing: 0) {
                    MiniPlayerBar()
                }
                .padding(.bottom, 52)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $playerManager.isPlayerPresented) {
            PlayerContainerView()
        }
    }
}
