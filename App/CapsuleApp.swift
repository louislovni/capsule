import SwiftUI

@main
struct CapsuleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Storage.prepare()
        CoreLog.start()
        EmulatorSession.prepareCompanionSettings()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
    }
}
