import Foundation
import UniformTypeIdentifiers

// The system's own ways to choose files for a Draft. Each resolves `[{ uri, name, type }]`, or an
// empty list when the person chooses nothing. iPhone and iPad copy the chosen files into a
// temporary folder that import or the next launch removes; a Mac file stays where it is and is
// read through the open panel's grant.
// One pick adds at most this many files, as TypeScript's `pickLimit`, so a huge selection is
// never copied or listed.
private let pickLimit = 20

// The MIME type comes from the type the source declared when it has one, then the extension.
private func pickedFile(_ url: URL, name: String? = nil, type declared: UTType? = nil)
  -> [String: String]
{
  let type =
    declared?.preferredMIMEType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    ?? ""
  return ["uri": url.absoluteString, "name": name ?? url.lastPathComponent, "type": type]
}

#if os(iOS)
  import PhotosUI
  import UIKit

  @MainActor enum DraftFilePicker {
    private static var active: (any NSObjectProtocol)?

    static func pick(_ source: String) async throws -> [[String: String]] {
      switch source {
      case "paste": return try await pasted()
      case "photos", "files": break
      default: throw RegistrationError.unavailable
      }
      guard
        active == nil,
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
          configuration.selectionLimit = pickLimit
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
        at: folder, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
      let safe = PrivateInboxStore.attachmentName(name)
      return folder.appendingPathComponent(safe)
    }

    // Images on the pasteboard, copied as files. Item providers load lazily, so only the first
    // `pickLimit` images are ever decoded or copied, however many the pasteboard holds.
    private static func pasted() async throws -> [[String: String]] {
      let providers = UIPasteboard.general.itemProviders.lazy
        .filter { $0.registeredContentTypes.contains { $0.conforms(to: .image) } }
        .prefix(pickLimit)
      var files: [[String: String]] = []
      do {
        for provider in providers {
          files.append(try await PhotoDelegate.copy(provider))
        }
        return files
      } catch {
        for file in files {
          if let uri = file["uri"], let url = URL(string: uri) {
            RegistrationStore.discardPickedDraftFile(url)
          }
        }
        throw error
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
        var files: [[String: String]] = []
        do {
          for result in results {
            files.append(try await Self.copy(result.itemProvider))
          }
          finish(.success(files))
        } catch {
          // Copies from earlier selections in a failed batch are no longer needed.
          for file in files {
            if let uri = file["uri"], let url = URL(string: uri) {
              RegistrationStore.discardPickedDraftFile(url)
            }
          }
          finish(.failure(error))
        }
      }
    }

    // The provider's file exists only during its callback, so it is copied there.
    static func copy(_ provider: NSItemProvider) async throws -> [String: String] {
      let type =
        provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? UTType.image
      return try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
          do {
            guard let url else { throw error ?? RegistrationError.unavailable }
            // A name without an extension takes the provided image type's usual one.
            let fileExtension =
              url.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "" : url.pathExtension
            let base = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
            let name =
              fileExtension.isEmpty || !URL(fileURLWithPath: base).pathExtension.isEmpty
              ? base : "\(base).\(fileExtension)"
            let target = try DraftFilePicker.destination(name)
            do {
              try FileManager.default.copyItem(at: url, to: target)
            } catch {
              RegistrationStore.discardPickedDraftFile(target)
              throw error
            }
            continuation.resume(returning: pickedFile(target, name: name, type: type))
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

    func documentPicker(
      _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
      MainActor.assumeIsolated {
        var files: [[String: String]] = []
        finish(
          Result {
            do {
              // The system already copied the selection; copies past the limit are removed.
              for url in urls.dropFirst(pickLimit) {
                try? FileManager.default.removeItem(at: url)
              }
              for url in urls.prefix(pickLimit) {
                let target = try DraftFilePicker.destination(url.lastPathComponent)
                do {
                  try FileManager.default.moveItem(at: url, to: target)
                } catch {
                  RegistrationStore.discardPickedDraftFile(target)
                  throw error
                }
                files.append(pickedFile(target, name: url.lastPathComponent))
              }
              return files
            } catch {
              for file in files {
                if let uri = file["uri"], let url = URL(string: uri) {
                  RegistrationStore.discardPickedDraftFile(url)
                }
              }
              throw error
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
      return panel.urls.prefix(pickLimit).map { pickedFile($0) }
    }
  }
#endif
