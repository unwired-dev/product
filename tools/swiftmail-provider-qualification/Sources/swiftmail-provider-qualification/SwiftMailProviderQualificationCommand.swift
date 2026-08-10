import Darwin
import Foundation
import SwiftMailProviderQualification

@main
struct SwiftMailProviderQualificationCommand {
  static func main() async {
    do {
      let arguments = try Arguments.parse(CommandLine.arguments.dropFirst())
      let report: QualificationReport
      do {
        let configuration = try QualificationConfiguration.load(provider: arguments.provider)
        report = await ProviderQualificationRunner(
          configuration: configuration,
          prepareDataset: arguments.prepareDataset
        ).execute()
      } catch {
        report = QualificationReport(
          checks: [
            QualificationCheck(
              name: "qualification configuration",
              passed: false,
              detail: error.localizedDescription
            )
          ],
          completedAt: Date(),
          metrics: [:],
          passed: false,
          provider: arguments.provider,
          startedAt: Date()
        )
      }

      try report.write(to: arguments.reportURL)
      print(
        "\(report.provider.displayName) SwiftMail \(report.swiftMailVersion) qualification "
          + "\(report.passed ? "passed" : "failed")."
      )
      print("Evidence: \(arguments.reportURL.path)")
      if !report.passed { exit(EXIT_FAILURE) }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}

private struct Arguments {
  let prepareDataset: Bool
  let provider: QualificationProvider
  let reportURL: URL

  static func parse(_ arguments: ArraySlice<String>) throws -> Arguments {
    var iterator = arguments.makeIterator()
    var prepareDataset = false
    var provider: QualificationProvider?
    var reportPath: String?
    while let argument = iterator.next() {
      switch argument {
      case "--prepare-dataset":
        prepareDataset = true
      case "--provider":
        guard let value = iterator.next(), let parsed = QualificationProvider(rawValue: value)
        else {
          throw QualificationError.failed("--provider requires icloud or fastmail.")
        }
        provider = parsed
      case "--report":
        guard let value = iterator.next(), !value.isEmpty else {
          throw QualificationError.failed("--report requires a path.")
        }
        reportPath = value
      default:
        throw QualificationError.failed("Unknown argument: \(argument)")
      }
    }
    guard let provider else {
      throw QualificationError.failed("Missing required --provider icloud|fastmail.")
    }
    let path = reportPath ?? "artifacts/provider-qualification/\(provider.rawValue).json"
    return Arguments(
      prepareDataset: prepareDataset,
      provider: provider,
      reportURL: URL(fileURLWithPath: path)
    )
  }
}
