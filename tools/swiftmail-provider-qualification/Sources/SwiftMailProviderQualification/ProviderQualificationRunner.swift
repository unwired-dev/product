import Foundation
import SwiftMail

// This single-use live qualification contract intentionally mirrors ADR 0027 linearly.
// swiftlint:disable file_length type_body_length

public actor ProviderQualificationRunner {
  private let configuration: QualificationConfiguration
  private let prepareDataset: Bool
  private let runID: String
  private let startedAt = Date()
  private var checks: [QualificationCheck] = []
  private var metrics: [String: QualificationMetrics] = [:]
  private var smtpAccepted = false
  private var smtpDeliveryObserved = false

  public init(configuration: QualificationConfiguration, prepareDataset: Bool) {
    self.configuration = configuration
    self.prepareDataset = prepareDataset
    runID = UUID().uuidString.lowercased()
  }

  // swiftlint:disable:next function_body_length
  public func execute() async -> QualificationReport {
    let endpoint = configuration.imapEndpoint
    let imap = IMAPServer(
      host: endpoint.host,
      port: endpoint.port,
      transportSecurity: endpoint.security,
      certificateVerificationPolicy: .fullVerification,
      minimumTLSVersion: .tlsv12,
      responseBufferLimit: 8 * 1024 * 1024
    )
    var roles: QualificationRoles?
    var passed = false

    do {
      try await perform("authentication", detail: "TLS 1.2+ password authentication passed.") {
        try await imap.connect()
        try await imap.login(
          username: self.configuration.emailAddress,
          password: self.configuration.password
        )
      }
      roles = try await qualifyMailboxRoles(on: imap)
      try await qualifyMailboxCreation(on: imap)
      if prepareDataset {
        try await prepareQualificationDataset(on: imap)
      }
      let backfill = try await qualifyMetadataPerformance(on: imap)
      try await qualifyIncrementalPerformance(on: imap, backfill: backfill)
      try await qualifyBodySearchFlagsAndSpam(on: imap, roles: try required(roles))
      try await qualifyIDLE(on: imap)
      try await qualifySMTPAndSentAppend(on: imap, roles: try required(roles))
      try await perform("run-scoped cleanup", detail: "Only matching UIDs were expunged.") {
        try await self.cleanupRunMessages(on: imap, roles: try self.required(roles))
      }
      try await imap.disconnect()
      passed = true
    } catch {
      recordFailure(error)
      do {
        if let roles {
          try await cleanupRunMessages(on: imap, roles: roles)
          checks.append(
            QualificationCheck(
              name: "failure cleanup",
              passed: true,
              detail: "Run-scoped messages were removed with UID EXPUNGE."
            )
          )
        }
      } catch {
        checks.append(
          QualificationCheck(
            name: "failure cleanup",
            passed: false,
            detail: "Cleanup failed with \(sanitizedErrorType(error))."
          )
        )
      }
      try? await imap.disconnect()
    }

    return QualificationReport(
      checks: checks,
      completedAt: Date(),
      metrics: metrics,
      passed: passed && checks.allSatisfy(\.passed),
      provider: configuration.provider,
      startedAt: startedAt
    )
  }

  private func qualifyMailboxRoles(on imap: IMAPServer) async throws -> QualificationRoles {
    try await perform(
      "trustworthy mailbox-role discovery",
      detail: "Roles came only from canonical INBOX, SPECIAL-USE, or exact validated mappings."
    ) {
      let mailboxes = try await imap.listMailboxes()
      let inbox = try MailboxRoleResolver.resolve(.inbox, from: mailboxes, explicitName: nil)
      let junk = try MailboxRoleResolver.resolve(
        .junk,
        from: mailboxes,
        explicitName: self.configuration.explicitJunkMailbox
      )
      let sent = try MailboxRoleResolver.resolve(
        .sent,
        from: mailboxes,
        explicitName: self.configuration.explicitSentMailbox
      )
      return QualificationRoles(inbox: inbox, junk: junk, sent: sent)
    }
  }

  private func qualifyMailboxCreation(on imap: IMAPServer) async throws {
    let created = try await perform(
      "permitted missing-role creation",
      detail: "A missing product-role mailbox can be created and resolved by exact validated name."
    ) {
      let first = try await self.ensureMailbox(self.configuration.scratchMailbox, on: imap)
      let second = try await self.ensureMailbox(
        self.configuration.secondaryScratchMailbox, on: imap)
      return first || second
    }
    checks.append(
      QualificationCheck(
        name: "missing-role creation state",
        passed: true,
        detail: created
          ? "At least one missing fixture mailbox was created."
          : "Fixture mailboxes already existed."
      )
    )
  }

  private func prepareQualificationDataset(on imap: IMAPServer) async throws {
    try await perform(
      "10,000-message dataset preparation",
      detail: "The disposable dataset mailbox contains exactly 10,000 approximately 2 KiB fixtures."
    ) {
      _ = try await self.ensureMailbox(self.configuration.datasetMailbox, on: imap)
      var selection = try await imap.selectMailbox(self.configuration.datasetMailbox)
      guard selection.messageCount <= QualificationConfiguration.datasetMessageCount else {
        throw QualificationError.failed("The dataset mailbox contains more than 10,000 messages.")
      }
      if selection.messageCount < QualificationConfiguration.datasetMessageCount {
        for index in (selection.messageCount + 1)...QualificationConfiguration.datasetMessageCount {
          let raw = QualificationMessages.datasetMessage(
            index: index,
            recipient: self.configuration.emailAddress
          )
          let result = try await imap.append(
            rawMessage: raw,
            to: self.configuration.datasetMailbox,
            flags: [],
            internalDate: nil
          )
          guard result.firstUID != nil, result.uidValidity?.value ?? 0 > 0 else {
            throw QualificationError.failed(
              "The provider omitted APPENDUID while preparing the dataset.")
          }
          if index.isMultiple(of: 500) {
            print(
              "Prepared \(index) of \(QualificationConfiguration.datasetMessageCount) fixtures.")
          }
        }
        selection = try await imap.selectMailbox(self.configuration.datasetMailbox)
      }
      guard selection.messageCount == QualificationConfiguration.datasetMessageCount else {
        throw QualificationError.failed(
          "The dataset mailbox did not reach exactly 10,000 messages.")
      }
    }
  }

  private func qualifyMetadataPerformance(on imap: IMAPServer) async throws -> BackfillSnapshot {
    let selection = try await imap.selectMailbox(configuration.datasetMailbox)
    guard selection.messageCount == QualificationConfiguration.datasetMessageCount else {
      throw QualificationError.failed(
        "The protected qualification account needs the prepared 10,000-message dataset."
      )
    }
    guard let newestSet = selection.latest(50) else {
      throw QualificationError.failed("The dataset mailbox is empty.")
    }

    let newest = try await QualificationMetricsRecorder.measure(
      decodedBytes: { encodedByteCount($0) },
      maximumPageSize: { $0.count },
      requestCount: { _ in 1 },
      operation: {
        try await imap.fetchMessageInfosBulk(using: newestSet, options: .slim)
      }
    )
    try validateMetadata(newest.value, expectedCount: 50)
    try recordBudgetedMetrics(newest.metrics, named: "initial-mailbox-availability")
    checks.append(
      QualificationCheck(
        name: "newest-50 metadata",
        passed: true,
        detail: "Exactly 50 valid UID-bearing metadata records loaded."
      )
    )

    let upperUID = Int(selection.uidNext.value) - 1
    guard upperUID > 0 else {
      throw QualificationError.failed("The dataset mailbox returned an invalid UIDNEXT.")
    }
    let backfill = try await QualificationMetricsRecorder.measure(
      decodedBytes: { $0.decodedBytes },
      maximumPageSize: { $0.maximumPageSize },
      requestCount: { $0.requestCount },
      operation: {
        try await self.fetchBackfill(on: imap, upperUID: upperUID)
      }
    )
    try validateBackfill(backfill.value, metrics: backfill.metrics)
    metrics["complete-history-backfill"] = backfill.metrics
    checks.append(
      QualificationCheck(
        name: "complete-history backfill",
        passed: true,
        detail: "10,000 records loaded newest-first with bounded UID pages."
      )
    )
    return BackfillSnapshot(messages: backfill.value.messages)
  }

  private func qualifyIncrementalPerformance(
    on imap: IMAPServer,
    backfill: BackfillSnapshot
  ) async throws {
    let newest = Array(backfill.messages.prefix(500))
    let identifiers = UIDSet(newest.compactMap(\.uid))
    guard identifiers.count == 500 else {
      throw QualificationError.failed("The incremental baseline did not contain 500 valid UIDs.")
    }

    let noChange = try await QualificationMetricsRecorder.measure(
      decodedBytes: { encodedByteCount($0) },
      maximumPageSize: { $0.count },
      requestCount: { _ in 1 },
      operation: {
        try await imap.fetchMessageInfosBulk(using: identifiers, options: .uidFlagsOnly)
      }
    )
    try recordBudgetedMetrics(noChange.metrics, named: "no-change-reconciliation")
    try validateFlagSnapshot(noChange.value, equals: newest)

    let changed = Array(newest.prefix(100))
    let originallySeen = changed.filter(isSeen).compactMap(\.uid)
    let originallyUnseen = changed.filter { !isSeen($0) }.compactMap(\.uid)
    let changedMeasurement = try await QualificationMetricsRecorder.measure(
      decodedBytes: { encodedByteCount($0.messages) },
      maximumPageSize: { $0.messages.count },
      requestCount: { $0.requestCount },
      operation: {
        try await self.exerciseHundredMessageChange(
          identifiers: identifiers,
          originallySeen: originallySeen,
          originallyUnseen: originallyUnseen,
          on: imap
        )
      }
    )
    let expectedToggledFlags = Dictionary(
      uniqueKeysWithValues: originallySeen.map { ($0, false) }
        + originallyUnseen.map { ($0, true) }
    )
    try validateToggledFlags(
      changedMeasurement.value.messages,
      expected: expectedToggledFlags
    )
    try recordBudgetedMetrics(
      changedMeasurement.metrics,
      named: "100-message-reconciliation"
    )

    checks.append(
      QualificationCheck(
        name: "incremental reconciliation",
        passed: true,
        detail: "No-change and 100-message changes stayed within ADR 0027 limits and were restored."
      )
    )
  }

  // swiftlint:disable:next function_body_length
  private func qualifyBodySearchFlagsAndSpam(
    on imap: IMAPServer,
    roles: QualificationRoles
  ) async throws {
    let bodyPhrase = "body-only-\(runID)"
    let headerOnlyPhrase = "header-only-\(runID)"
    let excludedPhrase = "excluded-mailbox-\(runID)"
    let target = QualificationMessages.runMessage(
      body: bodyPhrase,
      runID: runID,
      recipient: configuration.emailAddress,
      suffix: "body",
      subject: "\(runID) body target"
    )
    let headerOnly = QualificationMessages.runMessage(
      body: "plain qualification body",
      runID: runID,
      recipient: configuration.emailAddress,
      suffix: "header",
      subject: "\(runID) \(headerOnlyPhrase)"
    )
    let excluded = QualificationMessages.runMessage(
      body: excludedPhrase,
      runID: runID,
      recipient: configuration.emailAddress,
      suffix: "excluded",
      subject: "\(runID) exclusion target"
    )
    let targetAppend = try await append(target, to: configuration.scratchMailbox, on: imap)
    _ = try await append(headerOnly, to: configuration.scratchMailbox, on: imap)
    _ = try await append(excluded, to: configuration.secondaryScratchMailbox, on: imap)

    try await imap.selectMailbox(configuration.scratchMailbox)
    let targetUID = try required(targetAppend.firstUID, "APPENDUID for selected-body fixture")
    let parts = try await imap.fetchStructure(targetUID)
    guard let textPart = parts.first(where: { $0.contentType.lowercased().hasPrefix("text/plain") })
    else {
      throw QualificationError.failed("The selected-body fixture had no text/plain body part.")
    }
    let bodyData = try await imap.fetchPart(section: textPart.section, of: targetUID)
    guard String(data: bodyData, encoding: .utf8)?.contains(bodyPhrase) == true else {
      throw QualificationError.failed("The selected body part did not contain its private marker.")
    }
    checks.append(
      QualificationCheck(
        name: "selected body-part fetch",
        passed: true,
        detail: "The requested text part contained the expected run-scoped marker."
      )
    )

    try await verifyBodySearch(
      on: imap,
      bodyPhrase: bodyPhrase,
      headerOnlyPhrase: headerOnlyPhrase,
      excludedPhrase: excludedPhrase,
      targetUID: targetUID
    )
    try await verifyReadUnread(on: imap, uid: targetUID)
    try await verifySpamRoundTrip(on: imap, uid: targetUID, roles: roles)
  }

  // swiftlint:disable:next function_body_length
  private func qualifyIDLE(on imap: IMAPServer) async throws {
    var idleConfiguration = IMAPIdleConfiguration.default
    idleConfiguration.renewalInterval = 2
    idleConfiguration.noopInterval = 1
    idleConfiguration.postIdleNoopEnabled = true
    idleConfiguration.postIdleNoopDelay = 0
    idleConfiguration.doneTimeout = 5
    idleConfiguration.reconnectBaseDelay = 0.2
    idleConfiguration.reconnectMaxDelay = 2
    idleConfiguration.reconnectJitterFactor = 0

    let session = try await imap.idle(
      on: configuration.scratchMailbox,
      configuration: idleConfiguration
    )
    let recorder = IdleEventRecorder()
    let collector = Task {
      for await event in session.events {
        await recorder.record(event)
      }
    }
    do {
      _ = try await append(
        QualificationMessages.runMessage(
          body: "first IDLE event",
          runID: runID,
          recipient: configuration.emailAddress,
          suffix: "idle-one",
          subject: "\(runID) idle one"
        ),
        to: configuration.scratchMailbox,
        on: imap
      )
      try await recorder.waitForExistsEvents(1, timeout: .seconds(15))
      try await Task.sleep(for: .seconds(3))
      _ = try await append(
        QualificationMessages.runMessage(
          body: "post-renewal IDLE event",
          runID: runID,
          recipient: configuration.emailAddress,
          suffix: "idle-two",
          subject: "\(runID) idle two"
        ),
        to: configuration.scratchMailbox,
        on: imap
      )
      try await recorder.waitForExistsEvents(2, timeout: .seconds(15))
      try await withTimeout(.seconds(10)) {
        try await session.done()
      }
      collector.cancel()
      _ = await collector.result
    } catch {
      try? await session.done()
      collector.cancel()
      _ = await collector.result
      throw error
    }
    checks.append(
      QualificationCheck(
        name: "IDLE renewal and cancellation",
        passed: true,
        detail: "Events arrived before and after renewal, and DONE completed within 10 seconds."
      )
    )
  }

  // swiftlint:disable:next function_body_length
  private func qualifySMTPAndSentAppend(
    on imap: IMAPServer,
    roles: QualificationRoles
  ) async throws {
    let raw = QualificationMessages.runMessage(
      body: "SMTP delivery and exact Sent append \(runID)",
      runID: runID,
      recipient: configuration.emailAddress,
      suffix: "smtp",
      subject: "\(runID) SMTP qualification"
    )
    let endpoint = configuration.smtpEndpoint
    let smtp = SMTPServer(
      host: endpoint.host,
      port: endpoint.port,
      transportSecurity: endpoint.security,
      certificateVerificationPolicy: .fullVerification,
      minimumTLSVersion: .tlsv12
    )
    do {
      try await smtp.connect()
      try await smtp.login(
        username: configuration.emailAddress,
        password: configuration.password
      )
      let result = try await smtp.sendRawMessage(
        raw,
        from: EmailAddress(address: configuration.emailAddress),
        to: [EmailAddress(address: configuration.emailAddress)]
      )
      guard (200...299).contains(result.response.code) else {
        throw QualificationError.failed("SMTP did not return a final accepting response.")
      }
      smtpAccepted = true
      try await smtp.disconnect()
    } catch {
      try? await smtp.disconnect()
      throw error
    }

    try await waitForRunMessage(in: roles.inbox.mailbox.name, on: imap)
    smtpDeliveryObserved = true
    let appended = try await append(raw, to: roles.sent.mailbox.name, on: imap)
    let uid = try required(appended.firstUID, "APPENDUID for Sent copy")
    guard appended.uidValidity?.value ?? 0 > 0 else {
      throw QualificationError.failed("The Sent append omitted UIDVALIDITY.")
    }
    try await imap.selectMailbox(roles.sent.mailbox.name)
    let fetched = try await imap.fetchRawMessage(identifier: uid)
    guard canonicalMessage(fetched) == canonicalMessage(raw) else {
      throw QualificationError.failed("The verified Sent copy differed from the SMTP bytes.")
    }
    checks.append(
      QualificationCheck(
        name: "SMTP delivery and verified Sent append",
        passed: true,
        detail:
          "SMTP returned final acceptance; self-delivery and exact APPENDUID bytes were verified."
      )
    )
  }

  private func verifyBodySearch(
    on imap: IMAPServer,
    bodyPhrase: String,
    headerOnlyPhrase: String,
    excludedPhrase: String,
    targetUID: UID
  ) async throws {
    let bodyMatches = try await searchUIDs(on: imap, criteria: [.body(bodyPhrase)])
    let absentMatches = try await searchUIDs(on: imap, criteria: [.body("absent-\(runID)")])
    let headerOnlyMatches = try await searchUIDs(on: imap, criteria: [.body(headerOnlyPhrase)])
    let excludedMatches = try await searchUIDs(on: imap, criteria: [.body(excludedPhrase)])
    guard bodyMatches.contains(targetUID), absentMatches.isEmpty, headerOnlyMatches.isEmpty,
      excludedMatches.isEmpty
    else {
      throw QualificationError.failed("Provider-backed BODY search returned an unsafe result set.")
    }
    checks.append(
      QualificationCheck(
        name: "provider-backed body search",
        passed: true,
        detail: "Body-only, absent, header-only, and mailbox-exclusion cases passed."
      )
    )
  }

  private func verifyReadUnread(on imap: IMAPServer, uid: UID) async throws {
    let set = UIDSet(uid)
    try await imap.store(flags: [.seen], on: set, operation: .add)
    guard let read = try await imap.fetchMessageInfo(for: uid, options: .uidFlagsOnly), isSeen(read)
    else {
      throw QualificationError.failed("The read mutation did not reconcile.")
    }
    try await imap.store(flags: [.seen], on: set, operation: .remove)
    guard let unread = try await imap.fetchMessageInfo(for: uid, options: .uidFlagsOnly),
      !isSeen(unread)
    else {
      throw QualificationError.failed("The unread mutation did not reconcile.")
    }
    checks.append(
      QualificationCheck(
        name: "read and unread mutations",
        passed: true,
        detail: "Both flag states reconciled against the provider."
      )
    )
  }

  private func verifySpamRoundTrip(
    on imap: IMAPServer,
    uid: UID,
    roles: QualificationRoles
  ) async throws {
    let intoJunk = try await imap.move(messages: UIDSet(uid), to: roles.junk.mailbox.name)
    let junkUID = try mappedDestination(for: uid, in: intoJunk)
    try await imap.selectMailbox(roles.junk.mailbox.name)
    let outOfJunk = try await imap.move(
      messages: UIDSet(junkUID),
      to: configuration.scratchMailbox
    )
    _ = try mappedDestination(for: junkUID, in: outOfJunk)
    checks.append(
      QualificationCheck(
        name: "spam-state mutation",
        passed: true,
        detail:
          "The run-owned message moved into and out of the attributed junk role with COPYUID mappings."
      )
    )
  }

  private func fetchBackfill(on imap: IMAPServer, upperUID: Int) async throws -> BackfillResult {
    var upper = upperUID
    var messages: [MessageInfo] = []
    var decodedBytes = 0
    var requestCount = 0
    var maximumPageSize = 0
    while upper > 0 && messages.count < QualificationConfiguration.datasetMessageCount {
      let lower = max(1, upper - 499)
      let page = try await imap.fetchMessageInfos(
        uidRange: UID(UInt32(lower))...UID(UInt32(upper)),
        options: .slim
      )
      requestCount += 1
      maximumPageSize = max(maximumPageSize, page.count)
      decodedBytes += encodedByteCount(page)
      messages.append(contentsOf: page.sorted(by: uidDescending))
      upper = lower - 1
    }
    return BackfillResult(
      decodedBytes: decodedBytes,
      maximumPageSize: maximumPageSize,
      messages: messages,
      requestCount: requestCount
    )
  }

  private func validateBackfill(
    _ backfill: BackfillResult,
    metrics: QualificationMetrics
  ) throws {
    try validateMetadata(
      backfill.messages,
      expectedCount: QualificationConfiguration.datasetMessageCount
    )
    let uids = backfill.messages.compactMap { $0.uid?.value }
    guard zip(uids, uids.dropFirst()).allSatisfy({ $0 > $1 }) else {
      throw QualificationError.failed("Complete-history metadata was not newest-first.")
    }
    let sizes = backfill.messages.compactMap(\.size)
    guard sizes.count == backfill.messages.count else {
      throw QualificationError.failed("The dataset metadata omitted RFC822.SIZE.")
    }
    let averageSize = sizes.reduce(0, +) / max(1, sizes.count)
    guard (1_900...2_200).contains(averageSize) else {
      throw QualificationError.failed(
        "The dataset did not average approximately 2 KiB per message.")
    }
    let pageCount = Int(ceil(Double(backfill.messages.count) / 500))
    let allowedRequests = pageCount * 2 + 10
    guard metrics.requestCount <= allowedRequests else {
      throw QualificationError.failed(
        "Complete-history requests exceeded the ADR 0027 page budget.")
    }
    guard metrics.maximumPageSize <= 500 else {
      throw QualificationError.failed("Complete-history page size exceeded 500 messages.")
    }
    guard metrics.peakResidentMemoryIncreaseBytes <= 100 * 1024 * 1024 else {
      throw QualificationError.failed("Complete-history memory exceeded 100 MiB.")
    }
    guard metrics.mainThreadStallMilliseconds <= 100 else {
      throw QualificationError.failed("Complete-history main-thread stall exceeded 100 ms.")
    }
  }

  private func validateMetadata(_ messages: [MessageInfo], expectedCount: Int) throws {
    guard messages.count == expectedCount else {
      throw QualificationError.failed("Metadata count did not match the qualification fixture.")
    }
    let uids = messages.compactMap(\.uid)
    guard uids.count == messages.count, Set(uids).count == messages.count,
      uids.allSatisfy({ $0.value > 0 })
    else {
      throw QualificationError.failed("Metadata contained missing, repeated, or invalid UIDs.")
    }
  }

  private func validateFlagSnapshot(_ actual: [MessageInfo], equals expected: [MessageInfo]) throws
  {
    let expectedFlags = Dictionary(
      uniqueKeysWithValues: expected.compactMap { message in
        message.uid.map { ($0, Set(message.flags.map(\.description))) }
      })
    let actualFlags = Dictionary(
      uniqueKeysWithValues: actual.compactMap { message in
        message.uid.map { ($0, Set(message.flags.map(\.description))) }
      })
    guard actualFlags == expectedFlags else {
      throw QualificationError.failed(
        "No-change reconciliation did not preserve the flag snapshot.")
    }
  }

  private func validateToggledFlags(
    _ messages: [MessageInfo],
    expected: [UID: Bool]
  ) throws {
    let observed = Dictionary(
      uniqueKeysWithValues: messages.compactMap { message in
        message.uid.map { ($0, isSeen(message)) }
      })
    guard expected.allSatisfy({ observed[$0.key] == $0.value }) else {
      throw QualificationError.failed(
        "The 100-message reconciliation did not observe every flag change.")
    }
  }

  private func exerciseHundredMessageChange(
    identifiers: UIDSet,
    originallySeen: [UID],
    originallyUnseen: [UID],
    on imap: IMAPServer
  ) async throws -> HundredMessageChangeResult {
    var requestCount = 0
    do {
      requestCount += try await setSeen(true, uids: originallyUnseen, on: imap)
      requestCount += try await setSeen(false, uids: originallySeen, on: imap)
      let messages = try await imap.fetchMessageInfosBulk(
        using: identifiers,
        options: .uidFlagsOnly
      )
      requestCount += 1
      requestCount += try await restoreSeenFlags(
        originallySeen: originallySeen,
        originallyUnseen: originallyUnseen,
        on: imap
      )
      return HundredMessageChangeResult(messages: messages, requestCount: requestCount)
    } catch {
      _ = try? await restoreSeenFlags(
        originallySeen: originallySeen,
        originallyUnseen: originallyUnseen,
        on: imap
      )
      throw error
    }
  }

  private func recordBudgetedMetrics(
    _ recorded: QualificationMetrics,
    named name: String
  ) throws {
    let violations = QualificationBudget.adr0027.violations(in: recorded)
    guard violations.isEmpty else {
      throw QualificationError.failed(
        "\(name) violated ADR 0027: \(violations.joined(separator: ", ")).")
    }
    metrics[name] = recorded
  }

  private func setSeen(_ seen: Bool, uids: [UID], on imap: IMAPServer) async throws -> Int {
    guard !uids.isEmpty else { return 0 }
    try await imap.store(
      flags: [.seen],
      on: UIDSet(uids),
      operation: seen ? .add : .remove
    )
    return 1
  }

  private func restoreSeenFlags(
    originallySeen: [UID],
    originallyUnseen: [UID],
    on imap: IMAPServer
  ) async throws -> Int {
    let added = try await setSeen(true, uids: originallySeen, on: imap)
    let removed = try await setSeen(false, uids: originallyUnseen, on: imap)
    return added + removed
  }

  private func ensureMailbox(_ name: String, on imap: IMAPServer) async throws -> Bool {
    let existing = try await imap.listMailboxes().filter { $0.name == name }
    if existing.count == 1 {
      guard existing[0].isSelectable else {
        throw QualificationError.failed("A qualification mailbox exists but is not selectable.")
      }
      return false
    }
    guard existing.isEmpty else {
      throw QualificationError.failed("A qualification mailbox name is ambiguous.")
    }
    try await imap.createMailbox(name)
    let created = try await imap.listMailboxes().filter { $0.name == name && $0.isSelectable }
    guard created.count == 1 else {
      throw QualificationError.failed(
        "The provider did not create the requested qualification mailbox.")
    }
    return true
  }

  private func append(_ data: Data, to mailbox: String, on imap: IMAPServer) async throws
    -> AppendResult
  {
    guard let rawMessage = String(data: data, encoding: .utf8) else {
      throw QualificationError.failed("A generated qualification message was not UTF-8.")
    }
    let result = try await imap.append(
      rawMessage: rawMessage,
      to: mailbox,
      flags: [],
      internalDate: nil
    )
    guard result.firstUID != nil, result.uidValidity?.value ?? 0 > 0 else {
      throw QualificationError.failed("The provider omitted a verified APPENDUID result.")
    }
    return result
  }

  private func waitForRunMessage(in mailbox: String, on imap: IMAPServer) async throws {
    for _ in 0..<18 {
      try await imap.selectMailbox(mailbox)
      let matches = try await searchUIDs(
        on: imap,
        criteria: [.header("X-Unwired-Qualification-Run", runID)]
      )
      if !matches.isEmpty { return }
      try await Task.sleep(for: .seconds(5))
    }
    throw QualificationError.failed("The SMTP message did not arrive within 90 seconds.")
  }

  private func cleanupRunMessages(on imap: IMAPServer, roles: QualificationRoles) async throws {
    let mailboxes = Set([
      configuration.scratchMailbox,
      configuration.secondaryScratchMailbox,
      roles.inbox.mailbox.name,
      roles.junk.mailbox.name,
      roles.sent.mailbox.name,
    ])
    let delayedDeliveryPasses = smtpAccepted && !smtpDeliveryObserved ? 18 : 1
    for pass in 0..<delayedDeliveryPasses {
      for mailbox in mailboxes {
        try await imap.selectMailbox(mailbox)
        var matches = try await searchUIDs(
          on: imap,
          criteria: [.header("X-Unwired-Qualification-Run", runID)]
        )
        if matches.isEmpty {
          matches = try await searchUIDs(on: imap, criteria: [.subject(runID)])
        }
        if !matches.isEmpty {
          try await imap.store(flags: [.deleted], on: matches, operation: .add)
          try await imap.expunge(messages: matches)
        }
        let remaining = try await searchUIDs(on: imap, criteria: [.subject(runID)])
        guard remaining.isEmpty else {
          throw QualificationError.failed("Run-scoped cleanup left qualification messages behind.")
        }
      }
      if pass + 1 < delayedDeliveryPasses { try await Task.sleep(for: .seconds(5)) }
    }
  }

  private func perform<Value: Sendable>(
    _ name: String,
    detail: String,
    operation: () async throws -> Value
  ) async throws -> Value {
    do {
      let value = try await operation()
      checks.append(QualificationCheck(name: name, passed: true, detail: detail))
      return value
    } catch {
      checks.append(
        QualificationCheck(
          name: name,
          passed: false,
          detail: "Failed with \(sanitizedErrorType(error))."
        )
      )
      throw error
    }
  }

  private func recordFailure(_ error: Error) {
    if checks.last?.passed == false { return }
    checks.append(
      QualificationCheck(
        name: "qualification run",
        passed: false,
        detail: "Failed with \(sanitizedErrorType(error))."
      )
    )
  }

  private func required<Value>(_ value: Value?, _ label: String = "required value") throws -> Value
  {
    guard let value else { throw QualificationError.failed("The provider omitted \(label).") }
    return value
  }
}

