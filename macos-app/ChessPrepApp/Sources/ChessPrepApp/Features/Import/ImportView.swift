import AppKit
import SwiftUI

struct ImportView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import Workspace")
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)

                Text("Native PGN import flow backed by the Rust engine.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Database")
                        .font(Typography.sectionTitle)

                    TextField(
                        "Path to SQLite database",
                        text: $state.databasePath
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Select Database File") {
                        selectDatabasePath()
                    }
                    .buttonStyle(.bordered)
                }
                .panelCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("PGN Source")
                        .font(Typography.sectionTitle)

                    TextField(
                        "Path to PGN file(s)",
                        text: Binding(
                            get: { state.pgnPath },
                            set: { value in
                                state.pgnPath = value
                                state.selectedPgnPaths = []
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Select PGN File(s)") {
                        selectPgnPaths()
                    }
                    .buttonStyle(.bordered)

                    if state.selectedPgnPaths.count > 1 {
                        Text("\(state.selectedPgnPaths.count) PGN files selected for batch import.")
                            .font(Typography.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .panelCard()

                HStack(spacing: 12) {
                    Button("Run Import") {
                        Task {
                            await state.startImport()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if state.isImportRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .padding(24)
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .environment(\.colorScheme, .light)
        .background(Theme.background)
    }

    private func selectPgnPaths() {
        let panel = NSOpenPanel()
        panel.title = "Select PGN File(s)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["pgn"]

        if panel.runModal() == .OK {
            let paths = panel.urls.map { $0.path(percentEncoded: false) }
            guard !paths.isEmpty else {
                return
            }

            state.selectedPgnPaths = paths
            if paths.count == 1 {
                state.pgnPath = paths[0]
            } else {
                state.pgnPath = paths.joined(separator: "; ")
            }
        }
    }

    private func selectDatabasePath() {
        let panel = NSOpenPanel()
        panel.title = "Select SQLite Database"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["sqlite", "sqlite3", "db"]

        if panel.runModal() == .OK, let url = panel.url {
            state.databasePath = url.path(percentEncoded: false)
        }
    }
}

struct ImportStatusView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Status")
                .font(Typography.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            ProgressView(value: state.importProgress.completion)
                .tint(Theme.accent)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Total")
                        .font(Typography.detailLabel)
                    Text("\(state.importProgress.total)")
                        .font(Typography.dataMono)
                }
                GridRow {
                    Text("Inserted")
                        .font(Typography.detailLabel)
                    Text("\(state.importProgress.inserted)")
                        .font(Typography.dataMono)
                        .foregroundStyle(Theme.success)
                }
                GridRow {
                    Text("Skipped")
                        .font(Typography.detailLabel)
                    Text("\(state.importProgress.skipped)")
                        .font(Typography.dataMono)
                        .foregroundStyle(Theme.error)
                }
            }

            statusMessage

            Spacer()
        }
        .foregroundStyle(Theme.textPrimary)
        .environment(\.colorScheme, .light)
        .padding(20)
        .background(Theme.background)
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch state.importState {
        case .idle:
            Text("No import has been executed in this session.")
                .foregroundStyle(Theme.textSecondary)
        case .running:
            Text("Import in progress...")
                .foregroundStyle(Theme.accent)
        case .success(let summary):
            Text("Completed in \(summary.durationMs) ms.")
                .foregroundStyle(Theme.success)
        case .failure(let message):
            Text(message)
                .foregroundStyle(Theme.error)
        }
    }
}
