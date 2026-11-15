import Testing

@testable import PrivateInbox

struct MailServiceDiscoveryTests {
  // `0 1 993 IMAP.example.org.` in SRV wire format.
  static let imaps: [UInt8] =
    [0, 0, 0, 1, 3, 225] + [4] + Array("IMAP".utf8) + [7] + Array("example".utf8) + [3]
    + Array("org".utf8) + [0]

  @Test func readsAnSrvRecord() {
    #expect(
      MailServiceDiscovery.record(Self.imaps)
        == .init(priority: 0, weight: 1, port: 993, target: "imap.example.org"))
    #expect(
      MailServiceDiscovery.record([0, 0, 0, 0, 0, 0, 0])
        == .init(priority: 0, weight: 0, port: 0, target: ""))
  }

  @Test func refusesMalformedRecords() {
    // Truncated, trailing bytes, a label running past the end, and a label that is no host name.
    for data: [UInt8] in [
      [0, 0, 0, 1, 3], Self.imaps + [0], [0, 0, 0, 1, 3, 225, 9, 97, 0],
      [0, 0, 0, 1, 3, 225, 3, 97, 32, 98, 0],
    ] {
      #expect(MailServiceDiscovery.record(data) == nil)
    }
  }

  @Test func choosesTheLowestPriorityThenTheHighestWeight() {
    let records = [
      MailServiceDiscovery.Record(priority: 10, weight: 50, port: 993, target: "backup.example.org"),
      .init(priority: 0, weight: 5, port: 993, target: "light.example.org"),
      .init(priority: 0, weight: 20, port: 993, target: "imap.example.org"),
    ]
    #expect(
      MailServiceDiscovery.endpoint(records) == .init(host: "imap.example.org", port: 993))
    #expect(MailServiceDiscovery.endpoint([]) == nil)
  }

  @Test func aDotTargetMeansTheServiceIsNotOffered() {
    #expect(
      MailServiceDiscovery.endpoint([.init(priority: 0, weight: 0, port: 0, target: "")]) == nil)
  }
}
