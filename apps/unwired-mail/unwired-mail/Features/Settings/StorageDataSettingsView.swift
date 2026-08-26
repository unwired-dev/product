import SwiftUI
import UniformTypeIdentifiers

struct StorageDataSettingsView: View {
  let session: ProductAccountSessionSnapshot?
  let viewModel: StorageDataSettingsViewModel

  @State private var confirmsClear = false
  @State private var confirmsClearRemoteContent = false
  @State private var isFileExporterPresented = false

  var body: some View {
    Form {
      if let loadErrorMessage = viewModel.loadErrorMessage {
        Section {
          SettingsInlineErrorView(
            message: loadErrorMessage,
            isRetrying: viewModel.isLoading
          ) {
            Task { await viewModel.refresh() }
          }
        }
      }

      StorageOverviewSection(viewModel: viewModel)
      DraftStorageSection(snapshot: viewModel.snapshot)
      ClearStorageSection(confirmsClear: $confirmsClear, viewModel: viewModel)
      ClearRemoteContentSection(
        confirmsClear: $confirmsClearRemoteContent,
        viewModel: viewModel
      )
      if let session {
        ProductSyncExportSection(session: session, viewModel: viewModel)
        ReadReceiptStorageSection(summary: viewModel.readReceiptSummary)
      }

      if let statusMessage = viewModel.statusMessage {
        Section {
          Label(statusMessage, systemImage: "checkmark.circle")
        }
      }
    }
    .navigationTitle(session == nil ? "Device Storage" : "Storage & Export")
    .task(id: ObjectIdentifier(viewModel)) {
      await viewModel.refresh()
    }
    .onDisappear {
      viewModel.cancelExport()
    }
    .onChange(of: viewModel.exportData) { _, data in
      isFileExporterPresented = data != nil
    }
    .confirmationDialog(
      "Clear cached bodies and attachments?",
      isPresented: $confirmsClear,
      titleVisibility: .visible
    ) {
      Button("Clear Local Copies", role: .destructive) {
        Task { await viewModel.clearCaches() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        """
        Provider mail, Product-owned Categories, Thread Pins, Draft documents, Draft Assets, and Product \
        Sync records will remain.
        """
      )
    }
    .confirmationDialog(
      "Clear authorized remote content?",
      isPresented: $confirmsClearRemoteContent,
      titleVisibility: .visible
    ) {
      Button("Clear Remote Content", role: .destructive) {
        Task { await viewModel.clearRemoteContent() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Previously authorized remote images will need to be downloaded again. Provider mail is not deleted."
      )
    }
    .alert(
      session == nil ? "Device Storage unavailable" : "Storage & Export unavailable",
      isPresented: Binding(
        get: { viewModel.alertMessage != nil },
        set: { isPresented in
          if !isPresented { viewModel.clearAlert() }
        }
      )
    ) {
      Button("OK") { viewModel.clearAlert() }
    } message: {
      Text(verbatim: viewModel.alertMessage ?? "")
    }
    .fileExporter(
      isPresented: $isFileExporterPresented,
      document: ProductSyncExportFile(data: viewModel.exportData ?? Data()),
      contentType: .json,
      defaultFilename: "Unwired Product Sync Export"
    ) { result in
      if case .failure(let error) = result {
        viewModel.presentFileExportError(error)
      }
      viewModel.finishExport()
    }
  }
}

private struct StorageOverviewSection: View {
  let viewModel: StorageDataSettingsViewModel

  var body: some View {
    Section {
      if let snapshot = viewModel.snapshot {
        LabeledContent("Mail metadata", value: formattedByteCount(snapshot.metadataByteCount))
        LabeledContent("Cached bodies", value: formattedByteCount(snapshot.cachedBodyByteCount))
        LabeledContent("Complete Drafts", value: formattedByteCount(snapshot.draftByteCount))
        LabeledContent(
          "Downloaded attachments",
          value: formattedByteCount(snapshot.downloadedAttachmentByteCount)
        )
        LabeledContent(
          "Authorized remote content",
          value: formattedByteCount(snapshot.remoteContentByteCount)
        )
        LabeledContent("Total", value: formattedByteCount(snapshot.totalByteCount))
      } else if viewModel.isLoading {
        ProgressView("Inspecting storage…")
      } else {
        Button("Inspect Storage") {
          Task { await viewModel.refresh() }
        }
      }
    } header: {
      Text("Device Storage")
    } footer: {
      Text(
        """
        Mail metadata and complete Drafts are durable local data. Cached bodies and downloaded \
        incoming attachments and authorized remote content can be downloaded again.
        """
      )
    }
  }
}

private struct ClearRemoteContentSection: View {
  @Binding var confirmsClear: Bool
  let viewModel: StorageDataSettingsViewModel

  var body: some View {
    Section {
      Button("Clear Remote Content", role: .destructive) {
        confirmsClear = true
      }
      .disabled(viewModel.isClearingRemoteContent)
      if viewModel.isClearingRemoteContent {
        ProgressView("Clearing remote content…")
      }
    } footer: {
      Text("This removes only authorized remote images stored on this device.")
    }
  }
}

private struct DraftStorageSection: View {
  let snapshot: LocalMailStorageSnapshot?

  var body: some View {
    Section {
      LabeledContent(
        "Device-wide limit",
        value: formattedByteCount(Int64(LocalMailStorageSnapshot.draftStorageLimit))
      )
      if let snapshot {
        if snapshot.pendingDraftAssetCount == 0 {
          Label("All synchronized Draft Assets are available", systemImage: "checkmark.circle")
        } else {
          Label(pendingAssetLabel(snapshot.pendingDraftAssetCount), systemImage: "clock")
          LabeledContent(
            "Pending asset content",
            value: formattedByteCount(snapshot.pendingDraftAssetByteCount)
          )
        }
      }
    } header: {
      Text("Draft Storage")
    } footer: {
      Text(
        """
        Drafts and authored assets are never evicted automatically. If the 100 MB store is full, \
        synchronized asset content stays encrypted in Product Sync until space is available.
        """
      )
    }
  }

  private func pendingAssetLabel(_ count: Int) -> String {
    count == 1
      ? "1 Draft Asset pending local storage" : "\(count) Draft Assets pending local storage"
  }
}

private struct ClearStorageSection: View {
  @Binding var confirmsClear: Bool
  let viewModel: StorageDataSettingsViewModel

  var body: some View {
    Section {
      Button("Clear Cached Bodies & Attachments", role: .destructive) {
        confirmsClear = true
      }
      .disabled(viewModel.isClearing)
      if viewModel.isClearing {
        ProgressView("Clearing local copies…")
      }
    } footer: {
      Text(
        """
        This keeps provider mail, Message Categories, Thread Pins, Draft documents, Draft Assets, \
        and Product Sync records.
        """
      )
    }
  }
}

private struct ProductSyncExportSection: View {
  let session: ProductAccountSessionSnapshot
  let viewModel: StorageDataSettingsViewModel

  @Environment(SettingsRouter.self) private var settingsRouter

  var body: some View {
    Section {
      Text(
        """
        Product Sync records are end-to-end encrypted. Export decrypts them only on this Trusted \
        Device and never sends plaintext to the product backend.
        """
      )
      Button("Export Product Sync Data", systemImage: "square.and.arrow.up") {
        viewModel.startExport(session: session)
      }
      .disabled(viewModel.isExporting)
      if viewModel.isExporting {
        Button("Cancel Export", role: .cancel) {
          viewModel.cancelExport()
        }
        ProgressView("Preparing export…")
      }
      Button("Manage Recovery Key") {
        settingsRouter.open(SettingsDestination.accountAndDevices.route)
      }
      Text("Message content is never sent to the product backend for AI processing.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } header: {
      Text("Product Sync Export")
    } footer: {
      Text(
        """
        The JSON export preserves Mail Profile identities and ownership, multi-category membership, \
        Thread Pins, semantic Draft documents, and Draft-asset metadata and content. Provider \
        credentials are excluded.
        """
      )
    }
  }
}

private struct ReadReceiptStorageSection: View {
  let summary: String

  @Environment(SettingsRouter.self) private var settingsRouter

  var body: some View {
    Section("Read Receipts") {
      Text(verbatim: summary)
      Button("Review Read Receipt Settings") {
        settingsRouter.open(.readReceipt(connectionId: nil, field: .incoming))
      }
    }
  }
}

private func formattedByteCount(_ byteCount: Int64) -> String {
  ByteCountFormatStyle(style: .file).format(byteCount)
}

private struct ProductSyncExportFile: FileDocument {
  static let readableContentTypes: [UTType] = [.json]

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
