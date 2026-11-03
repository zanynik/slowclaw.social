import SwiftUI

struct SpacesView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var processor: Processor
    @EnvironmentObject private var cloud: CloudSync
    @State private var newSpaceName = ""
    @State private var showNewSpace = false

    var body: some View {
        NavigationStack {
            List {
                let unsorted = store.unsortedJournals
                if !unsorted.isEmpty || processor.bulkProgress != nil {
                    Section {
                        if let p = processor.bulkProgress {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                                HStack {
                                    Text("Organizing \(p.done) of \(p.total)…").font(.footnote)
                                    Spacer()
                                    Button("Stop") { processor.cancelBulk() }.font(.footnote)
                                }
                            }
                        } else {
                            Button {
                                processor.organizeAllUnsorted()
                            } label: {
                                Label("Organize \(unsorted.count) unsorted \(unsorted.count == 1 ? "entry" : "entries")",
                                      systemImage: "sparkles")
                            }
                            NavigationLink {
                                UnsortedView()
                            } label: {
                                Label("View unsorted", systemImage: "tray")
                            }
                        }
                    } footer: {
                        if let reason = OnDeviceAI.unavailableReason { Text(reason) }
                    }
                }

                Section {
                    ForEach(store.visibleSpaces) { space in
                        NavigationLink(value: space.id) { SpaceRow(space: space) }
                    }
                    .onMove { store.moveSpace(from: $0, to: $1) }
                    .onDelete { offsets in
                        let list = store.visibleSpaces
                        for i in offsets { store.deleteSpace(list[i].id) }
                    }
                } footer: {
                    Text("New journals are filed into a space automatically. To-dos, ideas and questions from them collect here.")
                }
            }
            .navigationTitle("Spaces")
            .navigationDestination(for: String.self) { id in SpaceDetailView(spaceID: id) }
            .refreshable { await cloud.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewSpace = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New space")
                }
            }
            .alert("New space", isPresented: $showNewSpace) {
                TextField("Name", text: $newSpaceName)
                Button("Add") {
                    let name = newSpaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { store.addSpace(name: name) }
                    newSpaceName = ""
                }
                Button("Cancel", role: .cancel) { newSpaceName = "" }
            }
        }
    }
}

struct SpaceRow: View {
    @EnvironmentObject private var store: Store
    let space: Space

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: space.icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(space.name).font(.headline)
                let count = store.journals(in: space.id).count
                let todos = store.openTodoCount(space.id)
                Text("\(count) \(count == 1 ? "entry" : "entries")" + (todos > 0 ? " · \(todos) to-do\(todos == 1 ? "" : "s")" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SpaceDetailView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var processor: Processor
    let spaceID: String
    @State private var adding: ItemKind?
    @State private var newText = ""
    @State private var showDone = false
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        if let space = store.space(spaceID) {
            List {
                summarySection(space)
                ForEach(ItemKind.allCases) { kind in
                    itemSection(kind)
                }
                let journals = store.journals(in: spaceID)
                Section("Journal entries (\(journals.count))") {
                    if journals.isEmpty {
                        Text("No entries yet.").foregroundStyle(.secondary)
                    }
                    ForEach(journals.prefix(50)) { j in
                        NavigationLink {
                            JournalDetailView(journalID: j.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(j.displayTitle).lineLimit(1)
                                Text(j.createdAt.dayLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(space.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newName = space.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Menu {
                            ForEach(SpaceIcons.all, id: \.self) { icon in
                                Button { store.updateSpace(spaceID) { $0.icon = icon } } label: { Label(icon, systemImage: icon) }
                            }
                        } label: { Label("Icon", systemImage: space.icon) }
                        Button { store.clearDone(in: spaceID) } label: { Label("Clear done to-dos", systemImage: "checkmark.circle.badge.xmark") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Rename space", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") {
                    let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !n.isEmpty { store.updateSpace(spaceID) { $0.name = n } }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Space deleted", systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder
    private func summarySection(_ space: Space) -> some View {
        Section {
            if processor.summarizing.contains(spaceID) {
                HStack { ProgressView(); Text("Reading your entries…").foregroundStyle(.secondary) }
            } else if space.summary.isEmpty {
                Text(OnDeviceAI.isAvailable ? "Tap refresh for a short overview of what's been on your mind here."
                                           : "Overviews need Apple Intelligence.")
                    .foregroundStyle(.secondary)
            } else {
                Text(space.summary)
            }
        } header: {
            HStack {
                Text("Overview")
                Spacer()
                if OnDeviceAI.isAvailable {
                    Button {
                        Task { await processor.refreshSummary(spaceID: spaceID) }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(processor.summarizing.contains(spaceID) || store.journals(in: spaceID).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func itemSection(_ kind: ItemKind) -> some View {
        let all = store.items(in: spaceID).filter { $0.kind == kind }
        let open = all.filter { !$0.done }
        let done = all.filter(\.done)
        Section {
            ForEach(open) { item in ItemRow(item: item) }
                .onDelete { offsets in for i in offsets { store.updateItem(open[i].id) { $0.deleted = true } } }
            if adding == kind {
                TextField("New \(kind.singular.lowercased())", text: $newText)
                    .focused($addFocused)
                    .submitLabel(.done)
                    .onSubmit { commitAdd(kind) }
            }
            if kind == .todo && !done.isEmpty {
                DisclosureGroup("Done (\(done.count))", isExpanded: $showDone) {
                    ForEach(done) { item in ItemRow(item: item) }
                        .onDelete { offsets in for i in offsets { store.updateItem(done[i].id) { $0.deleted = true } } }
                }
            }
        } header: {
            HStack {
                Label(kind.label, systemImage: kind.symbol)
                Spacer()
                Button {
                    if adding == kind { commitAdd(kind) } else { adding = kind; newText = ""; addFocused = true }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add \(kind.singular)")
            }
        }
    }

    private func commitAdd(_ kind: ItemKind) {
        store.addItem(spaceID: spaceID, kind: kind, text: newText)
        newText = ""
        adding = nil
    }
}

struct ItemRow: View {
    @EnvironmentObject private var store: Store
    let item: SpaceItem
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if item.kind == .todo {
                Button {
                    store.updateItem(item.id) { $0.done.toggle() }
                } label: {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.done ? Color.green : Color.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
            }
            if editing {
                TextField("", text: $text, axis: .vertical)
                    .onSubmit { commit() }
                Button("Done") { commit() }.font(.caption)
            } else {
                Text(item.text)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .onTapGesture(count: 2) { text = item.text; editing = true }
            }
        }
        .contextMenu {
            Button { text = item.text; editing = true } label: { Label("Edit", systemImage: "pencil") }
            if let jid = item.journalID, store.journal(jid) != nil {
                Text("From: \(store.journal(jid)?.displayTitle ?? "")")
            }
            Button(role: .destructive) { store.updateItem(item.id) { $0.deleted = true } } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { store.updateItem(item.id) { $0.text = t } }
        editing = false
    }
}

struct UnsortedView: View {
    @EnvironmentObject private var store: Store
    var body: some View {
        List(store.unsortedJournals) { j in
            NavigationLink {
                JournalDetailView(journalID: j.id)
            } label: {
                VStack(alignment: .leading) {
                    Text(j.displayTitle).lineLimit(1)
                    Text(j.createdAt.dayLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Unsorted")
    }
}