private struct QualificationRoles: Sendable {
  let inbox: ResolvedQualificationMailbox
  let junk: ResolvedQualificationMailbox
  let sent: ResolvedQualificationMailbox
}

private struct BackfillResult: Sendable {
  let decodedBytes: Int
  let maximumPageSize: Int
  let messages: [MessageInfo]
  let requestCount: Int
}

private struct BackfillSnapshot: Sendable {
  let messages: [MessageInfo]
}

private struct HundredMessageChangeResult: Sendable {
  let messages: [MessageInfo]
  let requestCount: Int
}

private actor IdleEventRecorder {
  private var existsEvents = 0

  func record(_ event: IMAPServerEvent) {
    if case .exists = event { existsEvents += 1 }
  }

  func waitForExistsEvents(_ expected: Int, timeout: Duration) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while existsEvents < expected {
      guard clock.now < deadline else {
        throw QualificationError.failed("Timed out waiting for an IDLE EXISTS event.")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}

private func withTimeout<Value: Sendable>(
  _ timeout: Duration,
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: timeout)
      throw QualificationError.failed("The operation exceeded its deadline.")
    }
    guard let value = try await group.next() else {
      throw QualificationError.failed("The timed operation returned no value.")
    }
    group.cancelAll()
    return value
  }
}

