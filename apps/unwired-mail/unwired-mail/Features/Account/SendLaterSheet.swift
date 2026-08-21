import SwiftUI

struct SendLaterRequest: Identifiable {
  let id = UUID()
}

struct MailComposerSendButton: View {
  let canSendLater: Bool
  let isSendEnabled: Bool
  let send: () -> Void
  let sendLater: () -> Void

  @State private var suppressSendUntil = Date.distantPast

  var body: some View {
    Button("Send") {
      guard Date.now >= suppressSendUntil, isSendEnabled else { return }
      send()
    }
    .accessibilityIdentifier("mail-compose-send")
    .opacity(isSendEnabled ? 1 : 0.4)
    .contentShape(.rect)
    .onLongPressGesture(minimumDuration: 0.5) {
      guard canSendLater else { return }
      suppressSendUntil = Date.now.addingTimeInterval(1)
      sendLater()
    }
    .accessibilityAction(named: "Send Later") {
      guard canSendLater else { return }
      sendLater()
    }
    .accessibilityHint(accessibilityHint)
  }

  private var accessibilityHint: String {
    if isSendEnabled {
      "Sends now. Press and hold for Send Later."
    } else if canSendLater {
      "Send now is unavailable. Use Send Later to set a reminder."
    } else {
      "Add Draft content before using Send Later."
    }
  }
}

struct SendLaterSheet: View {
  let schedule: @MainActor (Date, String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var errorMessage: String?
  @State private var isSaving = false
  @State private var repeatedTimeChoice: SendReminderRepeatedTimeChoice = .first
  @State private var selectedDate: Date

  private let calendar: Calendar
  private let now: Date
  private let presets: [SendReminderPreset]
  private let timeZone: TimeZone

  init(
    existingReminder: SendReminder?,
    now: Date = .now,
    calendar: Calendar = .current,
    timeZone: TimeZone = .current,
    schedule: @escaping @MainActor (Date, String) async -> Bool
  ) {
    var calendar = calendar
    calendar.timeZone = timeZone
    let presets = SendReminderSchedule.presets(now: now, calendar: calendar)
    self.calendar = calendar
    self.now = now
    self.presets = presets
    self.schedule = schedule
    self.timeZone = timeZone
    let minimumDate = now.addingTimeInterval(60)
    let existingDate = existingReminder?.dueAt
    _selectedDate = State(
      initialValue: existingDate.flatMap { $0 >= minimumDate ? $0 : nil }
        ?? presets.first?.dueAt
        ?? now.addingTimeInterval(60 * 60)
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        if !presets.isEmpty {
          Section("Suggested") {
            ForEach(presets) { preset in
              Button {
                selectedDate = preset.dueAt
                repeatedTimeChoice = .first
                errorMessage = nil
              } label: {
                LabeledContent(preset.title) {
                  Text(preset.dueAt, format: .dateTime.hour().minute())
                }
              }
            }
          }
        }

        Section("Pick Date & Time") {
          DatePicker(
            "Reminder",
            selection: $selectedDate,
            in: minimumDate...maximumDate,
            displayedComponents: [.date, .hourAndMinute]
          )
          if repeatedTimeOptions.count == 2 {
            Picker("Repeated Hour", selection: $repeatedTimeChoice) {
              ForEach(repeatedTimeOptions) { option in
                Text(option.label).tag(option.choice)
              }
            }
          }
          Text("Times use \(timeZoneName). The saved reminder keeps this absolute instant.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          if let validationMessage {
            Text(validationMessage)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }

        Section {
          Text("This keeps the message as a Draft. It will not be sent automatically.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Send Later")
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(isSaving)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Remind Me to Send", action: saveReminder)
            .disabled(resolvedDate == nil || isSaving)
            .accessibilityIdentifier("mail-compose-remind-to-send")
        }
      }
    }
  }

  private var minimumDate: Date {
    now.addingTimeInterval(60)
  }

  private var maximumDate: Date {
    calendar.date(byAdding: .year, value: 1, to: now)
      ?? now.addingTimeInterval(365 * 24 * 60 * 60)
  }

  private var localComponents: DateComponents {
    SendReminderSchedule.localComponents(for: selectedDate, timeZone: timeZone)
  }

  private var repeatedTimeOptions: [SendReminderLocalTimeOption] {
    (try? SendReminderSchedule.repeatedTimeOptions(
      localComponents: localComponents,
      timeZone: timeZone
    )) ?? []
  }

  private var resolvedDate: Date? {
    guard
      let date = try? SendReminderSchedule.resolve(
        localComponents: localComponents,
        timeZone: timeZone,
        repeatedTimeChoice: repeatedTimeChoice
      ),
      SendReminderSchedule.isValid(dueAt: date, now: now, calendar: calendar)
    else { return nil }
    return date
  }

  private var validationMessage: String? {
    if repeatedTimeOptions.isEmpty {
      return SendReminderLocalTimeError.nonexistent.localizedDescription
    }
    if resolvedDate == nil {
      return "Choose a time from one minute through one year from now."
    }
    return errorMessage
  }

  private var timeZoneName: String {
    timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier
  }

  private func saveReminder() {
    guard let resolvedDate else { return }
    isSaving = true
    errorMessage = nil
    Task {
      if await schedule(resolvedDate, timeZone.identifier) {
        dismiss()
      } else {
        errorMessage = "The reminder could not be saved. Review the Draft and try again."
        isSaving = false
      }
    }
  }
}

struct MailComposerReminderSummary: View {
  let notificationState: MailComposerReminderState
  let reminder: SendReminder

  var body: some View {
    LabeledContent {
      Text(reminder.dueAt, format: .dateTime.day().month().hour().minute())
    } label: {
      Label(
        reminder.isOverdue() ? "Send Reminder Overdue" : "Send Reminder",
        systemImage: reminder.isOverdue() ? "clock.badge.exclamationmark" : "clock"
      )
    }
    if case .saved(.unavailable) = notificationState {
      Text("Notifications are unavailable. The reminder will remain visible in Drafts.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    } else if case .failed(let message) = notificationState {
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}
