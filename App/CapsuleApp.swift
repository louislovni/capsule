import SwiftUI

@main
struct CapsuleApp: App {
    init() {
        Storage.prepare()
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
    }
}
