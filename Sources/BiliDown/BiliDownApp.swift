import SwiftUI
import BiliKit

@main
struct BiliDownApp: App {

    @StateObject private var settings: AppSettings
    @StateObject private var queue: DownloadQueue
    @StateObject private var account = AccountStore()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _queue = StateObject(wrappedValue: DownloadQueue(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(queue)
                .environmentObject(account)
        }
    }
}
