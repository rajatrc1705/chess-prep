import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @ObservedObject var state: AppState

    @State private var showPgnPicker = false
    @State private var showDbPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import Workspace")
                    .font(Typography.title)
                    .foregroundStyle(Theme.textPrimary)

                Text("Scaffolded flow for PGN ingestion. This view currently runs a mock import adapter and is ready for backend binding.")
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
                        showDbPicker = true
                    }
                    .buttonStyle(.bordered)
                }
                .panelCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("PGN Source")
                        .font(Typography.sectionTitle)

                    TextField(
                        "Path to PGN file",
                        text: $state.pgnPath
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Select PGN File") {
                        showPgnPicker = true
                    }
                    .buttonStyle(.bordered)
                }
                .panelCard()

                HStack(spacing: 12) {
                    Button("Run Import") {
                        Task {
                            await state.startImport()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isImportRunning)

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
        .fileImporter(
            isPresented: $showPgnPicker,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                state.pgnPath = urls.first?.path(percentEncoded: false) ?? ""
            case .failure:
                break
            }
        }
        .fileImporter(
            isPresented: $showDbPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                state.databasePath = urls.first?.path(percentEncoded: false) ?? ""
            case .failure:
                break
            }
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
