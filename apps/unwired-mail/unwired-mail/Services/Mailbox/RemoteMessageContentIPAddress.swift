import Darwin
import Foundation

struct RemoteMessageContentIPAddress: Equatable, Hashable, Sendable {
  let bytes: Data
  let family: Int32
  let literal: String

  var isPublic: Bool {
    switch family {
    case AF_INET:
      return isPublicIPv4
    case AF_INET6:
      return isPublicIPv6
    default:
      return false
    }
  }

  static func numericAddress(_ host: String) -> Self? {
    guard let addresses = try? resolvedAddresses(host: host, flags: AI_NUMERICHOST) else {
      return nil
    }
    return addresses.first
  }

  static func resolve(_ host: String) async throws -> [Self] {
    try await Task.detached(priority: .utility) {
      try resolvedAddresses(host: host, flags: 0)
    }.value
  }

  private static func resolvedAddresses(host: String, flags: Int32) throws -> [Self] {
    var hints = addrinfo()
    hints.ai_flags = flags
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)
    guard status == 0 else {
      throw RemoteMessageContentNetworkError.unresolvedDestination
    }
    defer { freeaddrinfo(result) }

    var addresses: [Self] = []
    var cursor = result
    while let addressInfo = cursor?.pointee {
      if let address = makeAddress(addressInfo.ai_addr) {
        addresses.append(address)
      }
      cursor = addressInfo.ai_next
    }
    var seen = Set<Self>()
    return addresses.filter { seen.insert($0).inserted }
  }

  private static func makeAddress(_ socketAddress: UnsafeMutablePointer<sockaddr>?) -> Self? {
    guard let socketAddress else { return nil }
    switch Int32(socketAddress.pointee.sa_family) {
    case AF_INET:
      var address = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in.self)
        .pointee.sin_addr
      let bytes = Data(bytes: &address, count: MemoryLayout<in_addr>.size)
      var literal = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &address, &literal, socklen_t(literal.count)) != nil else {
        return nil
      }
      return Self(bytes: bytes, family: AF_INET, literal: String(cString: literal))
    case AF_INET6:
      var address = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in6.self)
        .pointee.sin6_addr
      let bytes = Data(bytes: &address, count: MemoryLayout<in6_addr>.size)
      var literal = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      guard inet_ntop(AF_INET6, &address, &literal, socklen_t(literal.count)) != nil else {
        return nil
      }
      return Self(bytes: bytes, family: AF_INET6, literal: String(cString: literal))
    default:
      return nil
    }
  }

  private var isPublicIPv4: Bool {
    let octets = [UInt8](bytes)
    guard octets.count == 4 else { return false }
    let first = octets[0]
    let second = octets[1]
    if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
    if first == 100, (64...127).contains(second) { return false }
    if first == 169, second == 254 { return false }
    if first == 172, (16...31).contains(second) { return false }
    if first == 192 {
      if second == 0, octets[2] == 0, ![9, 10].contains(octets[3]) { return false }
      if second == 0, octets[2] == 2 { return false }
      if second == 168 { return false }
      if second == 88, octets[2] == 99 { return false }
    }
    if first == 198 {
      if second == 18 || second == 19 { return false }
      if second == 51, octets[2] == 100 { return false }
    }
    if first == 203, second == 0, octets[2] == 113 { return false }
    return true
  }

  private var isPublicIPv6: Bool {
    let octets = [UInt8](bytes)
    guard octets.count == 16, octets[0] & 0xE0 == 0x20 else { return false }
    if octets[0] == 0x20, octets[1] == 0x01 {
      if octets[2] == 0, octets[3] == 0 { return false }
      if octets[2] == 0, octets[3] == 2, octets[4] == 0, octets[5] == 0 {
        return false
      }
      if octets[2] == 0, [0x10, 0x20].contains(octets[3] & 0xF0) { return false }
    }
    if octets[0] == 0x20, octets[1] == 0x01, octets[2] == 0x0D, octets[3] == 0xB8 {
      return false
    }
    if octets[0] == 0x20, octets[1] == 0x02 { return false }
    if octets[0] == 0x3F, octets[1] == 0xFE || octets[1] == 0xFF { return false }
    return true
  }
}
