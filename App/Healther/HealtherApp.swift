import SwiftUI

@main
struct HealtherApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.blue)
                .task { model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await model.requestNewHealthTypesIfNeeded()
                            await model.refreshToday()
                            await model.proactiveTick(inBackground: false)
                        }
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("对话", systemImage: "bubble.left.and.text.bubble.right.fill", value: "chat") {
                ChatView()
            }
            Tab("今日", systemImage: "heart.text.square.fill", value: "today") {
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
        .onOpenURL { url in
            // healther://tab/<chat|today|memory|settings>
            if url.host() == "tab", let target = url.pathComponents.last,
               ["chat", "today", "memory", "settings"].contains(target) {
                model.tab = target
            }
            #if DEBUG
            if url.host() == "debug", url.pathComponents.dropFirst().first == "note", let key = url.pathComponents.last {
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
                model.debugSetNote(day: key, title: v("title") ?? "", detail: v("detail") ?? "", font: v("font"))
            }
            #endif
            // healther://day/2026-10-18 opens the Today tab on that day
            if url.host() == "day", let key = url.pathComponents.last,
               let day = try? Date(key, strategy: .iso8601.year().month().day()) {
                model.showDay(day)
                model.tab = "today"
            }
        }
        .onChange(of: model.settings.onboarded, initial: true) { _, done in showOnboarding = !done }
        .task {
            // While the app is open, check once a minute for check-ins whose time has come.
            while !Task.isCancelled {
                await model.proactiveTick(inBackground: false)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
    }
}
