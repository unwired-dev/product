import SwiftUI

/// Displays authored Draft assets with conversion and removal actions.
struct MailComposerAssetList: View {
  let assets: [MailDraftAsset]
  let remove: (UUID) -> Void
  let toggleDisposition: (UUID) -> Void

  var body: some View {
    if !assets.isEmpty {
      VStack(spacing: 0) {
        ForEach(assets) { asset in
          HStack(spacing: 12) {
            Image(systemName: asset.disposition == .inline ? "photo" : "paperclip")
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
              Text(asset.filename)
                .lineLimit(1)
              Text(asset.byteCount.formatted(.byteCount(style: .file)))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !asset.isComplete {
              Label("Pending", systemImage: "icloud.and.arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Menu("Attachment Actions", systemImage: "ellipsis.circle") {
              Button(
                asset.disposition == .inline ? "Make Attachment" : "Place Inline",
                systemImage: asset.disposition == .inline ? "paperclip" : "photo",
                action: { toggleDisposition(asset.id) }
              )
              Button("Remove Attachment", systemImage: "trash", role: .destructive) {
                remove(asset.id)
              }
            }
            .labelStyle(.iconOnly)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(asset.filename), \(asset.disposition == .inline ? "inline image" : "attachment")"
          )
          if asset.id != assets.last?.id {
            Divider().padding(.leading, 16)
          }
        }
      }
      .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
  }
}
