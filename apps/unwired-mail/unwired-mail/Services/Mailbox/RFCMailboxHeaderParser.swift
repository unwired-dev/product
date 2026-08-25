import Foundation

struct RFCMailbox: Equatable, Sendable {
  let displayName: String?
  let emailAddress: String

  var headerValue: String {
    guard let displayName, !displayName.isEmpty else { return emailAddress }
    let escapedName =
      displayName
      .replacing("\\", with: "\\\\")
      .replacing("\"", with: "\\\"")
    return "\"\(escapedName)\" <\(emailAddress)>"
  }
}

// The parser stays centralized so incoming-header and outgoing-recipient validation share rules.
// swiftlint:disable:next type_body_length
enum RFCMailboxHeaderParser {
  private static let maximumHeaderByteCount = 16 * 1_024

  static func singleMailbox(in value: String) -> RFCMailbox? {
    guard let mailboxes = mailboxes(in: value), mailboxes.count == 1 else { return nil }
    return mailboxes[0]
  }

  static func mailboxes(in value: String) -> [RFCMailbox]? {
    parsedMailboxes(in: value, allowsGroups: false, preservesAddressCase: false)
  }

  static func recipientAddresses(in value: String) -> [String]? {
    guard
      !value.contains("\r"),
      !value.contains("\n"),
      let mailboxes = parsedMailboxes(
        in: value,
        allowsGroups: true,
        preservesAddressCase: true
      ), !mailboxes.isEmpty
    else { return nil }
    return mailboxes.map(\.emailAddress)
  }

  private static func parsedMailboxes(
    in value: String,
    allowsGroups: Bool,
    preservesAddressCase: Bool
  ) -> [RFCMailbox]? {
    guard value.utf8.count <= maximumHeaderByteCount else { return nil }
    let unfolded = value.replacingOccurrences(
      of: #"\r\n[\t ]+"#,
      with: " ",
      options: .regularExpression
    )
    guard
      !unfolded.isEmpty,
      unfolded.utf8.count <= maximumHeaderByteCount,
      !unfolded.contains("\r"),
      !unfolded.contains("\n"),
      let components = mailboxComponents(in: unfolded, allowsGroups: allowsGroups)
    else { return nil }

    var parsed: [RFCMailbox] = []
    for component in components {
      guard
        let mailbox = parseMailbox(
          component,
          preservesAddressCase: preservesAddressCase
        )
      else { return nil }
      parsed.append(mailbox)
    }
    return parsed
  }

