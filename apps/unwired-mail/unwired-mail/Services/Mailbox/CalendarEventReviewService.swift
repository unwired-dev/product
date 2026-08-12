import EventKit
import Foundation

enum CalendarEventReviewAction: Equatable, Sendable {
  case alreadyAdded
  case alreadyRemoved
  case create
  case remove
  case update

  static func resolve(
    candidate: CalendarInvitationCandidate,
    mapping: CalendarEventMapping?,
    existingEventIdentifier: String?
  ) -> Self {
    if let mapping, mapping.sequence > candidate.sequence {
      return existingEventIdentifier == nil ? .alreadyRemoved : .alreadyAdded
    }
    if candidate.method == .cancel {
      return existingEventIdentifier == nil ? .alreadyRemoved : .remove
    }
    if let mapping, mapping.fingerprint == candidate.fingerprint,
      mapping.sequence >= candidate.sequence,
      existingEventIdentifier != nil
    {
      return .alreadyAdded
    }
    return existingEventIdentifier == nil ? .create : .update
  }
}

struct CalendarEventReview: Identifiable, Equatable, Sendable {
  let action: CalendarEventReviewAction
  let candidate: CalendarInvitationCandidate
  let existingEventIdentifier: String?
  let productAccountId: String
  let providerAccountIdentifier: String
  let id = UUID()
}

struct CalendarEventMapping: Codable, Equatable {
  let eventIdentifier: String?
  let fingerprint: String
  let sequence: Int
}

