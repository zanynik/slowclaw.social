import SwiftUI

struct JournalUnitsView: View {
    @EnvironmentObject var state: AppState
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        List {
            if state.journalUnitGroups.isEmpty {
                Section {
                    Text("Your thoughts, grouped by what connects them.").font(.headline)
                    Text("Connect SlowClaw Web, then choose Organize thoughts. Keep both devices open while your journals are processed. Groups are saved on this iPhone.")
                        .foregroundStyle(.secondary)
                    NavigationLink("Connect SlowClaw Web") { WebCompanionView() }
                }
            }
            ForEach(state.journalUnitGroups) { group in
                Section {
                    DisclosureGroup {
                        ForEach(group.units) { unit in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(unit.text)
                                HStack {
                                    Button("Source journal") { source = state.memorySource(unit.sourceKey) }
                                    Spacer()
                                    Button("Forget", role: .destructive) { state.dismissJournalUnit(unit.id) }
                                }.font(.caption).buttonStyle(.borderless)
                            }.padding(.vertical, 6)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).lineLimit(3)
                            Text("\(group.units.count) thought\(group.units.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("Your thoughts")
            .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
    }
}