  // A mailbox list is small and bounded before this single-pass structural scan.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private static func mailboxComponents(in value: String, allowsGroups: Bool) -> [String]? {
    var components: [String] = []
    var current = ""
    var commentDepth = 0
    var angleDepth = 0
    var isEscaped = false
    var isInGroup = false
    var isQuoted = false
    var lastSeparatorWasComma = false
    var requiresSeparatorAfterGroup = false
    for character in value {
      if character.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) {
        return nil
      }
      if isEscaped {
        isEscaped = false
      } else if character == "\\", isQuoted || commentDepth > 0 {
        isEscaped = true
      } else if character == "\"", commentDepth == 0 {
        isQuoted.toggle()
      } else if !isQuoted {
        if character == "(" {
          commentDepth += 1
        } else if character == ")" {
          guard commentDepth > 0 else { return nil }
          commentDepth -= 1
        } else if commentDepth == 0, character == "<" {
          guard angleDepth == 0 else { return nil }
          angleDepth = 1
        } else if commentDepth == 0, character == ">" {
          guard angleDepth == 1 else { return nil }
          angleDepth = 0
        } else if commentDepth == 0, angleDepth == 0 {
          if requiresSeparatorAfterGroup {
            if character.isWhitespace { continue }
            guard character == "," else { return nil }
            requiresSeparatorAfterGroup = false
            current = ""
            lastSeparatorWasComma = true
            continue
          }
          if character == ":" {
            guard allowsGroups, !isInGroup, validGroupName(current) else { return nil }
            current = ""
            isInGroup = true
            lastSeparatorWasComma = false
            continue
          }
          if character == ";" {
            guard allowsGroups, isInGroup, !lastSeparatorWasComma else { return nil }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              components.append(current)
            }
            current = ""
            isInGroup = false
            requiresSeparatorAfterGroup = true
            continue
          }
          if character == "," {
            guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
              return nil
            }
            components.append(current)
            current = ""
            lastSeparatorWasComma = true
            continue
          }
        }
      }
      current.append(character)
      if !character.isWhitespace { lastSeparatorWasComma = false }
    }
    guard
      !isEscaped,
      !isQuoted,
      commentDepth == 0,
      angleDepth == 0,
      !isInGroup,
      !lastSeparatorWasComma
    else { return nil }
    if !requiresSeparatorAfterGroup {
      guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      components.append(current)
    }
    return components
  }

  private static func validGroupName(_ value: String) -> Bool {
    guard let withoutComments = removingComments(from: value) else { return false }
    let trimmed = withoutComments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("\"") || !trimmed.contains("@") else { return false }
    return decodedDisplayName(withoutComments, allowsQuotedSpecials: true) != nil
  }

  private static func parseMailbox(
    _ value: String,
    preservesAddressCase: Bool
  ) -> RFCMailbox? {
    guard let withoutComments = removingComments(from: value) else { return nil }
    let trimmed = withoutComments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let address: String
    let displayName: String?
    if let opening = trimmed.firstIndex(of: "<") {
      guard let closing = trimmed.firstIndex(of: ">"), opening < closing,
        String(trimmed[trimmed.index(after: closing)...])
          .trimmingCharacters(in: .whitespaces).isEmpty,
        !trimmed[trimmed.index(after: opening)..<closing].contains("<")
      else { return nil }
      address = String(trimmed[trimmed.index(after: opening)..<closing])
      displayName = decodedDisplayName(
        String(trimmed[..<opening]),
        allowsQuotedSpecials: preservesAddressCase
      )
      guard displayName != nil else { return nil }
    } else {
      guard !trimmed.contains(">") else { return nil }
      address = trimmed
      displayName = nil
    }
    guard
      let normalizedAddress = normalizedEmailAddress(
        address,
        preservesCase: preservesAddressCase
      )
    else { return nil }
    return RFCMailbox(displayName: displayName, emailAddress: normalizedAddress)
  }

  private static func removingComments(from value: String) -> String? {
    var result = ""
    var depth = 0
    var isEscaped = false
    var isQuoted = false
    for character in value {
      if isEscaped {
        if depth == 0 { result.append(character) }
        isEscaped = false
      } else if character == "\\", isQuoted || depth > 0 {
        if depth == 0 { result.append(character) }
        isEscaped = true
      } else if character == "\"", depth == 0 {
        isQuoted.toggle()
        result.append(character)
      } else if !isQuoted, character == "(" {
        depth += 1
      } else if !isQuoted, character == ")" {
        guard depth > 0 else { return nil }
        depth -= 1
      } else if depth == 0 {
        result.append(character)
      }
    }
    return !isEscaped && !isQuoted && depth == 0 ? result : nil
  }

  private static func decodedDisplayName(
    _ value: String,
    allowsQuotedSpecials: Bool = false
  ) -> String? {
    var phrase = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty else { return nil }
    let containsEncodedWord = phrase.contains("=?")
    let isQuoted = phrase.hasPrefix("\"") && phrase.hasSuffix("\"")
    if phrase.hasPrefix("\"") || phrase.hasSuffix("\"") {
      guard phrase.count >= 2, isQuoted else { return nil }
      phrase.removeFirst()
      phrase.removeLast()
      phrase = phrase.replacingOccurrences(
        of: #"\\([\\\"])"#,
        with: "$1",
        options: .regularExpression
      )
    } else if phrase.contains("\"") {
      return nil
    }
    guard let decoded = decodeEncodedWords(in: phrase) else { return nil }
    let normalized = decoded.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    let prohibitedCharacters =
      allowsQuotedSpecials && (isQuoted || containsEncodedWord) ? "<>" : "<>,;:"
    guard
      !normalized.isEmpty,
      !normalized.contains(where: prohibitedCharacters.contains),
      !normalized.unicodeScalars.contains(where: isUnsafeDisplayNameScalar)
    else { return nil }
    return normalized
  }

  private static func decodeEncodedWords(in value: String) -> String? {
    let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
    let matches = expression.matches(in: value, range: fullRange)
    var result = ""
    var cursor = value.startIndex
    for (index, match) in matches.enumerated() {
      guard
        let matchRange = Range(match.range, in: value),
        let charsetRange = Range(match.range(at: 1), in: value),
        let encodingRange = Range(match.range(at: 2), in: value),
        let payloadRange = Range(match.range(at: 3), in: value)
      else { return nil }
      let separator = value[cursor..<matchRange.lowerBound]
      if index == 0 || separator.contains(where: { $0 != " " && $0 != "\t" }) {
        result += separator
      }
      guard
        let decoded = decodeEncodedWord(
          charset: String(value[charsetRange]),
          encoding: String(value[encodingRange]),
          payload: String(value[payloadRange])
        )
      else { return nil }
      result += decoded
      cursor = matchRange.upperBound
    }
    result += value[cursor...]
    return result.contains("=?") ? nil : result
  }

  private static func decodeEncodedWord(
    charset: String,
    encoding: String,
    payload: String
  ) -> String? {
    let data =
      encoding.caseInsensitiveCompare("B") == .orderedSame
      ? Data(base64Encoded: payload)
      : quotedPrintableData(payload)
    guard let data else { return nil }
    switch charset.lowercased() {
    case "utf-8", "utf8":
      return String(data: data, encoding: .utf8)
    case "us-ascii", "ascii":
      return String(data: data, encoding: .ascii)
    case "iso-8859-1", "latin1":
      return String(data: data, encoding: .isoLatin1)
    case "windows-1252", "cp1252":
      return String(data: data, encoding: .windowsCP1252)
    default:
      return nil
    }
  }

  private static func quotedPrintableData(_ payload: String) -> Data? {
    var bytes: [UInt8] = []
    let payloadBytes = Array(payload.utf8)
    var index = 0
    while index < payloadBytes.count {
      if payloadBytes[index] == Character("_").asciiValue {
        bytes.append(0x20)
        index += 1
      } else if payloadBytes[index] == Character("=").asciiValue {
        guard index + 2 < payloadBytes.count,
          let high = hexadecimalValue(payloadBytes[index + 1]),
          let low = hexadecimalValue(payloadBytes[index + 2])
        else { return nil }
        bytes.append(high * 16 + low)
        index += 3
      } else {
        guard payloadBytes[index] < 0x80 else { return nil }
        bytes.append(payloadBytes[index])
        index += 1
      }
    }
    return Data(bytes)
  }

  private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: return byte - 48
    case 65...70: return byte - 55
    case 97...102: return byte - 87
    default: return nil
    }
  }

  private static func normalizedEmailAddress(
    _ value: String,
    preservesCase: Bool
  ) -> String? {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let valueToValidate = address.lowercased()
    let atom = #"[a-z0-9!#$%&'*+/=?^_`{|}~-]+"#
    let quotedLocalPart = #"\"(?:[\x21\x23-\x5B\x5D-\x7E]|\\[\x21-\x7E])*\""#
    let localPart = #"(?:"# + atom + #"(?:\."# + atom + #")*|"# + quotedLocalPart + #")"#
    let label = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
    let domain = #"(?:"# + label + #"(?:\."# + label + #")*|\[[\x21-\x5A\x5E-\x7E]+\])"#
    let pattern = "^" + localPart + "@" + domain + "$"
    guard
      valueToValidate.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    else { return nil }
    return preservesCase ? address : valueToValidate
  }

  private static func isUnsafeDisplayNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .control
      || scalar.properties.generalCategory == .format
  }
}
