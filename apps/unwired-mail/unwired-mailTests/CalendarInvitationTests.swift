import Foundation
import Testing

@testable import unwired_mail

// swiftlint:disable file_length
@Suite(.serialized)
// swiftlint:disable:next type_body_length
final class CalendarInvitationTests {
  @Test
  func testParserReadsBoundedRequestWithUTCAndFoldedText() throws {
    let candidate = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        METHOD:REQUEST\r
        BEGIN:VEVENT\r
        UID:event-001@example.com\r
        SEQUENCE:2\r
        DTSTART:20260813T090000Z\r
        DTEND:20260813T100000Z\r
        SUMMARY:Product\\, planning\r
        DESCRIPTION:First line\\nSecond \r
         line\r
        LOCATION:Prague\\; Office\r
        END:VEVENT\r
        END:VCALENDAR\r

        """.utf8
      )
    )

    #expect(candidate.uid == "event-001@example.com")
    #expect(candidate.sequence == 2)
    #expect(candidate.summary == "Product, planning")
    #expect(candidate.notes == "First line\nSecond line")
    #expect(candidate.location == "Prague; Office")
    #expect(candidate.method == .request)
    #expect(candidate.timeZoneIdentifier == "UTC")
    #expect(candidate.startDate?.timeIntervalSince1970 == 1_786_611_600)
    #expect(candidate.endDate?.timeIntervalSince1970 == 1_786_615_200)
  }

  @Test
  func testParserUsesNextLocalMidnightForImplicitAllDayDefaultEndAcrossDST() throws {
    let localTimeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let candidate = try CalendarInvitationParser.parse(
      Data(
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nDTSTART:20260308\nEND:VEVENT\nEND:VCALENDAR"
          .utf8
      ),
      floatingTimeZone: localTimeZone
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = localTimeZone
    let end = calendar.dateComponents(
      [.day, .hour],
      from: try #require(candidate.endDate)
    )

    #expect(candidate.isAllDay)
    #expect(candidate.timeZoneIdentifier == nil)
    #expect(end.day == 9)
    #expect(end.hour == 0)
    #expect(
      try #require(candidate.endDate).timeIntervalSince(try #require(candidate.startDate)) == 82_800
    )
  }

  @Test
  func testParserUsesCalendarDaysForAllDayDurationAcrossDST() throws {
    let localTimeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let candidate = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        DTSTART;VALUE=DATE:20260308
        DURATION:P1D
        END:VEVENT
        END:VCALENDAR
        """.utf8
      ),
      floatingTimeZone: localTimeZone
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = localTimeZone
    let end = calendar.dateComponents([.day, .hour], from: try #require(candidate.endDate))

    #expect(end.day == 9)
    #expect(end.hour == 0)
    #expect(
      try #require(candidate.endDate).timeIntervalSince(try #require(candidate.startDate)) == 82_800
    )
  }

  @Test
  func testParserRejectsInvalidDurationForms() {
    let invitations = [
      """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:event-001
      DTSTART:20260813T090000Z
      DURATION:P1W1D
      END:VEVENT
      END:VCALENDAR
      """,
      """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:event-001
      DTSTART:20260813T090000Z
      DURATION:P1WT1H
      END:VEVENT
      END:VCALENDAR
      """,
      """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:event-001
      DTSTART;VALUE=DATE:20260813
      DURATION:P1DT1H
      END:VEVENT
      END:VCALENDAR
      """,
    ]

    for invitation in invitations {
      #expect(throws: CalendarInvitationParsingError.invalidInvitation) {
        try CalendarInvitationParser.parse(Data(invitation.utf8))
      }
    }
  }

  @Test
  func testParserNormalizesOverflowingTimedDurationUnits() throws {
    let durations = [
      (value: "PT36H", expectedInterval: 129_600.0),
      (value: "PT90M", expectedInterval: 5_400.0),
    ]

    for duration in durations {
      let candidate = try CalendarInvitationParser.parse(
        Data(
          """
          BEGIN:VCALENDAR
          BEGIN:VEVENT
          UID:event-001
          DTSTART:20260813T090000Z
          DURATION:\(duration.value)
          END:VEVENT
          END:VCALENDAR
          """.utf8
        )
      )

      #expect(
        try #require(candidate.endDate).timeIntervalSince(try #require(candidate.startDate))
          == duration.expectedInterval
      )
    }
  }

  @Test
  func testTimedCalendarDayDurationPreservesLocalTimeAcrossDST() throws {
    let localTimeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let candidate = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        DTSTART;TZID=America/Los_Angeles:20260308T010000
        DURATION:P1D
        END:VEVENT
        END:VCALENDAR
        """.utf8
      ),
      floatingTimeZone: localTimeZone
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = localTimeZone
    let end = try #require(candidate.endDate)

    #expect(calendar.component(.hour, from: end) == 1)
    #expect(end.timeIntervalSince(try #require(candidate.startDate)) == 82_800)
  }

  @Test
  func testCalendarNotesPreserveExistingValueWhenDescriptionIsAbsent() throws {
    let withoutNotes = try candidate(
      sequence: 1,
      start: "20260813T090000Z",
      summary: "Meeting"
    )
    let withNotes = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        DTSTART:20260813T090000Z
        DURATION:PT1H
        DESCRIPTION:Organizer note
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )

    #expect(withoutNotes.notesForCalendar(preserving: "Personal note") == "Personal note")
    #expect(withNotes.notesForCalendar(preserving: "Personal note") == "Organizer note")
  }

  @Test
  func testCalendarLocationPreservesExistingValueWhenLocationIsAbsent() throws {
    let withoutLocation = try candidate(
      sequence: 1,
      start: "20260813T090000Z",
      summary: "Meeting"
    )
    let withLocation = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        DTSTART:20260813T090000Z
        DURATION:PT1H
        LOCATION:Prague Office
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )

    #expect(
      withoutLocation.locationForCalendar(preserving: "Personal location") == "Personal location"
    )
    #expect(withLocation.locationForCalendar(preserving: "Personal location") == "Prague Office")
  }

  @Test
  // swiftlint:disable:next function_body_length
  func testParserRejectsAmbiguousTimeOversizedInputAndRecurrence() throws {
    let ambiguous = Data(
      """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:event-001
      DTSTART:20260813T090000
      SUMMARY:Meeting
      END:VEVENT
      END:VCALENDAR
      """.utf8
    )
    #expect(throws: CalendarInvitationParsingError.ambiguousTime) {
      try CalendarInvitationParser.parse(ambiguous)
    }

    for recurrenceProperty in [
      "RRULE:FREQ=DAILY",
      "RDATE:20260814T090000Z",
      "EXRULE:FREQ=WEEKLY",
      "EXDATE:20260814T090000Z",
      "RECURRENCE-ID:20260813T090000Z",
    ] {
      let recurring = Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        DTSTART:20260813T090000Z
        \(recurrenceProperty)
        SUMMARY:Meeting
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
      #expect(throws: CalendarInvitationParsingError.unsupportedRecurrence) {
        try CalendarInvitationParser.parse(recurring)
      }
    }
    #expect(throws: CalendarInvitationParsingError.invitationTooLarge) {
      try CalendarInvitationParser.parse(
        Data(repeating: 65, count: CalendarInvitationDescriptor.maximumByteCount + 1)
      )
    }

    // swiftlint:disable line_length
    let invalidInvitations = [
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20260813T090000Z\nEND:VEVENT\nEND:VCALENDAR",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:\nDTSTART:20260813T090000Z\nEND:VEVENT\nEND:VCALENDAR",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nDTSTART:20260813T090000Z\nEND:VCALENDAR",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nDTSTART:20260813T090000Z\nEND:VEVENT\nBEGIN:VEVENT\nUID:event-002\nDTSTART:20260813T100000Z\nEND:VEVENT\nEND:VCALENDAR",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nDTSTART:20260813T090000Z\nDTEND:20260813T090000Z\nEND:VEVENT\nEND:VCALENDAR",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nDTSTART:20260813T090000Z\nEND:VEVENT\nEND:VCALENDAR",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nDTSTART:20260813T090000Z\nSUMMARY:\(String(repeating: "A", count: 17_000))\nEND:VEVENT\nEND:VCALENDAR",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nSEQUENCE:abc\nDTSTART:20260813T090000Z\nEND:VEVENT\nEND:VCALENDAR",
    ]
    // swiftlint:enable line_length
    for invitation in invalidInvitations {
      #expect(throws: CalendarInvitationParsingError.invalidInvitation) {
        try CalendarInvitationParser.parse(Data(invitation.utf8))
      }
    }

    let localTimeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let allDay = try CalendarInvitationParser.parse(
      Data(
        "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:event-001\nDTSTART;VALUE=date:20260813\nEND:VEVENT\nEND:VCALENDAR"
          .utf8
      ),
      floatingTimeZone: localTimeZone
    )
    #expect(allDay.isAllDay)
    #expect(
      Calendar(identifier: .gregorian).dateComponents(
        in: localTimeZone,
        from: try #require(allDay.startDate)
      ).day == 13
    )
    #expect(
      try #require(allDay.endDate).timeIntervalSince(try #require(allDay.startDate)) == 86_400)

    let weekly = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        DTSTART:20260813T090000Z
        DURATION:P1W
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )
    #expect(
      try #require(weekly.endDate).timeIntervalSince(try #require(weekly.startDate)) == 604_800)
  }

  @Test
  func testCancellationRequiresUIDButNotEventTimes() throws {
    let candidate = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:event-001@example.com
        SEQUENCE:3
        STATUS:CANCELLED
        SUMMARY:Cancelled meeting
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )

    #expect(candidate.method == .cancel)
    #expect(candidate.startDate == nil)
    #expect(candidate.endDate == nil)
  }

  @Test
  func testParserRejectsNonInvitationCalendarMethods() {
    #expect(throws: CalendarInvitationParsingError.invalidInvitation) {
      try CalendarInvitationParser.parse(
        Data(
          """
          BEGIN:VCALENDAR
          METHOD:REPLY
          BEGIN:VEVENT
          UID:event-001
          DTSTART:20260813T090000Z
          END:VEVENT
          END:VCALENDAR
          """.utf8
        )
      )
    }
  }

  @Test
  func testDescriptorKeepsOpaqueDismissalOnlyForSameProviderPart() {
    let previous = CalendarInvitationDescriptor(
      byteCount: 500,
      dismissalIdentifier: "opaque-dismissal",
      mimeType: "text/calendar",
      providerAttachmentId: "attachment-001",
      providerPartId: "2"
    )
    let same = CalendarInvitationDescriptor(
      byteCount: 500,
      mimeType: "text/calendar",
      providerAttachmentId: "attachment-001",
      providerPartId: "2"
    ).preservingDismissalIdentifier(from: previous)
    let changed = CalendarInvitationDescriptor(
      byteCount: 501,
      mimeType: "text/calendar",
      providerAttachmentId: "attachment-001",
      providerPartId: "2"
    ).preservingDismissalIdentifier(from: previous)

    #expect(same.dismissalIdentifier == "opaque-dismissal")
    #expect(changed.dismissalIdentifier != "opaque-dismissal")
    #expect(!same.dismissalIdentifier.contains("event"))
  }

  @Test
  func testDescriptorDerivesStableOpaqueDismissalFromProviderIdentity() {
    func descriptor(providerMessageIdentity: String) -> CalendarInvitationDescriptor {
      CalendarInvitationDescriptor(
        byteCount: 500,
        mimeType: "text/calendar",
        providerAttachmentId: "attachment-001",
        providerMessageIdentity: providerMessageIdentity,
        providerPartId: "2"
      )
    }

    let first = descriptor(providerMessageIdentity: "gmail:account-001:message-001")
    let same = descriptor(providerMessageIdentity: "gmail:account-001:message-001")
    let otherAccount = descriptor(providerMessageIdentity: "gmail:account-002:message-001")

    #expect(first.dismissalIdentifier == same.dismissalIdentifier)
    #expect(first.dismissalIdentifier != otherAccount.dismissalIdentifier)
    #expect(first.dismissalIdentifier.count == 64)
    #expect(!first.dismissalIdentifier.contains("message"))
  }

  @Test
  func testReviewDecisionCoversCreateDuplicateAndUpdate() throws {
    let initial = try candidate(sequence: 1, start: "20260813T090000Z", summary: "Meeting")
    let mapping = CalendarEventMapping(
      eventIdentifier: "calendar-event-001",
      fingerprint: initial.fingerprint,
      sequence: initial.sequence
    )
    let updated = try candidate(
      sequence: 2,
      start: "20260813T100000Z",
      summary: "Updated meeting"
    )
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: initial,
        mapping: nil,
        existingEventIdentifier: nil
      ) == .create
    )
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: initial,
        mapping: mapping,
        existingEventIdentifier: mapping.eventIdentifier
      ) == .alreadyAdded
    )
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: updated,
        mapping: mapping,
        existingEventIdentifier: mapping.eventIdentifier
      ) == .update
    )
  }

  @Test
  func testReviewDecisionDistinguishesAbsentFieldsFromExplicitClears() throws {
    let absent = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        SEQUENCE:1
        DTSTART:20260813T090000Z
        DURATION:PT1H
        SUMMARY:Meeting
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )
    let cleared = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        SEQUENCE:1
        DTSTART:20260813T090000Z
        DURATION:PT1H
        SUMMARY:Meeting
        LOCATION:
        DESCRIPTION:
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )
    let mapping = CalendarEventMapping(
      eventIdentifier: "calendar-event-001",
      fingerprint: absent.fingerprint,
      sequence: absent.sequence
    )

    #expect(absent.location == nil)
    #expect(absent.notes == nil)
    #expect(cleared.location == "")
    #expect(cleared.notes == "")
    #expect(absent.fingerprint != cleared.fingerprint)
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: cleared,
        mapping: mapping,
        existingEventIdentifier: mapping.eventIdentifier
      ) == .update
    )
  }

  @Test
  func testReviewDecisionCoversCancellation() throws {
    let cancelled = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:event-001
        SEQUENCE:3
        STATUS:CANCELLED
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: cancelled,
        mapping: nil,
        existingEventIdentifier: "calendar-event-001"
      ) == .remove
    )
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: cancelled,
        mapping: nil,
        existingEventIdentifier: nil
      ) == .alreadyRemoved
    )
    let review = CalendarEventReview(
      action: .alreadyRemoved,
      candidate: cancelled,
      existingEventIdentifier: nil,
      productAccountId: "product-account-001",
      providerAccountIdentifier: "gmail-account-001"
    )
    #expect(review.requiresApply)
  }

  @Test
  func testCancellationReviewShowsMatchedEventDetails() throws {
    let cancelled = try CalendarInvitationParser.parse(
      Data(
        "BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nUID:event-001\nSEQUENCE:3\nEND:VEVENT\nEND:VCALENDAR"
          .utf8
      )
    )
    let startDate = Date(timeIntervalSince1970: 1_786_608_000)
    let endDate = Date(timeIntervalSince1970: 1_786_611_600)
    let review = CalendarEventReview(
      action: .remove,
      candidate: cancelled,
      existingEventEndDate: endDate,
      existingEventIdentifier: "calendar-event-001",
      existingEventStartDate: startDate,
      existingEventTitle: "Matched calendar event",
      productAccountId: "product-account-001",
      providerAccountIdentifier: "gmail-account-001"
    )

    #expect(review.reviewedTitle == "Matched calendar event")
    #expect(review.reviewedStartDate == startDate)
    #expect(review.reviewedEndDate == endDate)
  }

  @Test
  func testReviewDecisionDoesNotApplyStaleUpdatesOrCancellations() throws {
    let current = try candidate(sequence: 2, start: "20260813T100000Z", summary: "Current")
    let mapping = CalendarEventMapping(
      eventIdentifier: "calendar-event-001",
      fingerprint: current.fingerprint,
      sequence: current.sequence
    )
    let staleUpdate = try candidate(sequence: 1, start: "20260813T090000Z", summary: "Stale")
    let staleCancellation = try CalendarInvitationParser.parse(
      Data(
        "BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nUID:event-001\nSEQUENCE:1\nEND:VEVENT\nEND:VCALENDAR"
          .utf8
      )
    )

    #expect(
      CalendarEventReviewAction.resolve(
        candidate: staleUpdate,
        mapping: mapping,
        existingEventIdentifier: mapping.eventIdentifier
      ) == .alreadyAdded
    )
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: staleCancellation,
        mapping: mapping,
        existingEventIdentifier: mapping.eventIdentifier
      ) == .alreadyAdded
    )
  }

  @Test
  func testReviewDecisionKeepsCancellationTombstoneForStaleRequests() throws {
    let cancellation = try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        METHOD:CANCEL
        BEGIN:VEVENT
        UID:event-001
        SEQUENCE:3
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )
    let tombstone = CalendarEventMapping(
      eventIdentifier: nil,
      fingerprint: cancellation.fingerprint,
      sequence: cancellation.sequence
    )
    let staleRequest = try candidate(
      sequence: 2,
      start: "20260813T090000Z",
      summary: "Stale meeting"
    )
    let sameSequenceRequest = try candidate(
      sequence: 3,
      start: "20260813T090000Z",
      summary: "Original meeting"
    )

    #expect(
      CalendarEventReviewAction.resolve(
        candidate: staleRequest,
        mapping: tombstone,
        existingEventIdentifier: nil
      ) == .alreadyRemoved
    )
    #expect(
      CalendarEventReviewAction.resolve(
        candidate: sameSequenceRequest,
        mapping: tombstone,
        existingEventIdentifier: nil
      ) == .alreadyRemoved
    )
    let review = CalendarEventReview(
      action: .alreadyRemoved,
      candidate: staleRequest,
      existingEventIdentifier: nil,
      productAccountId: "product-account-001",
      providerAccountIdentifier: "gmail-account-001"
    )
    #expect(!review.requiresApply)
  }

  @Test
  func testCalendarEventMappingsAreScopedAndClearWithAccountState() throws {
    let suiteName = "calendar-event-mappings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CalendarEventMappingStore(defaults: defaults)
    let mapping = CalendarEventMapping(
      eventIdentifier: "event-001",
      calendarItemIdentifier: "stable-event-001",
      fingerprint: "fingerprint-001",
      sequence: 2
    )

    store.save(
      mapping,
      for: "opaque-uid",
      productAccountId: "product-account-001",
      providerAccountIdentifier: "gmail-account-001"
    )
    store.saveNewest(
      CalendarEventMapping(
        eventIdentifier: nil,
        fingerprint: "stale-fingerprint",
        sequence: 1
      ),
      for: "opaque-uid",
      productAccountId: "product-account-001",
      providerAccountIdentifier: "gmail-account-001"
    )

    #expect(
      store.mapping(
        for: "opaque-uid",
        productAccountId: "product-account-001",
        providerAccountIdentifier: "gmail-account-001"
      ) == mapping
    )
    #expect(
      store.mapping(
        for: "opaque-uid",
        productAccountId: "product-account-001",
        providerAccountIdentifier: "gmail-account-002"
      ) == nil
    )
    store.clear(productAccountId: "product-account-001")
    #expect(
      store.mapping(
        for: "opaque-uid",
        productAccountId: "product-account-001",
        providerAccountIdentifier: "gmail-account-001"
      ) == nil
    )
  }

  @MainActor
  @Test
  func testCalendarInvitationCardModelHandlesSuccessCancellationAndErrors() async throws {
    let candidate = try candidate(sequence: 1, start: "20260813T090000Z", summary: "Meeting")
    let expected = CalendarEventReview(
      action: .create,
      candidate: candidate,
      existingEventIdentifier: nil,
      productAccountId: "product-account-001",
      providerAccountIdentifier: "gmail-account-001"
    )
    let model = CalendarInvitationCardModel()
    var presented: CalendarEventReview?

    await model.prepare(loadReview: { expected }, review: { presented = $0 })
    #expect(presented == expected)
    #expect(model.errorMessage == nil)
    #expect(!model.isLoading)

    await model.prepare(
      loadReview: { throw CancellationError() },
      review: { _ in
        Issue.record("Cancellation must not present a review")
      })
    #expect(model.errorMessage == nil)

    await model.prepare(
      loadReview: { throw CalendarEventReviewError.calendarAccessDenied },
      review: { _ in
        Issue.record("An error must not present a review")
      })
    #expect(
      model.errorMessage == CalendarEventReviewError.calendarAccessDenied.localizedDescription)
    #expect(model.canOpenSettings)
    await model.prepare(
      loadReview: { throw CalendarInvitationParsingError.invalidInvitation },
      review: { _ in Issue.record("A parser error must not present a review") }
    )
    #expect(!model.canOpenSettings)
    #expect(!model.isLoading)
  }

  private func candidate(
    sequence: Int,
    start: String,
    summary: String
  ) throws -> CalendarInvitationCandidate {
    try CalendarInvitationParser.parse(
      Data(
        """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:event-001
        SEQUENCE:\(sequence)
        DTSTART:\(start)
        DURATION:PT1H
        SUMMARY:\(summary)
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )
  }
}
