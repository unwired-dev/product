import SwiftUI

struct UnderstandingAssistanceView: View {
  @Bindable var viewModel: MailAssistanceViewModel
  let currentInputVersion: MailAssistanceInputVersion
  let localErrorMessage: String?
  let regenerate: () -> Void
  let showSource: (String) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Group {
        if viewModel.phase == .generating {
          ProgressView("Analyzing local messages…")
            .accessibilityLabel("Analyzing local messages")
        } else if let localErrorMessage {
          unavailableContent(message: localErrorMessage)
        } else if let errorMessage = viewModel.errorMessage {
          unavailableContent(message: errorMessage)
        } else if let preview = viewModel.preview {
          previewContent(preview)
        } else {
          unavailableContent(message: viewModel.statusMessage)
        }
      }
      .navigationTitle("Understanding Assistance")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", action: dismiss.callAsFunction)
        }
      }
    }
  }

  @ViewBuilder
  private func previewContent(_ preview: MailAssistancePreview) -> some View {
    if preview.applicationStatus(
      profileId: viewModel.activeProfileId,
      inputVersion: currentInputVersion
    ) == .stale {
      ContentUnavailableView {
        Label("Thread changed", systemImage: "arrow.clockwise")
      } description: {
        Text("Regenerate before relying on this assistance output.")
      } actions: {
        Button("Regenerate", action: regenerate)
          .buttonStyle(.borderedProminent)
      }
    } else if preview.kind == .clarification {
      ContentUnavailableView {
        Label("More detail needed", systemImage: "questionmark.bubble")
      } description: {
        Text(preview.content)
      } actions: {
        Button("Regenerate", action: regenerate)
          .buttonStyle(.borderedProminent)
      }
    } else if let result = preview.understanding {
      resultContent(result)
    } else {
      unavailableContent(message: "No source-linked result was produced.")
    }
  }

  private func resultContent(_ result: UnderstandingAssistanceResult) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Label("Assistance output", systemImage: "sparkles")
            .font(.headline)
          Text("Verify each item against its linked local message.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        ForEach(UnderstandingAssistanceItemKind.allCases, id: \.self) { kind in
          let items = result.items.filter { $0.kind == kind }
          if !items.isEmpty {
            itemSection(kind: kind, items: items, scope: result.scope)
          }
        }

        analyzedSources(result.scope)
      }
      .padding(16)
    }
  }

  private func itemSection(
    kind: UnderstandingAssistanceItemKind,
    items: [UnderstandingAssistanceItem],
    scope: UnderstandingAssistanceScope
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(sectionTitle(for: kind), systemImage: sectionImage(for: kind))
        .font(.headline)
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 8) {
          Text(item.text)
          if item.kind == .action {
            LabeledContent("Responsible", value: item.responsibilityDescription)
              .font(.subheadline)
          }
          if let uncertainty = item.uncertainty {
            Label(uncertainty, systemImage: "exclamationmark.circle")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          ForEach(item.sourceMessageIds, id: \.self) { sourceMessageId in
            if let source = scope.includedSources.first(where: {
              $0.messageId == sourceMessageId
            }) {
              sourceButton(source)
            }
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
      }
    }
  }

  private func sourceButton(_ source: UnderstandingAssistanceSource) -> some View {
    Button {
      showSource(source.messageId)
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 4) {
          Text(source.senderDisplayName ?? "Unknown sender")
          Text(
            Date(
              timeIntervalSince1970: TimeInterval(source.sentAtMilliseconds) / 1_000
            ),
            format: .dateTime.day().month().year().hour().minute()
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "arrow.up.message")
      }
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(source.accessibilityLabel)
  }

  private func analyzedSources(_ scope: UnderstandingAssistanceScope) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Analyzed Sources")
        .font(.headline)
      Text("Analyzed \(scope.includedSources.count) of \(scope.totalThreadMessageCount) messages.")
        .font(.subheadline)
      ForEach(scope.includedSources) { source in
        VStack(alignment: .leading, spacing: 4) {
          Text(source.senderDisplayName ?? "Unknown sender")
          Text(
            "\(source.includedCharacterCount) of \(source.availableCharacterCount) local body characters"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      if scope.unavailableLocalMessageCount > 0 {
        Text(
          "\(scope.unavailableLocalMessageCount) message bodies were not available locally and were not fetched."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
      if scope.omittedForLimitMessageCount > 0 {
        Text(
          "\(scope.omittedForLimitMessageCount) older local messages were outside the deterministic limit."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
      if scope.hasOmittedContent {
        Text("This result does not cover the full Thread.")
          .font(.subheadline)
          .bold()
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 10))
  }

  private func unavailableContent(message: String) -> some View {
    ContentUnavailableView {
      Label("Understanding unavailable", systemImage: "sparkles")
    } description: {
      Text(message)
    } actions: {
      Button("Try Again", action: regenerate)
        .buttonStyle(.borderedProminent)
    }
  }

  private func sectionTitle(for kind: UnderstandingAssistanceItemKind) -> String {
    switch kind {
    case .action:
      "Actions"
    case .inferredDate:
      "Inferred Dates"
    case .openQuestion:
      "Open Questions"
    case .statedDate:
      "Stated Dates"
    case .statedDeadline:
      "Stated Deadlines"
    case .summary:
      "Summary"
    }
  }

  private func sectionImage(for kind: UnderstandingAssistanceItemKind) -> String {
    switch kind {
    case .action:
      "checkmark.circle"
    case .inferredDate:
      "calendar.badge.questionmark"
    case .openQuestion:
      "questionmark.bubble"
    case .statedDate:
      "calendar"
    case .statedDeadline:
      "calendar.badge.clock"
    case .summary:
      "text.justify.left"
    }
  }
}
