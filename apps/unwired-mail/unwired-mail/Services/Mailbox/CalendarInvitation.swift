import CryptoKit
import Foundation

struct CalendarInvitationDescriptor: Codable, Equatable, Sendable {
  static let maximumByteCount = 1 * 1_024 * 1_024

  let byteCount: Int
  let dismissalIdentifier: String
  let mimeType: String
  let providerAttachmentId: String?
  let providerPartId: String

  init(
    byteCount: Int,
    dismissalIdentifier: String = UUID().uuidString.lowercased(),
    mimeType: String,
    providerAttachmentId: String?,
    providerPartId: String
  ) {
    self.byteCount = max(byteCount, 0)
    self.dismissalIdentifier = dismissalIdentifier
    self.mimeType = mimeType
    self.providerAttachmentId = providerAttachmentId
    self.providerPartId = providerPartId
  }

  var stablePartSignature: String {
    [providerPartId, providerAttachmentId ?? "", mimeType.lowercased(), String(byteCount)]
      .joined(separator: "\u{1f}")
  }

  func preservingDismissalIdentifier(
    from previous: CalendarInvitationDescriptor?
  ) -> Self {
    guard let previous, previous.stablePartSignature == stablePartSignature else { return self }
    return Self(
      byteCount: byteCount,
      dismissalIdentifier: previous.dismissalIdentifier,
      mimeType: mimeType,
      providerAttachmentId: providerAttachmentId,
      providerPartId: providerPartId
    )
  }
}

enum CalendarInvitationMethod: String, Equatable, Sendable {
  case cancel
  case request
}

struct CalendarInvitationCandidate: Equatable, Sendable {
  let endDate: Date?
  let isAllDay: Bool
  let location: String?
  let method: CalendarInvitationMethod
  let notes: String?
  let sequence: Int
  let startDate: Date?
  let summary: String
  let timeZoneIdentifier: String?
  let uid: String

