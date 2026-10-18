import Foundation
import React

@objc(UnwiredErrorReporting)
final class UnwiredErrorReporting: NSObject {
  @objc static func requiresMainQueueSetup() -> Bool { false }

  @objc @MainActor static func start() { _ = ErrorReportingRuntime.shared.read() }

  @MainActor private func perform(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock,
    operation: @escaping @MainActor () async throws -> Any
  ) {
    Task { @MainActor in
      do { resolve(try await operation()) } catch {
        let code: String
        switch error {
        case ReportingError.stale: code = "error-reporting-stale"
        case ReportingError.disabled: code = "error-reporting-disabled"
        case ReportingError.invalid: code = "error-reporting-invalid"
        case ReportingError.retry: code = "error-reporting-retry"
        case ReportingError.offline: code = "offline"
        default: code = "error-reporting-unavailable"
        }
        reject(code, "Error reporting is unavailable.", nil)
      }
    }
  }

  @objc(errorReportingRead:rejecter:)
  func errorReportingRead(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in resolve(ErrorReportingRuntime.shared.read()) }
  }

  @objc(errorReportingConsent:renewIdentity:generation:resolver:rejecter:)
  func errorReportingConsent(
    _ enabled: Bool, renewIdentity: Bool, generation: Double,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      perform(resolve, reject: reject) {
        guard let generation = Self.generation(generation) else { throw ReportingError.invalid }
        return try ErrorReportingRuntime.shared.consent(
          enabled: enabled, renewIdentity: renewIdentity, expectedGeneration: generation)
      }
    }
  }

  @objc(errorReportingSave:document:resolver:rejecter:)
  func errorReportingSave(
    _ generation: Double, document: String,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      perform(resolve, reject: reject) {
        guard let generation = Self.generation(generation) else { throw ReportingError.invalid }
        return [
          "saved": try ErrorReportingRuntime.shared.save(generation: generation, document: document)
        ]
      }
    }
  }

  @objc(errorReportingRequest:body:generation:resolver:rejecter:)
  func errorReportingRequest(
    _ operation: String, body: String, generation: Double,
    resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      perform(resolve, reject: reject) {
        guard let generation = Self.generation(generation) else { throw ReportingError.invalid }
        return try await ErrorReportingRuntime.shared.request(
          operation: operation, body: body, generation: generation)
      }
    }
  }

  @objc(errorReportingTakeNative:rejecter:)
  func errorReportingTakeNative(
    _ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock
  ) {
    Task { @MainActor in
      perform(resolve, reject: reject) { try ErrorReportingRuntime.shared.takeNative() }
    }
  }

  private static func generation(_ value: Double) -> Int? {
    guard value.isFinite, value >= 0, value < 9_007_199_254_740_991, value.rounded(.down) == value
    else { return nil }
    return Int(value)
  }
}