struct CalendarEventMappingStore {
  private static let keyPrefix = "calendar-invitation.event-mappings."
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) {
    let prefix = Self.keyPrefix + productAccountId + "."
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
  }

  func clear(productAccountId: String, providerAccountIdentifier: String) {
    defaults.removeObject(forKey: key(productAccountId, providerAccountIdentifier))
  }

  func mapping(
    for opaqueUID: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> CalendarEventMapping? {
    mappings(productAccountId, providerAccountIdentifier)[opaqueUID]
  }

  func save(
    _ mapping: CalendarEventMapping,
    for opaqueUID: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) {
    var values = mappings(productAccountId, providerAccountIdentifier)
    values[opaqueUID] = mapping
    defaults.set(
      try? JSONEncoder().encode(values),
      forKey: key(productAccountId, providerAccountIdentifier)
    )
  }

  func saveNewest(
    _ mapping: CalendarEventMapping,
    for opaqueUID: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) {
    let existing = self.mapping(
      for: opaqueUID,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    guard existing?.sequence ?? -1 <= mapping.sequence else { return }
    save(
      mapping,
      for: opaqueUID,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }

  private func key(_ productAccountId: String, _ providerAccountIdentifier: String) -> String {
    Self.keyPrefix + productAccountId + "." + providerAccountIdentifier
  }

  private func mappings(
    _ productAccountId: String,
    _ providerAccountIdentifier: String
  ) -> [String: CalendarEventMapping] {
    guard let data = defaults.data(forKey: key(productAccountId, providerAccountIdentifier))
    else { return [:] }
    return (try? JSONDecoder().decode([String: CalendarEventMapping].self, from: data)) ?? [:]
  }
}

enum CalendarEventReviewError: LocalizedError {
  case calendarAccessDenied
  case missingDefaultCalendar
  case missingEvent

  var errorDescription: String? {
    switch self {
    case .calendarAccessDenied:
      "Calendar access is off. The invitation was kept so you can try again from Settings."
    case .missingDefaultCalendar:
      "No writable default calendar is available."
    case .missingEvent:
      "The existing calendar event is no longer available. Review the invitation again."
    }
  }
}

@MainActor
final class CalendarEventReviewService {
  private let eventStore: EKEventStore
  private let mappingStore: CalendarEventMappingStore

  init(
    eventStore: EKEventStore = EKEventStore(),
    userDefaults: UserDefaults = .standard
  ) {
    self.eventStore = eventStore
    mappingStore = CalendarEventMappingStore(defaults: userDefaults)
  }

  func prepare(
    _ candidate: CalendarInvitationCandidate,
    productAccountId: String,
    providerAccountIdentifier: String
  ) async throws -> CalendarEventReview {
    guard try await requestAccess() else { throw CalendarEventReviewError.calendarAccessDenied }
    let mapping = mappingStore.mapping(
      for: candidate.opaqueUID,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
    let existing = existingEvent(for: candidate, mapping: mapping)
    let action = CalendarEventReviewAction.resolve(
      candidate: candidate,
      mapping: mapping,
      existingEventIdentifier: existing?.eventIdentifier
    )
    return CalendarEventReview(
      action: action,
      candidate: candidate,
      existingEventIdentifier: existing?.eventIdentifier,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }

  func apply(_ review: CalendarEventReview) throws {
    switch review.action {
    case .alreadyAdded:
      return
    case .alreadyRemoved:
      if review.candidate.method == .cancel { saveCancellationTombstone(review) }
    case .remove:
      try remove(review)
    case .create, .update:
      try save(review)
    }
  }

  private func remove(_ review: CalendarEventReview) throws {
    guard let identifier = review.existingEventIdentifier,
      let event = eventStore.event(withIdentifier: identifier)
    else {
      saveCancellationTombstone(review)
      throw CalendarEventReviewError.missingEvent
    }
    try eventStore.remove(event, span: .thisEvent, commit: true)
    saveCancellationTombstone(review)
  }

  private func saveCancellationTombstone(_ review: CalendarEventReview) {
    mappingStore.saveNewest(
      CalendarEventMapping(
        eventIdentifier: nil,
        fingerprint: review.candidate.fingerprint,
        sequence: review.candidate.sequence
      ),
      for: review.candidate.opaqueUID,
      productAccountId: review.productAccountId,
      providerAccountIdentifier: review.providerAccountIdentifier
    )
  }

  private func save(_ review: CalendarEventReview) throws {
    let event = try writableEvent(for: review)
    event.title = review.candidate.summary
    event.startDate = review.candidate.startDate
    event.endDate = review.candidate.endDate
    event.isAllDay = review.candidate.isAllDay
    event.location = review.candidate.location
    event.notes = review.candidate.notes
    if let identifier = review.candidate.timeZoneIdentifier {
      event.timeZone = TimeZone(identifier: identifier)
    }
    try eventStore.save(event, span: .thisEvent, commit: true)
    guard let identifier = event.eventIdentifier else {
      throw CalendarEventReviewError.missingEvent
    }
    mappingStore.save(
      CalendarEventMapping(
        eventIdentifier: identifier,
        fingerprint: review.candidate.fingerprint,
        sequence: review.candidate.sequence
      ),
      for: review.candidate.opaqueUID,
      productAccountId: review.productAccountId,
      providerAccountIdentifier: review.providerAccountIdentifier
    )
  }

  private func writableEvent(for review: CalendarEventReview) throws -> EKEvent {
    if review.action == .update {
      guard let identifier = review.existingEventIdentifier,
        let existing = eventStore.event(withIdentifier: identifier)
      else { throw CalendarEventReviewError.missingEvent }
      return existing
    }
    let event = EKEvent(eventStore: eventStore)
    guard let calendar = eventStore.defaultCalendarForNewEvents else {
      throw CalendarEventReviewError.missingDefaultCalendar
    }
    event.calendar = calendar
    return event
  }

  private func requestAccess() async throws -> Bool {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
      return true
    case .notDetermined:
      return try await eventStore.requestFullAccessToEvents()
    case .denied, .restricted, .writeOnly:
      return false
    @unknown default:
      return false
    }
  }

  private func existingEvent(
    for candidate: CalendarInvitationCandidate,
    mapping: CalendarEventMapping?
  ) -> EKEvent? {
    if let identifier = mapping?.eventIdentifier,
      let event = eventStore.event(withIdentifier: identifier)
    {
      return event
    }
    guard let start = candidate.startDate, let end = candidate.endDate else { return nil }
    let predicate = eventStore.predicateForEvents(
      withStart: start.addingTimeInterval(-86_400),
      end: end.addingTimeInterval(86_400),
      calendars: nil
    )
    return eventStore.events(matching: predicate).first {
      $0.calendarItemExternalIdentifier == candidate.uid
    }
  }
}
