import Foundation

enum MailProfileDuplicableConfiguration: String, CaseIterable, Sendable {
  case categories
  case mailViews
  case preferences
  case rules
  case signatures
  case templates
}

struct MailProfileDuplicationReview: Equatable, Sendable {
  let configuration: Set<MailProfileDuplicableConfiguration>
  let expectedProfileUpdatedAt: Int64
  let id: String
  let sourceProfileId: MailProfileId
}

struct MailProfileCustomCategoryCopyReview: Equatable, Sendable {
  let destinationCategoryId: String
  let expectedDestinationUpdatedAt: Int64?
  let sourceCategoryId: String
}

struct MailProfileConnectionTransferReview: Equatable, Sendable {
  let connectionId: MailboxConnectionId
  let customCategoryCopies: [MailProfileCustomCategoryCopyReview]
  let destinationProfileId: MailProfileId
  let expectedProfileUpdatedAt: Int64
  let sourceProfileId: MailProfileId
}

struct MailProfileDeletionReview: Equatable, Sendable {
  let expectedProfileUpdatedAt: Int64
  let profileId: MailProfileId
  let unresolvedDraftCount: Int
  let unresolvedOutboxCount: Int
  let unresolvedPendingActionCount: Int

  var isReady: Bool {
    unresolvedDraftCount == 0 && unresolvedOutboxCount == 0
      && unresolvedPendingActionCount == 0
  }
}

enum MailProfileSyncError: LocalizedError, Equatable {
  case concurrentModification
  case finalProfileCannotBeDeleted
  case invalidLifecycleReview
  case invalidProfileName
  case invalidProfileState
  case missingProductSyncKeyMaterial
  case profileHasUnresolvedState
  case profileNotFound
  case transactionTooLarge

  var errorDescription: String? {
    switch self {
    case .concurrentModification:
      return "Mail Profiles changed on another device. Refresh and try again."
    case .finalProfileCannotBeDeleted:
      return "The Product Account's final Mail Profile cannot be deleted."
    case .invalidLifecycleReview:
      return "Review the current Mail Profile change before continuing."
    case .invalidProfileName:
      return "Choose a unique Mail Profile name between 1 and 40 characters."
    case .invalidProfileState:
      return "Mail Profile ownership is incomplete. Refresh Product Sync before continuing."
    case .missingProductSyncKeyMaterial:
      return "Restore Product Sync key material before changing Mail Profiles."
    case .profileHasUnresolvedState:
      return
        "Move or resolve this Mail Profile's connections, Drafts, Outbox, and pending actions first."
    case .profileNotFound:
      return "The selected Mail Profile no longer exists."
    case .transactionTooLarge:
      return "Select fewer Mail Profile settings to copy in one operation."
    }
  }
}
