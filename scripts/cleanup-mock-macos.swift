import AppKit
import Foundation
import Security

// External cleanup is restricted to the exact randomly assigned run namespace.
guard CommandLine.arguments.count == 2 else {
  fputs("Expected this helper's Mock Mail Session identifier\n", stderr)
  exit(EXIT_FAILURE)
}
let identifier = CommandLine.arguments[1]
guard identifier == Bundle.main.bundleIdentifier,
  identifier.range(of: #"^dev\.unwired\.mock\.[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
  fputs("Refusing cleanup outside a Mock Mail Session\n", stderr)
  exit(EXIT_FAILURE)
}
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
  $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}
for application in applications { application.forceTerminate() }
for _ in 0..<50 {
  if applications.allSatisfy({ $0.isTerminated }) { break }
  Thread.sleep(forTimeInterval: 0.1)
}
guard applications.allSatisfy({ $0.isTerminated }) else { fatalError("Mock app did not terminate") }
let status = SecItemDelete([
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: identifier + ".private-inbox.database",
  kSecAttrAccount as String: "encryption-key",
  kSecAttrSynchronizable as String: false,
  kSecUseDataProtectionKeychain as String: true,
] as CFDictionary)
guard status == errSecSuccess || status == errSecItemNotFound else {
  fatalError("Mock Keychain cleanup failed: \(status)")
}
let support = try FileManager.default.url(for: .applicationSupportDirectory,
  in: .userDomainMask, appropriateFor: nil, create: false)
let directory = support.appendingPathComponent(identifier)
if FileManager.default.fileExists(atPath: directory.path) {
  try FileManager.default.removeItem(at: directory)
}
