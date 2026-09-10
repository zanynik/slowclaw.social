import SwiftUI

struct WeeklyReflectionCard: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let weekly = state.currentWeeklyReflection, !weekly.dismissed {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("A reflection for this week").font(.headline)
                    Spacer()
                    Button { state.dismissWeeklyReflection() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss this reflection")
                }
                Text(weekly.reflection.observation)
                Text(weekly.reflection.question).font(.headline)
                Text("A tentative connection between two recent journal passages—not a complete account of your week. Checked quotes do not make the interpretation true.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(weekly.sources) { source in
                    NavigationLink { ContextExplorer(journalKey: source.id) } label: {
                        Text(source.date.formatted(date: .abbreviated, time: .omitted) + " · " + String(source.text.prefix(100)))
                            .font(.caption).multilineTextAlignment(.leading)
                    }
                }
                if let source = weekly.sources.first {
                    FollowQuestionButton(sourceKey: source.id, suggestion: weekly.reflection.question)
                }
            }.buttonStyle(.borderless).padding(.vertical, 6)
        }
    }
}

struct DraftEvidenceView: View {
    @EnvironmentObject var state: AppState
    let draftKey: String
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        if let evidence = DraftEvidence.load(draftKey) {
            DisclosureGroup("Why this draft was prepared") {
                if !state.excludedMemoryKeys.contains(evidence.journalKey),
                   let entry = state.memorySource(evidence.journalKey), evidence.matches(entry.content) {
                    Text(evidence.quote).font(.callout).foregroundStyle(.secondary)
                    Text("The model picked a possible lesson from this passage. Review accuracy and private details before sharing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open original journal") { source = entry }
                } else {
                    Text("The original source changed or is unavailable. Check this draft carefully before sharing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.font(.caption)
                .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
        }
    }
}
