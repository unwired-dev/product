// Appended to the real bridge source by picker.zsh so its private intake helpers can be exercised.
// This checks file/type intake with real Foundation/ImageIO; it does not open a picker or qualify
// sandbox grants, iOS protection, encrypted import or the visible composer.
import Darwin
import ImageIO

@main struct DraftFilePickerTests {
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j7yoAAAAASUVORK5CYII="
    )!
    let image = CGImageSourceCreateWithData(png as CFData, nil)!
    precondition(CGImageSourceCreateImageAtIndex(image, 0, nil) != nil)
    let extensionless = root.appendingPathComponent("extensionless")
    try png.write(to: extensionless)
    guard pickedFile(extensionless)["type"] == "image/png" else {
      print("Extensionless image MIME regression failed")
      exit(1)
    }
    precondition(pickedFile(extensionless)["name"] == "extensionless")
    precondition(pickedFile(extensionless, type: .image)["type"] == "image/png")
    // A provider's concrete declaration wins even when the URL's bytes/name differ or are absent.
    precondition(pickedFile(extensionless, type: .jpeg)["type"] == "image/jpeg")
    let absent = root.appendingPathComponent("absent.png")
    precondition(pickedFile(absent, type: .jpeg)["type"] == "image/jpeg")
    precondition(pickedFile(absent)["type"] == "image/png")
    let renamed = root.appendingPathComponent("renamed")
    try FileManager.default.copyItem(at: extensionless, to: renamed)
    precondition(pickedFile(renamed, name: "suggested.name")["type"] == "image/png")
    precondition(pickedFile(renamed, name: "suggested.name")["name"] == "suggested.name")
    let moved = root.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: renamed, to: moved)
    precondition(pickedFile(moved)["type"] == "image/png")
    let unknown = root.appendingPathComponent("unknown")
    try Data("ordinary file".utf8).write(to: unknown)
    precondition(pickedFile(unknown)["type"] == "")
    let missing = root.appendingPathComponent("missing")
    precondition(pickedFile(missing)["type"] == "")
    let fifo = root.appendingPathComponent("fifo")
    precondition(mkfifo(fifo.path, 0o600) == 0)
    precondition(pickedFile(fifo)["type"] == "")
    let oversized = root.appendingPathComponent("oversized")
    try png.write(to: oversized)
    let file = try FileHandle(forWritingTo: oversized)
    try file.truncate(atOffset: UInt64(PrivateInboxStore.draftAssetLimit + 1))
    try file.close()
    precondition(isOversized(oversized))
    let result = oversizedFile(oversized, name: "oversized")
    precondition(result["type"] == "image/png")
    precondition(result["oversized"] == "true" && result["uri"] == nil)
    let original = try Data(contentsOf: extensionless)
    precondition(original == png)
    print("Draft picker MIME regression passed")
  }
}
