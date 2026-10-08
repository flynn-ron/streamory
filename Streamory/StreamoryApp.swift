import SwiftUI

@main
struct StreamoryApp: App {
    @StateObject private var library = PhotoLibraryStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(library).preferredColorScheme(.dark)
        }
    }
}
