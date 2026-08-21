import Foundation

extension MailShellCompositionDraft {
  private enum CodingKeys: String, CodingKey {
    case assets
    case bccRecipients
    case ccRecipients
    case connectionId
    case document
    case hasExplicitReadReceiptChoice
    case id
    case kind
    case legacyBody = "body"
    case omittedForwardAttachmentCount
    case quotedText
    case recipient
    case replyToMessage
    case requestsReadReceipt
    case sendingIdentityId
    case signature
    case sourceMessage
    case subject
    case updatedAtMilliseconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    assets = try container.decodeIfPresent([MailDraftAsset].self, forKey: .assets) ?? []
    bccRecipients = try container.decodeIfPresent(String.self, forKey: .bccRecipients) ?? ""
    ccRecipients = try container.decodeIfPresent(String.self, forKey: .ccRecipients) ?? ""
    connectionId = try container.decodeIfPresent(MailboxConnectionId.self, forKey: .connectionId)
    if let decodedDocument = try container.decodeIfPresent(
      SemanticMessageDocument.self,
      forKey: .document
    ) {
      document = decodedDocument
    } else {
      document = SemanticMessageDocument(
        plainText: try container.decodeIfPresent(String.self, forKey: .legacyBody) ?? ""
      )
    }
    hasExplicitReadReceiptChoice =
      try container.decodeIfPresent(Bool.self, forKey: .hasExplicitReadReceiptChoice) ?? false
    id = try container.decode(UUID.self, forKey: .id)
    kind = try container.decodeIfPresent(MailCompositionKind.self, forKey: .kind) ?? .newMessage
    omittedForwardAttachmentCount =
      try container.decodeIfPresent(Int.self, forKey: .omittedForwardAttachmentCount) ?? 0
    quotedText = try container.decodeIfPresent(String.self, forKey: .quotedText)
    recipient = try container.decode(String.self, forKey: .recipient)
    replyToMessage = try container.decodeIfPresent(
      MailboxMessageMetadata.self,
      forKey: .replyToMessage
    )
    requestsReadReceipt =
      try container.decodeIfPresent(Bool.self, forKey: .requestsReadReceipt) ?? false
    sendingIdentityId = try container.decodeIfPresent(
      SendingIdentityId.self,
      forKey: .sendingIdentityId
    )
    signature = try container.decodeIfPresent(MailSignature.self, forKey: .signature)
    sourceMessage = try container.decodeIfPresent(
      MailboxMessageMetadata.self,
      forKey: .sourceMessage
    )
    subject = try container.decode(String.self, forKey: .subject)
    updatedAtMilliseconds =
      try container.decodeIfPresent(Int64.self, forKey: .updatedAtMilliseconds)
      ?? Int64(Date.now.timeIntervalSince1970 * 1_000)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(assets, forKey: .assets)
    try container.encode(bccRecipients, forKey: .bccRecipients)
    try container.encode(ccRecipients, forKey: .ccRecipients)
    try container.encodeIfPresent(connectionId, forKey: .connectionId)
    try container.encode(document, forKey: .document)
    try container.encode(document.plainText, forKey: .legacyBody)
    try container.encode(hasExplicitReadReceiptChoice, forKey: .hasExplicitReadReceiptChoice)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(omittedForwardAttachmentCount, forKey: .omittedForwardAttachmentCount)
    try container.encodeIfPresent(quotedText, forKey: .quotedText)
    try container.encode(recipient, forKey: .recipient)
    try container.encodeIfPresent(replyToMessage, forKey: .replyToMessage)
    try container.encode(requestsReadReceipt, forKey: .requestsReadReceipt)
    try container.encodeIfPresent(sendingIdentityId, forKey: .sendingIdentityId)
    try container.encodeIfPresent(signature, forKey: .signature)
    try container.encodeIfPresent(sourceMessage, forKey: .sourceMessage)
    try container.encode(subject, forKey: .subject)
    try container.encode(updatedAtMilliseconds, forKey: .updatedAtMilliseconds)
  }
}
