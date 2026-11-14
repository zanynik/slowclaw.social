import SwiftUI

/// Every open to-do across all spaces in one list — the daily "what's next" view.
struct TodosView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var cloud: CloudSync
    @AppStorage("slowclaw.todos.last-space") private var targetSpaceID = ""
    @State private var newText = ""
    @FocusState private var addFocused: Bool
    @State private var showDone = false

    private var openBySpace: [(Space, [SpaceItem])] {
        store.visibleSpaces.compactMap { space in
            let open = store.items(in: space.id).filter { $0.kind == .todo && !$0.done }
            return open.isEmpty ? nil : (space, open)
        }
    }

    /// The space a new to-do goes into: the last one used, else the first space.
    private var target: Space? {
        store.space(targetSpaceID) ?? store.visibleSpaces.first
    }

    var body: some View {
        NavigationStack {
            List {
                if let target {
                    Section {
                        HStack {
                            TextField("Add a to-do", text: $newText)
                                .focused($addFocused)
                                .submitLabel(.done)
                                .onSubmit(add)
                            Menu {
                                ForEach(store.visibleSpaces) { s in
                                    Button { targetSpaceID = s.id } label: { Label(s.name, systemImage: s.icon) }
                                }
                            } label: {
                                Label(target.name, systemImage: target.icon)
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            }
                            .accessibilityLabel("Space for new to-do: \(target.name)")
                        }
                    }
                }

                let groups = openBySpace
                let doneToday = store.todosDoneToday
                if groups.isEmpty {
                    ContentUnavailableView(doneToday.isEmpty ? "Nothing to do" : "All done",
                                           systemImage: "checkmark.circle",
                                           description: Text("To-dos you mention in a recording show up here, sorted by space."))
                }
                ForEach(groups, id: \.0.id) { space, todos in
                    Section {
                        ForEach(todos) { item in ItemRow(item: item) }
                            .onDelete { offsets in
                                for i in offsets { store.updateItem(todos[i].id) { $0.deleted = true } }
                            }
                    } header: {
                        Label(space.name, systemImage: space.icon)
                    }
                }
                if !doneToday.isEmpty {
                    // Checked something by mistake? It stays here for the day.
                    Section {
                        DisclosureGroup("Done today (\(doneToday.count))", isExpanded: $showDone) {
                            ForEach(doneToday) { item in ItemRow(item: item) }
                        }
                    }
                }
            }
            .animation(.default, value: store.items)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("To-dos")
            .refreshable { await cloud.sync() }
        }
    }

    private func add() {
        guard let target else { return }
        store.addItem(spaceID: target.id, kind: .todo, text: newText)
        targetSpaceID = target.id
        newText = ""
        addFocused = true
    }
}
