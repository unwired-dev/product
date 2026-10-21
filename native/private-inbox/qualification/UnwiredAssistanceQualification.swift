import Foundation
import React

// Compiled only into the `assistance-qualification` build (#625). It names the device a corpus run
// uses and appends the run's synthetic evidence to the app's temporary directory; it reads no mail.
@objc(UnwiredAssistanceQualification)
final class UnwiredAssistanceQualification: NSObject {
  private static let evidence = FileManager.default.temporaryDirectory.appending(
    path: "assistance-qualification.jsonl")

  @objc static func requiresMainQueueSetup() -> Bool { false }

  // The public hardware identifier: `Mac16,10` on a Mac, `iPad16,5` or `iPhone18,2` on mobile.
  private static func hardware() -> String {
    #if os(macOS)
      let name = "hw.model"
    #else
      let name = "hw.machine"
    #endif
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var value = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &value, &size, nil, 0)
    return String(cString: value)
  }

  // Starts a new evidence file and describes this device, without any identifier of it.
  @objc(begin:rejecter:)
  func begin(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock)
  {
    do {
      try Data().write(to: Self.evidence)
      resolve([
        "hardware": Self.hardware(),
        "system": ProcessInfo.processInfo.operatingSystemVersionString,
        "locale": Locale.current.identifier,
        "languages": Locale.preferredLanguages,
        "commit": Bundle.main.object(forInfoDictionaryKey: "UnwiredCommit") as? String ?? "",
      ])
    } catch {
      reject("unavailable", "The evidence file could not be created.", nil)
    }
  }

  @objc(record:resolver:rejecter:)
  func record(
    _ line: String, resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    do {
      let file = try FileHandle(forWritingTo: Self.evidence)
      defer { try? file.close() }
      try file.seekToEnd()
      try file.write(contentsOf: Data((line + "\n").utf8))
      resolve(nil)
    } catch {
      reject("unavailable", "The evidence could not be recorded.", nil)
    }
  }
}
