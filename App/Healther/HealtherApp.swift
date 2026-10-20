import SwiftUI

@main
struct HealtherApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.blue)
                .task { model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refreshToday() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "chat"
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("对话", systemImage: "bubble.left.and.text.bubble.right.fill", value: "chat") {
                ChatView()
            }
            Tab("今日", systemImage: "circle.hexagongrid.fill", value: "today") {
                TodayView()
            }
            Tab("记忆", systemImage: "brain.head.profile", value: "memory") {
                MemoryView()
            }
            Tab("设置", systemImage: "gearshape.fill", value: "settings") {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: model.hasAPIKey, initial: true) { _, has in showOnboarding = !has }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
    }
}