  var fingerprint: String {
    let fields = [
      method.rawValue,
      String(sequence),
      summary,
      startDate.map { String($0.timeIntervalSince1970) } ?? "",
      endDate.map { String($0.timeIntervalSince1970) } ?? "",
      isAllDay ? "all-day" : "timed",
      timeZoneIdentifier ?? "",
      location ?? "",
      notes ?? "",
    ]
    return SHA256.hash(data: Data(fields.joined(separator: "\u{1f}").utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  var opaqueUID: String {
    SHA256.hash(data: Data(uid.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

enum CalendarInvitationParsingError: LocalizedError, Equatable {
  case ambiguousTime
  case invalidInvitation
  case invitationTooLarge
  case unsupportedRecurrence

  var errorDescription: String? {
    switch self {
    case .ambiguousTime:
      "The invitation does not identify a usable time zone."
    case .invalidInvitation:
      "The calendar invitation is invalid or incomplete."
    case .invitationTooLarge:
      "The calendar invitation is larger than the supported safety limit."
    case .unsupportedRecurrence:
      "Recurring calendar changes are not supported yet."
    }
  }
}

// The parser keeps its resource limits and grammar helpers together for review.
// swiftlint:disable:next type_body_length
enum CalendarInvitationParser {
  private struct Property {
    let name: String
    let parameters: [String: String]
    let value: String
  }

  private static let maximumLineByteCount = 16 * 1_024
  private static let maximumLineCount = 2_048

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func parse(
    _ data: Data,
    floatingTimeZone: TimeZone? = nil
  ) throws -> CalendarInvitationCandidate {
    guard data.count <= CalendarInvitationDescriptor.maximumByteCount else {
      throw CalendarInvitationParsingError.invitationTooLarge
    }
    guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    if text.first == "\u{feff}" { text.removeFirst() }
    let properties = try eventProperties(in: text)
    let recurrencePropertyNames = ["RRULE", "RDATE", "EXRULE", "EXDATE", "RECURRENCE-ID"]
    guard !properties.contains(where: { recurrencePropertyNames.contains($0.name) })
    else { throw CalendarInvitationParsingError.unsupportedRecurrence }

    guard let uid = value(named: "UID", in: properties).map(unescapedText),
      !uid.isEmpty,
      uid.utf8.count <= 998
    else { throw CalendarInvitationParsingError.invalidInvitation }

    let methodValue = value(named: "METHOD", in: properties)?.uppercased()
    let statusValue = value(named: "STATUS", in: properties)?.uppercased()
    let method: CalendarInvitationMethod
    switch methodValue {
    case "CANCEL":
      method = .cancel
    case "REQUEST", nil:
      method = statusValue == "CANCELLED" ? .cancel : .request
    default:
      throw CalendarInvitationParsingError.invalidInvitation
    }
    let summary = value(named: "SUMMARY", in: properties).map(unescapedText) ?? "Calendar Event"
    guard !summary.isEmpty, summary.utf8.count <= 8_192 else {
      throw CalendarInvitationParsingError.invalidInvitation
    }

    let startProperty = properties.first { $0.name == "DTSTART" }
    if method == .request, startProperty == nil {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    let start = try startProperty.map {
      try dateValue($0, floatingTimeZone: floatingTimeZone)
    }
    var end = try properties.first { $0.name == "DTEND" }.map {
      try dateValue($0, floatingTimeZone: floatingTimeZone)
    }
    if end == nil, let start {
      if let duration = value(named: "DURATION", in: properties) {
        end = start.addingTimeInterval(try durationInterval(duration))
      } else {
        end = start.addingTimeInterval(
          startProperty?.parameters["VALUE"]?.uppercased() == "DATE" ? 86_400 : 3_600)
      }
    }
    if let start, let end, end <= start {
      throw CalendarInvitationParsingError.invalidInvitation
    }

    let sequence = value(named: "SEQUENCE", in: properties).flatMap(Int.init) ?? 0
    guard sequence >= 0 else { throw CalendarInvitationParsingError.invalidInvitation }
    let timeZoneIdentifier = resolvedTimeZoneIdentifier(
      for: startProperty,
      floatingTimeZone: floatingTimeZone
    )
    return CalendarInvitationCandidate(
      endDate: end,
      isAllDay: startProperty?.parameters["VALUE"]?.uppercased() == "DATE",
      location: value(named: "LOCATION", in: properties).map(unescapedText),
      method: method,
      notes: value(named: "DESCRIPTION", in: properties).map(unescapedText),
      sequence: sequence,
      startDate: start,
      summary: summary,
      timeZoneIdentifier: timeZoneIdentifier,
      uid: uid
    )
  }

  private static func eventProperties(in text: String) throws -> [Property] {
    let lines = try unfoldedLines(in: text)
    var stack: [String] = []
    var calendarProperties: [Property] = []
    var eventProperties: [Property] = []
    var eventCount = 0
    for line in lines {
      let property = try parsedProperty(line)
      if property.name == "BEGIN" {
        let component = property.value.uppercased()
        stack.append(component)
        if component == "VEVENT" { eventCount += 1 }
        continue
      }
      if property.name == "END" {
        guard stack.last == property.value.uppercased() else {
          throw CalendarInvitationParsingError.invalidInvitation
        }
        stack.removeLast()
        continue
      }
      if stack == ["VCALENDAR"] {
        calendarProperties.append(property)
      } else if stack.last == "VEVENT" {
        eventProperties.append(property)
      }
    }
    guard stack.isEmpty, eventCount == 1, !eventProperties.isEmpty else {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    if let method = calendarProperties.first(where: { $0.name == "METHOD" }) {
      eventProperties.append(method)
    }
    return eventProperties
  }

  private static func unfoldedLines(in text: String) throws -> [String] {
    let physicalLines =
      text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard physicalLines.count <= maximumLineCount else {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    var result: [String] = []
    for line in physicalLines where !line.isEmpty {
      guard line.utf8.count <= maximumLineByteCount else {
        throw CalendarInvitationParsingError.invalidInvitation
      }
      if line.first == " " || line.first == "\t" {
        guard !result.isEmpty else { throw CalendarInvitationParsingError.invalidInvitation }
        result[result.count - 1].append(contentsOf: line.dropFirst())
        guard result[result.count - 1].utf8.count <= maximumLineByteCount else {
          throw CalendarInvitationParsingError.invalidInvitation
        }
      } else {
        result.append(line)
      }
    }
    return result
  }

  private static func parsedProperty(_ line: String) throws -> Property {
    var isQuoted = false
    var separator: String.Index?
    for index in line.indices {
      if line[index] == "\"" { isQuoted.toggle() }
      if line[index] == ":", !isQuoted {
        separator = index
        break
      }
    }
    guard let separator else { throw CalendarInvitationParsingError.invalidInvitation }
    let declaration = line[..<separator].split(separator: ";", omittingEmptySubsequences: false)
    guard let rawName = declaration.first, !rawName.isEmpty else {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    var parameters: [String: String] = [:]
    for parameter in declaration.dropFirst() {
      let components = parameter.split(
        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard components.count == 2 else { throw CalendarInvitationParsingError.invalidInvitation }
      parameters[String(components[0]).uppercased()] = String(components[1])
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    return Property(
      name: String(rawName).uppercased(),
      parameters: parameters,
      value: String(line[line.index(after: separator)...])
    )
  }

  private static func value(named name: String, in properties: [Property]) -> String? {
    properties.first { $0.name == name }?.value
  }

  private static func dateValue(
    _ property: Property,
    floatingTimeZone: TimeZone?
  ) throws -> Date {
    let value = property.value
    if property.parameters["VALUE"]?.uppercased() == "DATE" || value.count == 8 {
      return try date(
        value,
        format: "yyyyMMdd",
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    if value.hasSuffix("Z") {
      return try date(
        value,
        format: value.count == 16 ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmm'Z'",
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    }
    let declaredTimeZone = property.parameters["TZID"].flatMap(TimeZone.init(identifier:))
    guard let timeZone = declaredTimeZone ?? floatingTimeZone else {
      throw CalendarInvitationParsingError.ambiguousTime
    }
    return try date(
      value,
      format: value.count == 15 ? "yyyyMMdd'T'HHmmss" : "yyyyMMdd'T'HHmm",
      timeZone: timeZone
    )
  }

  private static func date(_ value: String, format: String, timeZone: TimeZone) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = format
    formatter.isLenient = false
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    guard let result = formatter.date(from: value), formatter.string(from: result) == value else {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    return result
  }

  private static func durationInterval(_ value: String) throws -> TimeInterval {
    let expression = try NSRegularExpression(
      pattern: #"^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range) else {
      throw CalendarInvitationParsingError.invalidInvitation
    }
    func integer(at index: Int, maximum: Int) throws -> Int {
      guard let range = Range(match.range(at: index), in: value) else { return 0 }
      guard let result = Int(value[range]), result <= maximum else {
        throw CalendarInvitationParsingError.invalidInvitation
      }
      return result
    }
    let weeks = try integer(at: 1, maximum: 5_228)
    let days = try integer(at: 2, maximum: 36_600)
    let hours = try integer(at: 3, maximum: 23)
    let minutes = try integer(at: 4, maximum: 59)
    let seconds = try integer(at: 5, maximum: 59)
    let interval = weeks * 604_800 + days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    guard interval > 0 else { throw CalendarInvitationParsingError.invalidInvitation }
    return TimeInterval(interval)
  }

  private static func resolvedTimeZoneIdentifier(
    for property: Property?,
    floatingTimeZone: TimeZone?
  ) -> String? {
    guard let property, property.parameters["VALUE"]?.uppercased() != "DATE" else { return nil }
    if property.value.hasSuffix("Z") { return "UTC" }
    return property.parameters["TZID"].flatMap(TimeZone.init(identifier:))?.identifier
      ?? floatingTimeZone?.identifier
  }

  private static func unescapedText(_ value: String) -> String {
    var result = ""
    var iterator = value.makeIterator()
    while let character = iterator.next() {
      guard character == "\\", let escaped = iterator.next() else {
        result.append(character)
        continue
      }
      switch escaped {
      case "n", "N": result.append("\n")
      case ",": result.append(",")
      case ";": result.append(";")
      case "\\": result.append("\\")
      default:
        result.append("\\")
        result.append(escaped)
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
