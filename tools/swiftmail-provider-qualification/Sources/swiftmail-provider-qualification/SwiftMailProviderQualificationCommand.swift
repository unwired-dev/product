import Darwin
import Foundation
import SwiftMailProviderQualification

@main
struct SwiftMailProviderQualificationCommand {
  static func main() async {
    do {
      let arguments = try Arguments.parse(CommandLine.arguments.dropFirst())
      if case .verifyEvidence(let reportURLs) = arguments {
        try QualificationEvidenceVerifier.verify(reportURLs: reportURLs)
        print("iCloud Mail and Fastmail final evidence passed offline verification.")
        return
      }
      guard case .qualify(let qualification) = arguments else { return }
      let report: QualificationReport
      do {
        let configuration = try QualificationConfiguration.load(provider: qualification.provider)
        report = await ProviderQualificationRunner(
          configuration: configuration,
          prepareDataset: qualification.prepareDataset
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
          preparedDataset: qualification.prepareDataset,
          provider: qualification.provider,
          startedAt: Date()
        )
      }

      try report.write(to: qualification.reportURL)
      print(
        "\(report.provider.displayName) SwiftMail \(report.swiftMailVersion) qualification "
          + "\(report.passed ? "passed" : "failed")."
      )
      print("Evidence: \(qualification.reportURL.path)")
      if !report.passed { exit(EXIT_FAILURE) }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}

private enum Arguments {
  case qualify(QualificationArguments)
  case verifyEvidence([URL])

  static func parse(_ arguments: ArraySlice<String>) throws -> Arguments {
    if arguments.first == "--verify-evidence" {
      let reportURLs = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
      guard reportURLs.count == QualificationProvider.allCases.count else {
        throw QualificationError.failed(
          "--verify-evidence requires the iCloud Mail and Fastmail report paths."
        )
      }
      return .verifyEvidence(reportURLs)
    }
    return .qualify(try QualificationArguments.parse(arguments))
  }
}

private struct QualificationArguments {
  let prepareDataset: Bool
  let provider: QualificationProvider
  let reportURL: URL

  static func parse(_ arguments: ArraySlice<String>) throws -> QualificationArguments {
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
    return QualificationArguments(
      prepareDataset: prepareDataset,
      provider: provider,
      reportURL: URL(fileURLWithPath: path)
    )
  }
}
