import EventKit
import Foundation

// swiftlint:disable file_length

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
    if let mapping, mapping.eventIdentifier == nil, mapping.sequence >= candidate.sequence {
      return .alreadyRemoved
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

enum CalendarEventReviewOrigin: Equatable, Sendable {
  case prose(duplicateFingerprint: Bool)
  case structuredInvitation

  var isProse: Bool {
    if case .prose = self { return true }
    return false
  }

  var warnsAboutDuplicate: Bool {
    if case .prose(let duplicateFingerprint) = self { return duplicateFingerprint }
    return false
  }
}

struct CalendarEventReview: Identifiable, Equatable, Sendable {
  let action: CalendarEventReviewAction
  let candidate: CalendarInvitationCandidate
  let existingEventEndDate: Date?
  let existingEventIdentifier: String?
  let existingEventStartDate: Date?
  let existingEventTitle: String?
  let origin: CalendarEventReviewOrigin
  let productAccountId: String
  let providerAccountIdentifier: String
  let id = UUID()

  init(
    action: CalendarEventReviewAction,
    candidate: CalendarInvitationCandidate,
    existingEventEndDate: Date? = nil,
    existingEventIdentifier: String?,
    existingEventStartDate: Date? = nil,
    existingEventTitle: String? = nil,
    origin: CalendarEventReviewOrigin = .structuredInvitation,
    productAccountId: String,
    providerAccountIdentifier: String
  ) {
    self.action = action
    self.candidate = candidate
    self.existingEventEndDate = existingEventEndDate
    self.existingEventIdentifier = existingEventIdentifier
    self.existingEventStartDate = existingEventStartDate
    self.existingEventTitle = existingEventTitle
    self.origin = origin
    self.productAccountId = productAccountId
    self.providerAccountIdentifier = providerAccountIdentifier
  }

  var reviewedEndDate: Date? {
    action == .remove ? existingEventEndDate ?? candidate.endDate : candidate.endDate
  }

  var reviewedStartDate: Date? {
    action == .remove ? existingEventStartDate ?? candidate.startDate : candidate.startDate
  }

  var reviewedTitle: String {
    if action == .remove, let existingEventTitle, !existingEventTitle.isEmpty {
      return existingEventTitle
    }
    return candidate.summary
  }

  var requiresApply: Bool {
    switch action {
    case .alreadyAdded:
      false
    case .alreadyRemoved:
      candidate.method == .cancel
    case .create, .remove, .update:
      true
    }
  }
}

struct CalendarEventMapping: Codable, Equatable {
  let eventIdentifier: String?
  let calendarItemIdentifier: String?
  let fingerprint: String
  let sequence: Int

  init(
    eventIdentifier: String?,
    calendarItemIdentifier: String? = nil,
    fingerprint: String,
    sequence: Int
  ) {
    self.eventIdentifier = eventIdentifier
    self.calendarItemIdentifier = calendarItemIdentifier
    self.fingerprint = fingerprint
    self.sequence = sequence
  }
}

struct CalendarEventMappingStore {
  private static let keyPrefix = "calendar-invitation.event-mappings."
  private static let lock = NSLock()
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func clear(productAccountId: String) {
    Self.lock.withLock {
      let prefix = Self.keyPrefix + productAccountId + "."
      for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
        defaults.removeObject(forKey: key)
      }
    }
  }

  func clear(productAccountId: String, providerAccountIdentifier: String) {
    Self.lock.withLock {
      defaults.removeObject(forKey: key(productAccountId, providerAccountIdentifier))
    }
  }

  func mapping(
    for opaqueUID: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) -> CalendarEventMapping? {
    Self.lock.withLock {
      mappings(productAccountId, providerAccountIdentifier)[opaqueUID]
    }
  }

  func containsMapping(
    for opaqueUID: String,
    productAccountId: String
  ) -> Bool {
    Self.lock.withLock {
      let prefix = Self.keyPrefix + productAccountId + "."
      return defaults.dictionaryRepresentation().keys.contains { key in
        key.hasPrefix(prefix) && mappings(forKey: key)[opaqueUID] != nil
      }
    }
  }

  func save(
    _ mapping: CalendarEventMapping,
    for opaqueUID: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) {
    Self.lock.withLock {
      saveUnlocked(
        mapping,
        for: opaqueUID,
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    }
  }

  func saveNewest(
    _ mapping: CalendarEventMapping,
    for opaqueUID: String,
    productAccountId: String,
    providerAccountIdentifier: String
  ) {
    Self.lock.withLock {
      let existing = mappings(productAccountId, providerAccountIdentifier)[opaqueUID]
      guard existing?.sequence ?? -1 <= mapping.sequence else { return }
      saveUnlocked(
        mapping,
        for: opaqueUID,
        productAccountId: productAccountId,
        providerAccountIdentifier: providerAccountIdentifier
      )
    }
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

  private func mappings(forKey key: String) -> [String: CalendarEventMapping] {
    guard let data = defaults.data(forKey: key) else { return [:] }
    return (try? JSONDecoder().decode([String: CalendarEventMapping].self, from: data)) ?? [:]
  }

  private func saveUnlocked(
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
}

enum CalendarEventReviewError: LocalizedError {
  case calendarAccessDenied
  case missingDefaultCalendar
  case missingEvent

  var errorDescription: String? {
    switch self {
    case .calendarAccessDenied:
      "Calendar access is off. The suggestion was kept so you can try again from Settings."
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

  var eventStoreForEditor: EKEventStore { eventStore }

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
      existingEventEndDate: existing?.endDate,
      existingEventIdentifier: existing?.eventIdentifier,
      existingEventStartDate: existing?.startDate,
      existingEventTitle: existing?.title,
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }

  func prepare(
    _ proseCandidate: ProseCalendarEventCandidate,
    productAccountId: String,
    providerAccountIdentifier: String
  ) async throws -> CalendarEventReview {
    let candidate = proseCandidate.calendarCandidate
    let duplicate = mappingStore.containsMapping(
      for: candidate.opaqueUID,
      productAccountId: productAccountId
    )
    return CalendarEventReview(
      action: .create,
      candidate: candidate,
      existingEventIdentifier: nil,
      origin: .prose(duplicateFingerprint: duplicate),
      productAccountId: productAccountId,
      providerAccountIdentifier: providerAccountIdentifier
    )
  }

  func editableProseEvent(for review: CalendarEventReview) -> EKEvent {
    precondition(review.origin.isProse)
    let event = EKEvent(eventStore: eventStore)
    event.calendar = eventStore.defaultCalendarForNewEvents
    event.title = review.candidate.summary
    event.startDate = review.candidate.startDate
    event.endDate = review.candidate.endDate
    if let identifier = review.candidate.timeZoneIdentifier {
      event.timeZone = TimeZone(identifier: identifier)
    }
    return event
  }

  func recordSavedProseEvent(_ event: EKEvent, for review: CalendarEventReview) {
    guard review.origin.isProse, let eventIdentifier = event.eventIdentifier else { return }
    mappingStore.save(
      CalendarEventMapping(
        eventIdentifier: eventIdentifier,
        calendarItemIdentifier: event.calendarItemIdentifier,
        fingerprint: review.candidate.fingerprint,
        sequence: review.candidate.sequence
      ),
      for: review.candidate.opaqueUID,
      productAccountId: review.productAccountId,
      providerAccountIdentifier: review.providerAccountIdentifier
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
        calendarItemIdentifier: nil,
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
    event.location = review.candidate.locationForCalendar(preserving: event.location)
    event.notes = review.candidate.notesForCalendar(preserving: event.notes)
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
        calendarItemIdentifier: event.calendarItemIdentifier,
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
    if let identifier = mapping?.calendarItemIdentifier,
      let event = eventStore.calendarItem(withIdentifier: identifier) as? EKEvent
    {
      return event
    }
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
