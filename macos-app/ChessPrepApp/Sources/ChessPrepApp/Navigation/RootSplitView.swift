import SwiftUI

struct RootSplitView: View {
    @ObservedObject var state: AppState
    private let sidebarWidth: CGFloat = 290
    private let detailWidth: CGFloat = 380

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if shouldShowDetailColumn {
                detail
                    .frame(width: detailWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            await state.loadGames()
        }
    }

    private var isGameExplorerRouteActive: Bool {
        guard state.selectedSection == .library else { return false }
        guard let route = state.libraryPath.last else { return false }
        if case .gameExplorer = route {
            return true
        }
        return false
    }

    private var shouldShowDetailColumn: Bool {
        switch state.selectedSection ?? .library {
        case .importPgn:
            return true
        case .library:
            return !isGameExplorerRouteActive
        }
    }

    private var sidebar: some View {
        List {
            Section {
                ForEach(AppSection.allCases) { section in
                    HStack {
                        Label(section.title, systemImage: section.systemImage)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.textOnBrown)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(state.selectedSection == section ? Theme.accent.opacity(0.55) : Theme.accent.opacity(0.18))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        state.selectedSection = section
                    }
                    .accessibilityAddTraits(.isButton)
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



                    HStack(spacing: 12) {
                        sidebarFilterButton(
                            title: "Apply",
                            foreground: Theme.sidebarBackground,
                            background: Theme.textOnBrown
                        ) {
                            state.reloadWithCurrentFilter()
                        }

                        sidebarFilterButton(
                            title: "Reset",
                            foreground: Theme.textOnBrown,
                            background: Theme.accent.opacity(0.55),
                            border: Theme.textOnBrown.opacity(0.25)
                        ) {
                            state.resetFilters()
                        }
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
        ZStack(alignment: .leading) {
            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .foregroundStyle(Theme.textSecondary.opacity(0.78))
                    .allowsHitTesting(false)
            }

            TextField("", text: text)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.sidebarFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .light)
    }

    private func sidebarFilterButton(
        title: String,
        foreground: Color,
        background: Color,
        border: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(background)
                )
                .overlay {
                    if let border {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(border, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch state.selectedSection ?? .library {
        case .importPgn:
            ImportView(state: state)
        case .library:
            NavigationStack(path: $state.libraryPath) {
                LibraryView(state: state)
                    .navigationDestination(for: LibraryRoute.self) { route in
                        switch route {
                        case .gameExplorer(let gameID):
                            GameDetailView(state: state, databaseGameID: gameID)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selectedSection ?? .library {
        case .importPgn:
            ImportStatusView(state: state)
        case .library:
            if isGameExplorerRouteActive {
                Color.clear
                    .allowsHitTesting(false)
            } else {
                GamePreviewView(state: state)
            }
        }
    }
}
