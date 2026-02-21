import AppKit
import SwiftUI

struct ImportView: View {
    @ObservedObject var state: AppState
    @State private var databasePathInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import Workspace")
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)

                Text("Native PGN import flow backed by the Rust engine.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Import Games")
                        .font(Typography.sectionTitle)

                    Text("Choose target database, select PGN files, then run import.")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Target Database")
                            .font(Typography.detailLabel)
                            .foregroundStyle(Theme.textSecondary)

                        HStack(spacing: 10) {
                            if state.workspaceDatabases.isEmpty {
                                Text("Register a database first")
                                    .font(Typography.body)
                                    .foregroundStyle(Theme.error)
                            } else {
                                Picker(
                                    "Import Target",
                                    selection: Binding(
                                        get: { state.selectedImportDatabaseID },
                                        set: { state.selectedImportDatabaseID = $0 }
                                    )
                                ) {
                                    ForEach(state.workspaceDatabases) { database in
                                        Text(database.label).tag(Optional(database.id))
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            Spacer(minLength: 0)
                        }

                        if let target = state.selectedImportDatabase {
                            Text(target.path)
                                .font(Typography.dataMono)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. PGN Files")
                            .font(Typography.detailLabel)
                            .foregroundStyle(Theme.textSecondary)

                        if state.selectedPgnPaths.isEmpty {
                            Text("No files selected")
                                .font(Typography.body)
                                .foregroundStyle(Theme.textSecondary)
                        } else if state.selectedPgnPaths.count == 1 {
                            Text(state.selectedPgnPaths[0])
                                .font(Typography.dataMono)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        } else {
                            Text("\(state.selectedPgnPaths.count) files selected")
                                .font(Typography.body)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        HStack(spacing: 10) {
                            Button("Select PGN File(s)") {
                                selectPgnPaths()
                            }
                            .buttonStyle(.bordered)

                            Button("Clear Selection") {
                                clearPgnSelection()
                            }
                            .buttonStyle(.bordered)
                            .disabled(state.selectedPgnPaths.isEmpty)

                            Button("Run Import") {
                                Task {
                                    await state.startImport()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.selectedImportDatabase == nil || state.selectedPgnPaths.isEmpty)
                        }

                        if state.isImportRunning {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Importing...")
                                    .font(Typography.detailLabel)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .panelCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Database Registry")
                        .font(Typography.sectionTitle)

                    TextField("Path to SQLite database", text: $databasePathInput)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button("Register Path") {
                            state.registerDatabase(path: databasePathInput)
                            databasePathInput = ""
                        }
                        .buttonStyle(.bordered)

                        Button("Select Database File") {
                            selectDatabasePath()
                        }
                        .buttonStyle(.bordered)
                    }

                    if let workspaceError = state.workspaceError {
                        Text(workspaceError)
                            .font(Typography.body)
                            .foregroundStyle(Theme.error)
                    }
                }
                .panelCard()
            }
            .padding(24)
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .environment(\.colorScheme, .light)
        .background(Theme.background)
    }

    private func clearPgnSelection() {
        state.selectedPgnPaths = []
        state.pgnPath = ""
    }

    private func selectPgnPaths() {
        let panel = NSOpenPanel()
        panel.title = "Select PGN File(s)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["pgn", "zst"]

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
            state.registerDatabase(path: url.path(percentEncoded: false))
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

            if state.isImportRunning {
                ProgressView()
                    .tint(Theme.accent)
            } else {
                ProgressView(value: state.importProgress.completion)
                    .tint(Theme.accent)
            }

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
                GridRow {
                    Text("Errors")
                        .font(Typography.detailLabel)
                    Text("\(state.importProgress.errors)")
                        .font(Typography.dataMono)
                        .foregroundStyle(Theme.textSecondary)
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
