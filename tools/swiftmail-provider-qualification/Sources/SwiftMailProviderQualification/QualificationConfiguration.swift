import Foundation
import SwiftMail

struct QualificationEndpoint: Sendable {
  let host: String
  let port: Int
  let security: MailTransportSecurity
}

public struct QualificationConfiguration: Sendable {
  public static let datasetMessageCount = 10_000
  public static let datasetMessageSize = 2_048

  public let datasetMailbox: String
  public let emailAddress: String
  public let explicitJunkMailbox: String?
  public let explicitSentMailbox: String?
  public let password: String
  public let provider: QualificationProvider

  public init(
    datasetMailbox: String,
    emailAddress: String,
    explicitJunkMailbox: String? = nil,
    explicitSentMailbox: String? = nil,
    password: String,
    provider: QualificationProvider
  ) {
    self.datasetMailbox = datasetMailbox
    self.emailAddress = emailAddress
    self.explicitJunkMailbox = explicitJunkMailbox
    self.explicitSentMailbox = explicitSentMailbox
    self.password = password
    self.provider = provider
  }

  public static func load(
    provider: QualificationProvider,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> QualificationConfiguration {
    let prefix = provider == .icloud ? "ICLOUD" : "FASTMAIL"
    let emailName = "\(prefix)_QUALIFICATION_EMAIL"
    let passwordName = "\(prefix)_QUALIFICATION_PASSWORD"
    guard let emailAddress = nonempty(environment[emailName]) else {
      throw QualificationError.missingEnvironmentVariable(emailName)
    }
    guard let password = nonempty(environment[passwordName]) else {
      throw QualificationError.missingEnvironmentVariable(passwordName)
    }
    return QualificationConfiguration(
      datasetMailbox: nonempty(environment["\(prefix)_QUALIFICATION_DATASET_MAILBOX"])
        ?? "Unwired Qualification Dataset",
      emailAddress: emailAddress,
      explicitJunkMailbox: nonempty(environment["\(prefix)_QUALIFICATION_JUNK_MAILBOX"]),
      explicitSentMailbox: nonempty(environment["\(prefix)_QUALIFICATION_SENT_MAILBOX"]),
      password: password,
      provider: provider
    )
  }

  var imapEndpoint: QualificationEndpoint {
    switch provider {
    case .fastmail:
      QualificationEndpoint(host: "imap.fastmail.com", port: 993, security: .implicitTLS)
    case .icloud:
      QualificationEndpoint(host: "imap.mail.me.com", port: 993, security: .implicitTLS)
    }
  }

  var smtpEndpoint: QualificationEndpoint {
    switch provider {
    case .fastmail:
      QualificationEndpoint(host: "smtp.fastmail.com", port: 465, security: .implicitTLS)
    case .icloud:
      QualificationEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS)
    }
  }

  var scratchMailbox: String { "Unwired Qualification Scratch" }
  var secondaryScratchMailbox: String { "Unwired Qualification Exclusion" }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else {
      return nil
    }
    return value
  }
}
