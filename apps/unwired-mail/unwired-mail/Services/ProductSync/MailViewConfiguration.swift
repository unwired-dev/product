import Foundation

enum MailViewSelection: Codable, Equatable, Hashable, Identifiable, Sendable {
  case all
  case category(String)
  case important

  var id: String {
    switch self {
    case .all:
      return "all"
    case .category(let categoryId):
      return "category:\(categoryId)"
    case .important:
      return "important"
    }
  }
}

struct MailViewConfiguration: Codable, Equatable, Sendable {
  static let configurableSlotCount = 3
  static let defaults = MailViewConfiguration(
    importantCategoryIds: [
      "system:people",
      "system:invites",
      "system:invoices",
      "system:flights",
    ],
    categorySlots: [
      "system:invoices",
      "system:promotions",
      "system:flights",
    ]
  )

  var importantCategoryIds: [String]
  var categorySlots: [String?]

  init(importantCategoryIds: [String], categorySlots: [String?]) {
    self.importantCategoryIds = Self.uniqueCategoryIds(importantCategoryIds)
    self.categorySlots = Self.normalizedSlots(categorySlots)
  }

  private enum CodingKeys: String, CodingKey {
    case categorySlots
    case importantCategoryIds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      importantCategoryIds: try container.decodeIfPresent(
        [String].self,
        forKey: .importantCategoryIds
      ) ?? [],
      categorySlots: try container.decodeIfPresent([String?].self, forKey: .categorySlots) ?? []
    )
  }

  func retainingCategories(in availableCategoryIds: Set<String>) -> Self {
    MailViewConfiguration(
      importantCategoryIds: importantCategoryIds.filter(availableCategoryIds.contains),
      categorySlots: categorySlots.map { categoryId in
        categoryId.flatMap { availableCategoryIds.contains($0) ? $0 : nil }
      }
    )
  }

  func contains(_ selection: MailViewSelection) -> Bool {
    switch selection {
    case .all, .important:
      return true
    case .category(let categoryId):
      return categorySlots.contains(categoryId)
    }
  }

  mutating func setImportant(_ isImportant: Bool, categoryId: String) {
    var categoryIds = Set(importantCategoryIds)
    if isImportant {
      categoryIds.insert(categoryId)
    } else {
      categoryIds.remove(categoryId)
    }
    importantCategoryIds = categoryIds.sorted()
  }

  mutating func setCategory(_ categoryId: String?, at index: Int) {
    guard categorySlots.indices.contains(index) else { return }
    if let categoryId,
      categorySlots.enumerated().contains(where: { $0.offset != index && $0.element == categoryId })
    {
      return
    }
    categorySlots[index] = categoryId
  }

  mutating func moveCategory(from sourceIndex: Int, to destinationIndex: Int) {
    guard categorySlots.indices.contains(sourceIndex),
      categorySlots.indices.contains(destinationIndex),
      sourceIndex != destinationIndex
    else { return }
    categorySlots.swapAt(sourceIndex, destinationIndex)
  }

  private static func normalizedSlots(_ slots: [String?]) -> [String?] {
    var seen: Set<String> = []
    var normalized = slots.prefix(configurableSlotCount).map { categoryId -> String? in
      guard let categoryId, !categoryId.isEmpty, seen.insert(categoryId).inserted else {
        return nil
      }
      return categoryId
    }
    normalized.append(
      contentsOf: repeatElement(nil, count: configurableSlotCount - normalized.count)
    )
    return normalized
  }

  private static func uniqueCategoryIds(_ categoryIds: [String]) -> [String] {
    Array(Set(categoryIds.filter { !$0.isEmpty })).sorted()
  }
}

extension InboxPreferenceStore {
  func setImportantMailViewCategory(_ isImportant: Bool, categoryId: String) {
    var configuration = preferences.mailViewConfiguration
    configuration.setImportant(isImportant, categoryId: categoryId)
    editMailViewConfiguration(configuration)
  }

  func setMailViewCategory(_ categoryId: String?, at index: Int) {
    var configuration = preferences.mailViewConfiguration
    configuration.setCategory(categoryId, at: index)
    editMailViewConfiguration(configuration)
  }

  func moveMailViewCategory(from sourceIndex: Int, to destinationIndex: Int) {
    var configuration = preferences.mailViewConfiguration
    configuration.moveCategory(from: sourceIndex, to: destinationIndex)
    editMailViewConfiguration(configuration)
  }

  func retainAvailableMailViewCategories(_ availableCategoryIds: Set<String>) {
    let configuration = preferences.mailViewConfiguration.retainingCategories(
      in: availableCategoryIds
    )
    guard configuration != preferences.mailViewConfiguration else { return }
    editMailViewConfiguration(configuration)
  }
}
