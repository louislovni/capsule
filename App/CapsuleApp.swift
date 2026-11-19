import SwiftUI

@main
struct CapsuleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Storage.prepare()
        CoreLog.start()
        EmulatorSession.prepareCompanionSettings()
        CapsuleTheme.apply()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .preferredColorScheme(.dark)
                .tint(.capsuleAccent)
        }
    }
}
