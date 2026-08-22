import Foundation

/// Loads supported values from one Share Extension request.
@MainActor
protocol ShareExtensionInputLoading {
  func loadInputs() async throws -> [ShareExtensionInput]
}

#if canImport(UIKit)
  import UniformTypeIdentifiers
  import UIKit

  /// Reads host-provided item providers without retaining their temporary files.
  @MainActor
  struct SystemShareExtensionInputLoader: ShareExtensionInputLoading {
    static let maximumSingleItemByteCount = 24 * 1_024 * 1_024

    private let extensionItems: [NSExtensionItem]

    /// Creates a loader for the current extension context.
    init(extensionItems: [NSExtensionItem]) {
      self.extensionItems = extensionItems
    }

    func loadInputs() async throws -> [ShareExtensionInput] {
      var inputs: [ShareExtensionInput] = []
      for extensionItem in extensionItems {
        for provider in extensionItem.attachments ?? [] {
          try Task.checkCancellation()
          inputs.append(try await loadInput(from: provider))
        }
      }
      guard !inputs.isEmpty else { throw ShareExtensionInputError.emptyRequest }
      let totalByteCount = inputs.reduce(0) { total, input in
        switch input {
        case .file(let data, _, _), .image(let data, _, _): total + data.count
        case .link(let url): total + url.absoluteString.utf8.count
        case .text(let text): total + text.utf8.count
        }
      }
      guard totalByteCount <= ShareExtensionDraftPayload.maximumInputByteCount else {
        throw ShareExtensionInputError.totalSizeExceeded
      }
      return inputs
    }

    private func loadInput(from provider: NSItemProvider) async throws -> ShareExtensionInput {
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        return .link(try await loadURL(from: provider))
      }
      if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        return .text(try await loadText(from: provider))
      }
      if let type = supportedType(from: provider, conformingTo: .image) {
        let loaded = try await loadFile(from: provider, type: type)
        return .image(data: loaded.data, filename: loaded.filename, mediaType: type.mailMIMEType)
      }
      if let type = supportedType(from: provider, conformingTo: .data) {
        let loaded = try await loadFile(from: provider, type: type)
        return .file(data: loaded.data, filename: loaded.filename, mediaType: type.mailMIMEType)
      }
      throw ShareExtensionInputError.unsupportedItem
    }

    private func supportedType(
      from provider: NSItemProvider,
      conformingTo parent: UTType
    ) -> UTType? {
      provider.registeredTypeIdentifiers.compactMap(UTType.init).first {
        $0.conforms(to: parent)
      }
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL {
      return try await withCheckedThrowingContinuation { continuation in
        provider.loadObject(ofClass: NSURL.self) { object, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let url = object as? URL {
            continuation.resume(returning: url)
          } else {
            continuation.resume(throwing: ShareExtensionInputError.unsupportedItem)
          }
        }
      }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String {
      try await withCheckedThrowingContinuation { continuation in
        provider.loadObject(ofClass: NSString.self) { object, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let text = object as? String {
            continuation.resume(returning: text)
          } else {
            continuation.resume(throwing: ShareExtensionInputError.unsupportedItem)
          }
        }
      }
    }

    private func loadFile(
      from provider: NSItemProvider,
      type: UTType
    ) async throws -> (data: Data, filename: String) {
      let maximumByteCount = Self.maximumSingleItemByteCount
      let suggestedName = provider.suggestedName
      return try await withCheckedThrowingContinuation { continuation in
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          guard let url else {
            continuation.resume(throwing: ShareExtensionInputError.unsupportedItem)
            return
          }
          do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            let filename = values.name ?? suggestedName ?? "Shared File"
            guard values.fileSize ?? 0 <= maximumByteCount else {
              throw ShareExtensionInputError.itemTooLarge(filename: filename)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumByteCount else {
              throw ShareExtensionInputError.itemTooLarge(filename: filename)
            }
            continuation.resume(returning: (data, filename))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  extension UTType {
    fileprivate var mailMIMEType: String {
      preferredMIMEType ?? "application/octet-stream"
    }
  }
#endif
