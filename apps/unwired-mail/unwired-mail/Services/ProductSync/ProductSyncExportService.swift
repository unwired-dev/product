import Foundation

/// Produces a readable device-local export of encrypted Product Sync records.
protocol ProductSyncExporting: Sendable {
  /// Returns the complete Product Sync export for one Trusted Device session.
  func export(session: ProductAccountSessionSnapshot) async throws -> Data
}

enum ProductSyncExportError: LocalizedError, Equatable {
  case duplicatePayloadIdentifier
  case incompletePagination
  case missingKeyMaterial

  var errorDescription: String? {
    switch self {
    case .duplicatePayloadIdentifier:
      "Product Sync returned the same record more than once. Refresh and try again."
    case .incompletePagination:
      "Product Sync did not return a complete export. Refresh and try again."
    case .missingKeyMaterial:
      "Restore Product Sync with a Recovery Key before exporting data."
    }
  }
}

struct ProductSyncExportDocument: Codable, Equatable, Sendable {
  struct Record: Codable, Equatable, Sendable {
    let payloadIdentifier: String
    let updatedAtMilliseconds: Int64
    let value: ProductSyncExportValue
  }

  let exportedAt: Date
  let formatVersion: Int
  let productAccountId: String
  let records: [Record]
}

indirect enum ProductSyncExportValue: Codable, Equatable, Sendable {
  case array([Self])
  case boolean(Bool)
  case decimal(Double)
  case integer(Int64)
  case null
  case object([String: Self])
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .decimal(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([Self].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: Self].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .boolean(let value):
      try container.encode(value)
    case .decimal(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .object(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }
}

/// Reads ciphertext from Product Sync and decrypts every record on this device.
actor ProductSyncExportService: ProductSyncExporting {
  private static let maximumPageCount = 100
  private static let pageSize = 100

  private let keyMaterialStore: ProductSyncKeyMaterialPersisting
  private let now: @Sendable () -> Date
  private let transport: ProductSyncRecordTransport

  init(
    keyMaterialStore: ProductSyncKeyMaterialPersisting = KeychainProductSyncKeyMaterialStore(),
    now: @escaping @Sendable () -> Date = { .now },
    transport: ProductSyncRecordTransport = ConvexProductSyncRecordTransport()
  ) {
    self.keyMaterialStore = keyMaterialStore
    self.now = now
    self.transport = transport
  }

  func export(session: ProductAccountSessionSnapshot) async throws -> Data {
    guard
      let keyMaterial = try keyMaterialStore.load(productAccountId: session.productAccountId)
    else {
      throw ProductSyncExportError.missingKeyMaterial
    }

    let records = try await exportRecords(session: session, keyMaterial: keyMaterial)
    let document = ProductSyncExportDocument(
      exportedAt: now(),
      formatVersion: 1,
      productAccountId: session.productAccountId,
      records: records.sorted { $0.payloadIdentifier < $1.payloadIdentifier }
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(document)
  }

  private func exportRecords(
    session: ProductAccountSessionSnapshot,
    keyMaterial: ProductSyncKeyMaterial
  ) async throws -> [ProductSyncExportDocument.Record] {
    var cursor: String?
    var pageCount = 0
    var records: [ProductSyncExportDocument.Record] = []
    var seenPayloadIdentifiers: Set<String> = []
    repeat {
      try Task.checkCancellation()
      pageCount += 1
      guard pageCount <= Self.maximumPageCount else {
        throw ProductSyncExportError.incompletePagination
      }
      let page = try await transport.listEncryptedProductSyncPayloads(
        session: session,
        payloadIdentifierPrefix: "",
        cursor: cursor,
        limit: Self.pageSize
      )
      for payload in page.page {
        try Task.checkCancellation()
        guard seenPayloadIdentifiers.insert(payload.payloadIdentifier).inserted else {
          throw ProductSyncExportError.duplicatePayloadIdentifier
        }
        let plaintext = try keyMaterial.decryptPayload(
          payload.encryptedPayload,
          associatedData: Data(payload.payloadIdentifier.utf8)
        )
        records.append(
          ProductSyncExportDocument.Record(
            payloadIdentifier: payload.payloadIdentifier,
            updatedAtMilliseconds: payload.updatedAt,
            value: try JSONDecoder().decode(ProductSyncExportValue.self, from: plaintext)
          )
        )
      }

      if page.isDone {
        cursor = nil
      } else {
        guard !page.continueCursor.isEmpty, page.continueCursor != cursor else {
          throw ProductSyncExportError.incompletePagination
        }
        cursor = page.continueCursor
      }
    } while cursor != nil

    return records
  }
}
