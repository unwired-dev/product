import Foundation
import Testing

@testable import unwired_mail

@Suite(.serialized)
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

    let recurring = Data(
      """
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      UID:event-001
      DTSTART:20260813T090000Z
      RRULE:FREQ=DAILY
      SUMMARY:Meeting
      END:VEVENT
      END:VCALENDAR
      """.utf8
    )
    #expect(throws: CalendarInvitationParsingError.unsupportedRecurrence) {
      try CalendarInvitationParser.parse(recurring)
    }
    #expect(throws: CalendarInvitationParsingError.invitationTooLarge) {
      try CalendarInvitationParser.parse(
        Data(repeating: 65, count: CalendarInvitationDescriptor.maximumByteCount + 1)
      )
    }
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
        SUMMARY:\(summary)
        END:VEVENT
        END:VCALENDAR
        """.utf8
      )
    )
  }
}
