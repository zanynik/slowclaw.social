import SwiftUI

/// Uses the same journal-based relevance decisions, but never interleaves
/// short social notes with the long-form reading surface.
struct PulseView: View {
    @EnvironmentObject var state: AppState
    @State private var showConversations = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Pulse").font(DS.titleFont)
                    Spacer()
                    Button { showConversations = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                        .accessibilityLabel("My posts and replies")
                }
                if state.readsLoading || state.readsDecisionBusy { ProgressView("Finding conversations…") }
                if state.relevantPulse.isEmpty && !state.readsLoading && !state.readsDecisionBusy {
                    ContentUnavailableView("A little connection", systemImage: "bubble.left",
                        description: Text("Short Nostr posts that match your interests appear here. Pull to refresh."))
                }
                ForEach(state.relevantPulse) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.description).textSelection(.enabled)
                        HStack {
                            Button("Open conversation") { state.openArticle(item) }
                            Spacer()
                            CopyTextButton(text: item.description)
                        }.font(.caption)
                    }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding(20)
        }
        .sheet(isPresented: $showConversations) { NostrPostsView() }
        .refreshable { await state.loadReads(force: true) }
        .task { await state.loadReads() }
    }
}
