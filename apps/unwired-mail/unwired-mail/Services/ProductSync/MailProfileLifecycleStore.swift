import Foundation
import Observation
import Security

protocol MailProfileLifecycleLocalStatePersisting {
  func clear(productAccountId: String) throws
  func load(productAccountId: String) throws -> MailProfileLifecycleLocalState?
  func save(_ state: MailProfileLifecycleLocalState, productAccountId: String) throws
}

protocol MailProfileLifecycleSyncing: AnyObject {
  func createProfile(
    id: MailProfileId?,
    name: String,
    appearance: MailProfileAppearance,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot

  func saveProfile(
    _ profile: MailProfileDefinition,
    basedOn base: MailProfileDefinition,
    session: ProductAccountSessionSnapshot
  ) async throws -> MailProfileSyncSnapshot
}

extension MailboxConnectionSyncService: MailProfileLifecycleSyncing {}

struct MailProfilePendingCreate: Codable, Equatable, Sendable {
  var profile: MailProfileDefinition
  var revision: Int
}

struct MailProfilePendingUpdate: Codable, Equatable, Sendable {
  var base: MailProfileDefinition
  var profile: MailProfileDefinition
  var revision: Int
}

struct MailProfileLifecycleLocalState: Codable, Equatable, Sendable {
  var knownProfiles: [MailProfileDefinition]
  var nextRevision: Int
  var pendingCreates: [MailProfilePendingCreate]
  var pendingUpdates: [MailProfilePendingUpdate]

  static let empty = MailProfileLifecycleLocalState(
    knownProfiles: [],
    nextRevision: 1,
    pendingCreates: [],
    pendingUpdates: []
  )
}

struct KeychainMailProfileStateStore:
  MailProfileLifecycleLocalStatePersisting
{
  private static let lock = NSLock()
  private let service = "dev.unwired.mail.mail-profile-lifecycle-state"

  func clear(productAccountId: String) throws {
    try Self.lock.withLock {
      try KeychainStore.delete(service: service, account: productAccountId)
    }
  }

  func load(productAccountId: String) throws -> MailProfileLifecycleLocalState? {
    try Self.lock.withLock {
      guard
        let rawValue = try KeychainStore.readString(service: service, account: productAccountId),
        let data = rawValue.data(using: .utf8)
      else {
        return nil
      }
      return try JSONDecoder().decode(MailProfileLifecycleLocalState.self, from: data)
    }
  }

  func save(_ state: MailProfileLifecycleLocalState, productAccountId: String) throws {
    try Self.lock.withLock {
      let data = try JSONEncoder().encode(state)
      guard let rawValue = String(data: data, encoding: .utf8) else {
        throw KeychainStoreError.unexpectedData
      }
      try KeychainStore.writeString(
        rawValue,
        service: service,
        account: productAccountId,
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      )
    }
  }
}

@MainActor
@Observable
final class MailProfileLifecycleStore {
  private(set) var errorMessage: String?
  private(set) var isSynchronizing = false
  private var isLocalStateAvailable = true
  private var localState: MailProfileLifecycleLocalState
  private let localStateStore: MailProfileLifecycleLocalStatePersisting
  private let session: ProductAccountSessionSnapshot
  private let syncService: MailProfileLifecycleSyncing

  var hasPendingChanges: Bool {
    !localState.pendingCreates.isEmpty || !localState.pendingUpdates.isEmpty
  }

