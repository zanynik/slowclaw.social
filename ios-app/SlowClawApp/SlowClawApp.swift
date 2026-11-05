import SwiftUI
import NaturalLanguage

@main
struct SlowClawApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var processor = Processor.shared
    @StateObject private var cloud = CloudSync.shared
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var book = BookStore.shared
    @StateObject private var news = NewsStore.shared
    @StateObject private var videos = VideoStore.shared
    @StateObject private var local = LocalServer.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(processor)
                .environmentObject(cloud)
                .environmentObject(recorder)
                .environmentObject(book)
                .environmentObject(news)
                .environmentObject(videos)
                .environmentObject(local)
                .task {
                    LegacyImport.runIfNeeded(store: store)
                    book.onLocalChange = { CloudSync.shared.schedulePush() }
                    processor.start()
                    // The better embedding model downloads once, in the background.
                    Task.detached(priority: .utility) { await Embedder.prepare(for: [.english, NLLanguage(rawValue: Locale.current.language.languageCode?.identifier ?? "en")]) }
                    if local.enabled { local.start() }
                    await cloud.sync()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                processor.kick()
                if local.enabled { local.start() }
                Task { await cloud.sync() }
            case .background:
                store.saveNow()
                book.saveNow()
                // iOS suspends the app in the background; the browser reconnects on return.
                local.stop()
            default:
                break
            }
        }
    }
}

enum AppTab: Hashable { case journal, todos, spaces, book, discover }

struct RootView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var recorder: AudioRecorder
    @State private var tab: AppTab = .journal
    @State private var showRecorder = false
    @AppStorage("slowclaw.open-into-recording") private var openIntoRecording = false
    @State private var didAutoOpen = false
    @ObservedObject private var recordRequest = RecordRequest.shared

    var body: some View {
        TabView(selection: $tab) {
            JournalListView(showRecorder: $showRecorder)
                .tabItem { Label("Journal", systemImage: "book.closed") }
                .tag(AppTab.journal)
            TodosView()
                .tabItem { Label("To-dos", systemImage: "checklist") }
                .tag(AppTab.todos)
            SpacesView()
                .tabItem { Label("Spaces", systemImage: "square.grid.2x2") }
                .tag(AppTab.spaces)
            BookView()
                .tabItem { Label("Book", systemImage: "book") }
                .tag(AppTab.book)
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkle.magnifyingglass") }
                .tag(AppTab.discover)
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordView()
        }
        .onAppear {
            if (openIntoRecording || recordRequest.pending) && !didAutoOpen {
                didAutoOpen = true
                recordRequest.pending = false
                showRecorder = true
            }
        }
        .onChange(of: recordRequest.pending) { _, pending in
            // Siri / Action Button / Shortcuts asked to record.
            guard pending else { return }
            recordRequest.pending = false
            tab = .journal
            showRecorder = true
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
