import Foundation
import UniformTypeIdentifiers

// The system's own ways to choose files for a Draft. Each resolves `[{ uri, name, type }]`, or an
// empty list when the person chooses nothing. iPhone and iPad copy the chosen files into a
// temporary folder that import or the next launch removes; a Mac file stays where it is and is
// read through the open panel's grant.
private func pickedFile(_ url: URL, name: String? = nil) -> [String: String] {
  let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
  return ["uri": url.absoluteString, "name": name ?? url.lastPathComponent, "type": type]
}

#if os(iOS)
  import PhotosUI
  import UIKit

  @MainActor enum DraftFilePicker {
    private static var active: (any NSObjectProtocol)?

    static func pick(_ source: String) async throws -> [[String: String]] {
      switch source {
      case "paste": return try pasted()
      case "photos", "files": break
      default: throw RegistrationError.unavailable
      }
      guard
        let presenter = topController(),
        !presenter.isBeingPresented, !presenter.isBeingDismissed
      else { throw RegistrationError.unavailable }
      return try await withCheckedThrowingContinuation { continuation in
        let finish: @MainActor (Result<[[String: String]], any Error>) -> Void = { result in
          active = nil
          continuation.resume(with: result)
        }
        if source == "photos" {
          var configuration = PHPickerConfiguration()
          configuration.filter = .images
          configuration.selectionLimit = 0
          let picker = PHPickerViewController(configuration: configuration)
          let delegate = PhotoDelegate(finish: finish)
          picker.delegate = delegate
          active = delegate
          presenter.present(picker, animated: true)
        } else {
          let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
          picker.allowsMultipleSelection = true
          let delegate = DocumentDelegate(finish: finish)
          picker.delegate = delegate
          active = delegate
          presenter.present(picker, animated: true)
        }
      }
    }

    // A folder of its own per file, so names never collide.
    nonisolated static func destination(_ name: String) throws -> URL {
      let folder = RegistrationStore.pickedDraftFiles.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let safe = PrivateInboxStore.attachmentName(name)
      return folder.appendingPathComponent(safe)
    }

    // Images on the pasteboard, as PNG files.
    private static func pasted() throws -> [[String: String]] {
      try (UIPasteboard.general.images ?? []).enumerated().compactMap { index, image in
        guard let data = image.pngData() else { return nil }
        let url = try destination(index == 0 ? "Pasted image.png" : "Pasted image \(index + 1).png")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return pickedFile(url)
      }
    }

    private static func topController() -> UIViewController? {
      var controller = AttachmentPresenter.origin().window?.rootViewController
      while let presented = controller?.presentedViewController { controller = presented }
      return controller
    }
  }

  private final class PhotoDelegate: NSObject, PHPickerViewControllerDelegate {
    let finish: @MainActor (Result<[[String: String]], any Error>) -> Void
    init(finish: @escaping @MainActor (Result<[[String: String]], any Error>) -> Void) {
      self.finish = finish
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      picker.dismiss(animated: true)
      let finish = self.finish
      Task { @MainActor in
        do {
          var files: [[String: String]] = []
          for result in results {
            files.append(try await Self.copy(result.itemProvider))
          }
          finish(.success(files))
        } catch {
          finish(.failure(error))
        }
      }
    }

    // The provider's file exists only during its callback, so it is copied there.
    private static func copy(_ provider: NSItemProvider) async throws -> [String: String] {
      let type =
        provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? UTType.image
      return try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
          do {
            guard let url else { throw error ?? RegistrationError.unavailable }
            let name =
              provider.suggestedName.map {
                url.pathExtension.isEmpty ? $0 : "\($0).\(url.pathExtension)"
              } ?? url.lastPathComponent
            let target = try DraftFilePicker.destination(name)
            try FileManager.default.copyItem(at: url, to: target)
            continuation.resume(returning: pickedFile(target, name: name))
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  private final class DocumentDelegate: NSObject, UIDocumentPickerDelegate {
    let finish: @MainActor (Result<[[String: String]], any Error>) -> Void
    init(finish: @escaping @MainActor (Result<[[String: String]], any Error>) -> Void) {
      self.finish = finish
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
      MainActor.assumeIsolated {
        finish(
          Result {
            try urls.map { url in
              let target = try DraftFilePicker.destination(url.lastPathComponent)
              try FileManager.default.moveItem(at: url, to: target)
              return pickedFile(target, name: url.lastPathComponent)
            }
          })
      }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      MainActor.assumeIsolated { finish(.success([])) }
    }
  }
#elseif os(macOS)
  import AppKit

  @MainActor enum DraftFilePicker {
    // Pasting and dropping go through the composer's own text view on Mac.
    static func pick(_ source: String) async throws -> [[String: String]] {
      guard source == "photos" || source == "files" else { throw RegistrationError.unavailable }
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = true
      if source == "photos" { panel.allowedContentTypes = [.image] }
      let response: NSApplication.ModalResponse
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        response = await panel.beginSheetModal(for: window)
      } else {
        response = panel.runModal()
      }
      guard response == .OK else { return [] }
      return panel.urls.map { pickedFile($0) }
    }
  }
#endif
