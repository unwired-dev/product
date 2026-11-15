import Foundation
import dnssd

// RFC 6186 email-service discovery for Other IMAP Account: the endpoints a domain's SRV records
// name, looked up through the system resolver on this device. The person reviews them before
// connecting, and Secure Mail Transport verifies each host as usual (ADR 0017).
enum MailServiceDiscovery {
  struct Endpoint: Equatable, Sendable {
    let host: String
    let port: Int
  }
  struct Record: Equatable, Sendable {
    let priority: UInt16
    let weight: UInt16
    let port: UInt16
    // Empty for ".", which says the service is not offered.
    let target: String
  }

  // IMAP over implicit TLS, and SMTP over implicit TLS (RFC 8314) or else submission with
  // STARTTLS; nil unless the domain names both.
  static func servers(domain: String) async -> (imap: Endpoint, smtp: Endpoint)? {
    async let imaps = records("_imaps._tcp.\(domain)")
    async let submissions = records("_submissions._tcp.\(domain)")
    async let submission = records("_submission._tcp.\(domain)")
    let (imap, implicit, starttls) = await (imaps, submissions, submission)
    guard let imap = endpoint(imap), let smtp = endpoint(implicit) ?? endpoint(starttls)
    else { return nil }
    return (imap, smtp)
  }

  // The record a client tries first: the lowest priority, then the highest weight (RFC 2782).
  static func endpoint(_ records: [Record]) -> Endpoint? {
    guard !records.contains(where: { $0.target.isEmpty || $0.port == 0 }),
      let first = records.min(by: { ($0.priority, ~$0.weight) < ($1.priority, ~$1.weight) })
    else { return nil }
    return Endpoint(host: first.target, port: Int(first.port))
  }

  // An SRV record's data: priority, weight and port, then the uncompressed target name. Only
  // letter-digit-hyphen labels are read; anything else is not a mail server's host name.
  static func record(_ data: [UInt8]) -> Record? {
    guard data.count > 6 else { return nil }
    let number = { (index: Int) in UInt16(data[index]) << 8 | UInt16(data[index + 1]) }
    var labels: [String] = []
    var index = 6
    while index < data.count {
      let length = Int(data[index])
      index += 1
      if length == 0 {
        guard index == data.count else { return nil }
        return Record(
          priority: number(0), weight: number(2), port: number(4),
          target: labels.joined(separator: "."))
      }
      guard length <= 63, index + length <= data.count else { return nil }
      let label = String(decoding: data[index..<index + length], as: UTF8.self)
      guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
      else { return nil }
      labels.append(label.lowercased())
      index += length
    }
    return nil
  }

  // The SRV records the system resolver returns for `name`; none after an error or five seconds.
  static func records(_ name: String) async -> [Record] {
    await withCheckedContinuation { Query($0).start(name) }
  }

  // One DNS-SD query; every access runs on `queue`.
  private final class Query: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.unwired.mail-service-discovery")
    private var continuation: CheckedContinuation<[Record], Never>?
    private var reference: DNSServiceRef?
    private var records: [Record] = []

    init(_ continuation: CheckedContinuation<[Record], Never>) {
      self.continuation = continuation
    }

    func start(_ name: String) {
      Self.queue.async { [self] in
        // The query holds itself until it finishes.
        let context = Unmanaged.passRetained(self).toOpaque()
        let status = DNSServiceQueryRecord(
          &reference, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name,
          UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN),
          { _, flags, _, error, _, type, _, length, data, _, context in
            guard let context else { return }
            Unmanaged<Query>.fromOpaque(context).takeUnretainedValue().receive(
              flags: flags, error: error, type: type,
              data: data.map { Array(UnsafeRawBufferPointer(start: $0, count: Int(length))) })
          }, context)
        guard status == kDNSServiceErr_NoError, let reference,
          DNSServiceSetDispatchQueue(reference, Self.queue) == kDNSServiceErr_NoError
        else { return finish() }
        Self.queue.asyncAfter(deadline: .now() + 5) { self.finish() }
      }
    }

    // A negative answer or an error ends the query, as does the last SRV answer of a batch.
    private func receive(
      flags: DNSServiceFlags, error: DNSServiceErrorType, type: UInt16, data: [UInt8]?
    ) {
      guard error == kDNSServiceErr_NoError else { return finish() }
      guard type == kDNSServiceType_SRV else { return }
      if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let data,
        let record = MailServiceDiscovery.record(data)
      {
        records.append(record)
      }
      if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { finish() }
    }

    private func finish() {
      guard let continuation else { return }
      self.continuation = nil
      if let reference { DNSServiceRefDeallocate(reference) }
      reference = nil
      continuation.resume(returning: records)
      Unmanaged.passUnretained(self).release()
    }
  }
}