private func encodedByteCount(_ messages: [MessageInfo]) -> Int {
  (try? JSONEncoder().encode(messages).count) ?? Int.max
}

private func searchUIDs(
  on imap: IMAPServer,
  criteria: [SearchCriteria]
) async throws -> UIDSet {
  let result: ExtendedSearchResult<UID> = try await imap.extendedSearch(criteria: criteria)
  if let all = result.all { return all }
  if let partial = result.partial { return partial.results }
  if let ordered = result.ordered { return UIDSet(ordered) }
  return UIDSet()
}

private func isSeen(_ message: MessageInfo) -> Bool {
  message.flags.contains { $0.description == Flag.seen.description }
}

private func uidDescending(_ lhs: MessageInfo, _ rhs: MessageInfo) -> Bool {
  (lhs.uid?.value ?? 0) > (rhs.uid?.value ?? 0)
}

private func mappedDestination(for source: UID, in mapping: CopyUID?) throws -> UID {
  guard let mapping, mapping.destinationUIDValidity.value > 0,
    let destination = mapping.mapping.first(where: { $0.source == source })?.destination,
    mapping.mapping.count == 1
  else {
    throw QualificationError.failed("The provider omitted a one-to-one COPYUID mapping.")
  }
  return destination
}

private func canonicalMessage(_ data: Data) -> Data {
  guard var text = String(data: data, encoding: .utf8) else { return Data() }
  text = text.replacingOccurrences(of: "\r\n", with: "\n")
  while text.hasSuffix("\n") { text.removeLast() }
  return Data((text + "\n").utf8)
}

private func sanitizedErrorType(_ error: Error) -> String {
  String(reflecting: type(of: error))
}
