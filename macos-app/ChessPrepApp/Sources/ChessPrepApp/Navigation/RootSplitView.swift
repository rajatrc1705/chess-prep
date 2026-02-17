import SwiftUI

struct RootSplitView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 560, ideal: 700)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            await state.loadGames()
        }
    }

    private var sidebar: some View {
        List(selection: $state.selectedSection) {
            Section {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .foregroundStyle(Theme.textOnBrown)
                        .tag(Optional(section))
                        .listRowBackground(Theme.sidebarBackground)
                }
            } header: {
                Text("Workspace")
                    .foregroundStyle(Theme.textOnBrown.opacity(0.85))
            }

            if state.selectedSection == .library {
                Section {
                    sidebarTextField(
                        "Player, event, site",
                        text: Binding(
                            get: { state.filter.searchText },
                            set: { state.filter.searchText = $0 }
                        )
                    )
                    .listRowBackground(Theme.sidebarBackground)

                    Picker(
                        "Result",
                        selection: Binding(
                            get: { state.filter.result },
                            set: { state.filter.result = $0 }
                        )
                    ) {
                        ForEach(GameResultFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .foregroundStyle(Theme.textOnBrown)
                    .listRowBackground(Theme.sidebarBackground)

                    sidebarTextField(
                        "ECO",
                        text: Binding(
                            get: { state.filter.eco },
                            set: { state.filter.eco = $0 }
                        )
                    )
                    .listRowBackground(Theme.sidebarBackground)

                    sidebarTextField(
                        "Event/Site",
                        text: Binding(
                            get: { state.filter.eventOrSite },
                            set: { state.filter.eventOrSite = $0 }
                        )
                    )
                    .listRowBackground(Theme.sidebarBackground)

                    HStack {
                        Button("Apply") {
                            state.reloadWithCurrentFilter()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.textOnBrown)
                        .foregroundStyle(Theme.sidebarBackground)

                        Button("Reset") {
                            state.resetFilters()
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(Theme.textOnBrown)
                    }
                    .listRowBackground(Theme.sidebarBackground)
                } header: {
                    Text("Filters")
                        .foregroundStyle(Theme.textOnBrown.opacity(0.85))
                }
            }
        }
        .listStyle(.sidebar)
        .foregroundStyle(Theme.textOnBrown)
        .environment(\.colorScheme, .dark)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBackground)
    }

    private func sidebarTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.sidebarFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        switch state.selectedSection ?? .library {
        case .importPgn:
            ImportView(state: state)
        case .library:
            LibraryView(state: state)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selectedSection ?? .library {
        case .importPgn:
            ImportStatusView(state: state)
        case .library:
            GameDetailView(game: state.selectedGame)
        }
    }
}
