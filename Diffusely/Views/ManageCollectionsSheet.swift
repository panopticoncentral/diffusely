import SwiftUI
import SwiftData

struct ManageCollectionsSheet: View {
    let target: ManageCollectionsTarget
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var civitaiService = CivitaiService()
    @State private var viewModel: ManageCollectionsViewModel?
    @State private var showingCreate = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Manage Collections")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    // Membership changes apply immediately, so Done is the
                    // confirming action (bold, trailing) rather than a cancel.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 560)
        #endif
        .task {
            if viewModel == nil {
                let persistence = CollectionPersistenceService(modelContext: modelContext)
                viewModel = ManageCollectionsViewModel(
                    target: target,
                    api: civitaiService,
                    persistence: persistence
                )
            }
            await viewModel?.load()
        }
        .sheet(isPresented: $showingCreate) {
            CreateCollectionView(initialType: target.collectionType, onCreated: { newId in
                Task {
                    // CreateCollectionView gives us only the id; fetch the full
                    // model so the VM has name/type/description for its row.
                    if let full = try? await civitaiService.getCollectionById(id: newId) {
                        await viewModel?.addNewCollection(full)
                    }
                }
            })
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            switch vm.loadState {
            case .loading:
                ProgressView("Loading collections…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(message)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await vm.load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                List {
                    Button(action: { showingCreate = true }) {
                        Label("New Collection…", systemImage: "folder.badge.plus")
                            .foregroundColor(.accentColor)
                    }
                    if vm.collections.isEmpty {
                        Section {
                            VStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                                Text("No \(target.displayName) collections found")
                                    .foregroundColor(.secondary)
                                Text("Create one to add this \(target.displayName) to it.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    } else {
                        ForEach(vm.collections) { collection in
                            collectionRow(collection, vm: vm)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: CivitaiCollection, vm: ManageCollectionsViewModel) -> some View {
        let isMember = vm.membership.contains(collection.id)
        VStack(alignment: .leading, spacing: 4) {
            // Leading checkmark row (matching ManageAlbumsSheet) instead of a
            // trailing Toggle, so the two membership sheets read the same. A
            // collection targets a single item, so it's binary — no tri-state.
            Button {
                Task { await vm.toggle(collection) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isMember ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                        if let desc = collection.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(vm.pendingFlips.contains(collection.id))
            .accessibilityAddTraits(isMember ? .isSelected : [])

            if let message = vm.rowErrors[collection.id] {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .onTapGesture {
                    Task { await vm.toggle(collection) }
                }
            }
        }
    }
}
