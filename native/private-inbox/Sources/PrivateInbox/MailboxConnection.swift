import CryptoKit
import Foundation

// One authorized mailbox on this device. Each keeps its own credential, verification and cache;
// its provider account identifies it, so adding the same mailbox again repairs it.
struct MailboxConnection: Codable {
  // A Gmail refresh credential, or an IMAP connection's password.
  var credential: Data
  var receipt: GmailRegistrationReceipt
  // Present for a Standards-Based Mailbox Connection; its receipt's subject names this account.
  var imap: ImapAccount? = nil
  // Its SMTP endpoint, once verified; connections saved before SMTP receive only until then.
  var smtp: SmtpAccount? = nil
  // A separate SMTP password; without one SMTP uses `credential`.
  var smtpCredential: Data? = nil
  // Gmail refused this mailbox's grant; nothing reaches it until it is authorized again.
  var authorizationNeeded: Bool?
  // The synchronized descriptor's epoch this authorization belongs to. A new epoch means the
  // connection was removed and added again, so an authorization from before that is purged.
  var epoch: String?
  // This device has read its descriptor back at `epoch`.
  var published: Bool?
  // What this device had last read of the synchronized descriptor when it authorized the
  // connection: `observed` with `observedEpoch`, nil when there was no descriptor (empty for one
  // without an epoch). Only a later live descriptor at that known epoch proves no removal since;
  // absence supplies no incarnation to adopt after relaunch.
  var observed: Bool?
  var observedEpoch: String?
  // The opaque relay route of this connection's Gmail watch, and when Gmail ends that watch, in
  // milliseconds since 1970.
  var pushRoute: String?
  var pushExpiration: Double?
  var pushVerified: Bool?

  // The opaque identifier JavaScript names this connection by.
  var id: String { Self.id(receipt) }
  // A Gmail connection keeps the identifier of connections from before other providers.
  static func id(_ receipt: GmailRegistrationReceipt) -> String {
    id(subject: receipt.mailProvider == .gmail ? receipt.subject : receipt.account)
  }
  static func id(subject: String) -> String {
    SHA256.hash(data: Data(("dev.unwired.mailbox-connection\n" + subject).utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
  }
}

// A removed connection's descriptor still to be marked removed in Product Sync.
struct MailboxRemoval: Codable {
  let subject: String
  let address: String
  let epoch: String?
  var provider: MailProvider? = nil

  var receipt: GmailRegistrationReceipt {
    GmailRegistrationReceipt(subject: subject, address: address, provider: provider)
  }
}
