import Foundation

// Calls the real mock provider; the fixture changes only its synthetic mailbox data.
@main struct SyntheticMetadataTests {
  struct Message: Decodable {
    struct Payload: Decodable {
      struct Header: Decodable { let name: String; let value: String }
      struct Body: Decodable { let size: Int; let data: String }
      let headers: [Header]
      let body: Body?
    }
    let payload: Payload
  }

  @MainActor static func main() async throws {
    let attachment = "attachment; filename=body.html"
    let provider = MockGoogleRegistrationProvider(
      scenario: "registration-declined",
      messages: [
        "attached": ["html": "<p>Attached body</p>", "disposition": attachment],
        "inline": ["text": "Inline body", "disposition": "inline"],
        "absent": ["text": "Ordinary body"],
      ])
    let identity = provider.identity("synthetic-alternate-mailbox", granted: true)

    func url(_ path: String, format: String = "metadata", headers: [String] = []) -> URL {
      var components = URLComponents(
        string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
      components.queryItems = [URLQueryItem(name: "format", value: format)]
        + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
      return components.url!
    }
    func message(_ id: String, format: String = "metadata", headers: [String]) async throws
      -> Message.Payload
    {
      let (status, data) = try await provider.gmail(
        identity, url: url("messages/\(id)", format: format, headers: headers))
      precondition(status == 200, "message request failed: \(id)")
      return try JSONDecoder().decode(Message.self, from: data).payload
    }
    func values(_ payload: Message.Payload) -> [String: String] {
      Dictionary(uniqueKeysWithValues: payload.headers.map { ($0.name, $0.value) })
    }
    for selectors in [
      ["Content-Type", "Content-Disposition"],
      ["Content-Disposition", "Content-Type"],
      ["cOnTeNt-DiSpOsItIoN", "CONTENT-TYPE", "Content-Disposition"],
    ] {
      let payload = try await message("attached", headers: selectors)
      precondition(values(payload) == [
        "Content-Type": "text/html; charset=UTF-8", "Content-Disposition": attachment,
      ], "repeated admission selectors must preserve both headers")
      precondition(payload.body == nil, "metadata must not download body bytes")
    }
    let type = try await message("attached", headers: ["Content-Type"])
    precondition(values(type) == ["Content-Type": "text/html; charset=UTF-8"])
    let disposition = try await message("attached", headers: ["Content-Disposition"])
    precondition(values(disposition) == ["Content-Disposition": attachment])
    let inline = try await message("inline", headers: ["Content-Type", "Content-Disposition"])
    precondition(values(inline) == [
      "Content-Type": "text/plain; charset=UTF-8", "Content-Disposition": "inline",
    ])
    let absent = try await message("absent", headers: ["Content-Type", "Content-Disposition"])
    precondition(values(absent) == ["Content-Type": "text/plain; charset=UTF-8"])
    let metadata = try await message("attached", headers: ["Content-Type", "Content-Disposition"])
    for selectors in [[], ["Content-Type", "Content-Disposition"]] {
      let full = try await message("attached", format: "full", headers: selectors)
      precondition(values(full) == values(metadata))
      precondition(full.body?.size == "<p>Attached body</p>".utf8.count)
      let encoded = full.body!.data.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
      let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
      precondition(Data(base64Encoded: padded) == Data("<p>Attached body</p>".utf8))
    }
    let missing = try await provider.gmail(identity, url: url(
      "messages/missing", headers: ["Content-Type", "Content-Disposition"]))
    precondition(missing.0 == 404)
    let denied = try await provider.gmail(
      provider.identity("synthetic-product-subject", granted: false),
      url: url("messages/attached", headers: ["Content-Type", "Content-Disposition"]))
    precondition(denied.0 == 401)

    // The test-only mailbox injection must not change the packaged journey's fixed corpus.
    let packaged = MockGoogleRegistrationProvider(scenario: "registration-declined")
    let first = try await packaged.gmail(identity, url: url("messages"))
    let page = try JSONSerialization.jsonObject(with: first.1) as! [String: Any]
    precondition(first.0 == 200 && page["nextPageToken"] as? String == "2")
    precondition((page["messages"] as! [[String: String]]).map { $0["id"]! } == [
      "19a0c0ffee000001", "19a0c0ffee000002",
    ])
    var next = URLComponents(url: url("messages"), resolvingAgainstBaseURL: false)!
    next.queryItems!.append(URLQueryItem(name: "pageToken", value: "2"))
    let second = try await packaged.gmail(identity, url: next.url!)
    let last = try JSONSerialization.jsonObject(with: second.1) as! [String: Any]
    precondition(second.0 == 200 && last["nextPageToken"] == nil)
    precondition((last["messages"] as! [[String: String]]).map { $0["id"]! } == [
      "19a0c0ffee000003",
    ])
    print("Synthetic Gmail metadata checks passed: repeated headers, dispositions, full body, status guards and packaged pagination")
  }
}