  var profiles: [MailProfileDefinition] {
    var values = Dictionary(
      uniqueKeysWithValues: localState.knownProfiles.map { ($0.id, $0) }
    )
    for update in localState.pendingUpdates {
      values[update.profile.id] = update.profile
    }
    for create in localState.pendingCreates {
      values[create.profile.id] = create.profile
    }
    return values.values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  init(
    session: ProductAccountSessionSnapshot,
    syncService: MailProfileLifecycleSyncing,
    localStateStore: MailProfileLifecycleLocalStatePersisting =
      KeychainMailProfileStateStore()
  ) {
    self.session = session
    self.syncService = syncService
    self.localStateStore = localStateStore
    do {
      localState = try localStateStore.load(productAccountId: session.productAccountId) ?? .empty
    } catch is DecodingError {
      localState = .empty
      errorMessage = MailProfileSyncError.invalidProfileState.localizedDescription
    } catch {
      localState = .empty
      isLocalStateAvailable = false
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func createProfile(
    name: String,
    appearance: MailProfileAppearance = .default
  ) throws -> MailProfileId {
    try requireLocalStateAvailable()
    let normalizedName = try validatedName(name)
    let profileId = MailProfileId(rawValue: UUID().uuidString.lowercased())
    localState.pendingCreates.append(
      MailProfilePendingCreate(
        profile: MailProfileDefinition(
          id: profileId,
          appearance: appearance,
          name: normalizedName,
          recordScope: .profile(profileId),
          quietState: .inactive
        ),
        revision: takeRevision()
      )
    )
    try persist()
    return profileId
  }

  func renameProfile(_ profileId: MailProfileId, name: String) throws {
    let normalizedName = try validatedName(name, excluding: profileId)
    try editProfile(profileId) { $0.name = normalizedName }
  }

  func styleProfile(_ profileId: MailProfileId, appearance: MailProfileAppearance) throws {
    try editProfile(profileId) { $0.appearance = appearance }
  }

  func updateFromSnapshot(_ snapshot: MailProfileSyncSnapshot) throws {
    try requireLocalStateAvailable()
    localState.knownProfiles = snapshot.profiles
    for index in localState.pendingCreates.indices.reversed() {
      let pending = localState.pendingCreates[index]
      guard let synchronized = snapshot.profiles.first(where: { $0.id == pending.profile.id })
      else { continue }
      localState.pendingCreates.remove(at: index)
      if synchronized != pending.profile {
        localState.pendingUpdates.append(
          MailProfilePendingUpdate(
            base: synchronized,
            profile: pending.profile,
            revision: pending.revision
          )
        )
      }
    }
    localState.pendingUpdates.removeAll { pending in
      snapshot.profiles.contains(pending.profile)
    }
    try persist()
  }

  func synchronize() async throws {
    try requireLocalStateAvailable()
    guard !isSynchronizing else { return }
    isSynchronizing = true
    defer { isSynchronizing = false }
    do {
      for pending in localState.pendingCreates {
        let snapshot = try await syncService.createProfile(
          id: pending.profile.id,
          name: pending.profile.name,
          appearance: pending.profile.appearance,
          session: session
        )
        try finishCreate(pending, snapshot: snapshot)
      }
      for pending in localState.pendingUpdates {
        let snapshot = try await syncService.saveProfile(
          pending.profile,
          basedOn: pending.base,
          session: session
        )
        try finishUpdate(pending, snapshot: snapshot)
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  private func editProfile(
    _ profileId: MailProfileId,
    edit: (inout MailProfileDefinition) -> Void
  ) throws {
    try requireLocalStateAvailable()
    let revision = takeRevision()
    if let index = localState.pendingCreates.firstIndex(where: { $0.profile.id == profileId }) {
      edit(&localState.pendingCreates[index].profile)
      localState.pendingCreates[index].revision = revision
    } else if let index = localState.pendingUpdates.firstIndex(where: {
      $0.profile.id == profileId
    }) {
      edit(&localState.pendingUpdates[index].profile)
      localState.pendingUpdates[index].revision = revision
    } else if let profile = localState.knownProfiles.first(where: { $0.id == profileId }) {
      var edited = profile
      edit(&edited)
      localState.pendingUpdates.append(
        MailProfilePendingUpdate(base: profile, profile: edited, revision: revision)
      )
    } else {
      throw MailProfileSyncError.profileNotFound
    }
    try persist()
  }

  private func finishCreate(
    _ pending: MailProfilePendingCreate,
    snapshot: MailProfileSyncSnapshot
  ) throws {
    localState.knownProfiles = snapshot.profiles
    guard
      let currentIndex = localState.pendingCreates.firstIndex(where: {
        $0.profile.id == pending.profile.id
      })
    else {
      try persist()
      return
    }
    let current = localState.pendingCreates.remove(at: currentIndex)
    if let synchronized = snapshot.profiles.first(where: { $0.id == pending.profile.id }),
      synchronized != current.profile
    {
      localState.pendingUpdates.append(
        MailProfilePendingUpdate(
          base: synchronized,
          profile: current.profile,
          revision: current.revision
        )
      )
    }
    try persist()
  }

  private func finishUpdate(
    _ pending: MailProfilePendingUpdate,
    snapshot: MailProfileSyncSnapshot
  ) throws {
    localState.knownProfiles = snapshot.profiles
    guard
      let currentIndex = localState.pendingUpdates.firstIndex(where: {
        $0.profile.id == pending.profile.id
      })
    else {
      try persist()
      return
    }
    let current = localState.pendingUpdates[currentIndex]
    if current.revision == pending.revision {
      localState.pendingUpdates.remove(at: currentIndex)
    } else if let synchronized = snapshot.profiles.first(where: {
      $0.id == pending.profile.id
    }) {
      localState.pendingUpdates[currentIndex].base = synchronized
    }
    try persist()
  }

  private func validatedName(
    _ name: String,
    excluding profileId: MailProfileId? = nil
  ) throws -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...40).contains(normalizedName.count) else {
      throw MailProfileSyncError.invalidProfileName
    }
    guard
      !profiles.contains(where: {
        $0.id != profileId && $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
      })
    else {
      throw MailProfileSyncError.invalidProfileName
    }
    return normalizedName
  }

  private func takeRevision() -> Int {
    let revision = localState.nextRevision
    localState.nextRevision += 1
    return revision
  }

  private func persist() throws {
    try requireLocalStateAvailable()
    try localStateStore.save(localState, productAccountId: session.productAccountId)
  }

  private func requireLocalStateAvailable() throws {
    guard isLocalStateAvailable else {
      throw MailProfileSyncError.invalidProfileState
    }
  }
}
