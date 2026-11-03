import SwiftUI

@main
struct SlowClawApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var processor = Processor.shared
    @StateObject private var cloud = CloudSync.shared
    @StateObject private var recorder = AudioRecorder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(processor)
                .environmentObject(cloud)
                .environmentObject(recorder)
                .task {
                    LegacyImport.runIfNeeded(store: store)
                    processor.start()
                    await cloud.sync()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                processor.kick()
                Task { await cloud.sync() }
            case .background:
                store.saveNow()
            default:
                break
            }
        }
    }
}

enum AppTab: Hashable { case journal, spaces, settings }

struct RootView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var recorder: AudioRecorder
    @State private var tab: AppTab = .journal
    @State private var showRecorder = false
    @AppStorage("slowclaw.open-into-recording") private var openIntoRecording = false
    @State private var didAutoOpen = false

    var body: some View {
        TabView(selection: $tab) {
            JournalListView(showRecorder: $showRecorder)
                .tabItem { Label("Journal", systemImage: "book.closed") }
                .tag(AppTab.journal)
            SpacesView()
                .tabItem { Label("Spaces", systemImage: "square.grid.2x2") }
                .tag(AppTab.spaces)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordView()
        }
        .onAppear {
            if openIntoRecording && !didAutoOpen {
                didAutoOpen = true
                showRecorder = true
            }
        }
        .alert("Storage problem", isPresented: Binding(
            get: { store.loadError != nil },
            set: { if !$0 { store.loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.loadError ?? "")
        }
    }
}
