import Foundation

enum QualificationMessages {
  static func datasetMessage(index: Int, recipient: String) -> String {
    let token = String(format: "%05d", index)
    return paddedMessage(
      MessageDescriptor(
        body: "Unwired qualification dataset body \(token).",
        markerHeader: "X-Unwired-Qualification-Dataset: v1",
        messageID: "dataset-\(token)@qualification.invalid",
        subject: "Unwired qualification dataset \(token)",
        targetSize: QualificationConfiguration.datasetMessageSize
      ),
      recipient: recipient
    )
  }

  static func runMessage(
    body: String,
    runID: String,
    recipient: String,
    suffix: String,
    subject: String
  ) -> Data {
    Data(
      paddedMessage(
        MessageDescriptor(
          body: body,
          markerHeader: "X-Unwired-Qualification-Run: \(runID)",
          messageID: "\(runID)-\(suffix)@qualification.invalid",
          subject: subject,
          targetSize: nil
        ),
        recipient: recipient
      ).utf8
    )
  }

  private static func paddedMessage(_ descriptor: MessageDescriptor, recipient: String) -> String {
    var message = [
      "From: \(recipient)",
      "To: \(recipient)",
      "Subject: \(descriptor.subject)",
      "Message-ID: <\(descriptor.messageID)>",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Transfer-Encoding: 7bit",
    ]
    message.append(descriptor.markerHeader)
    var raw = message.joined(separator: "\r\n") + "\r\n\r\n" + descriptor.body
    if let targetSize = descriptor.targetSize {
      let ending = "\r\n"
      let missing = max(0, targetSize - raw.utf8.count - ending.utf8.count)
      raw += String(repeating: "x", count: missing)
    }
    return raw + "\r\n"
  }
}

private struct MessageDescriptor {
  let body: String
  let markerHeader: String
  let messageID: String
  let subject: String
  let targetSize: Int?
}
