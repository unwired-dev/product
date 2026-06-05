import XCTest

@testable import unwired_mail

final class BackendHealthServiceTests: XCTestCase {
  func testMissingConvexURLReportsSetupError() async {
    let service = ConvexBackendHealthService(convexURL: nil)

    do {
      _ = try await service.health()
      XCTFail("Expected missing Convex URL error")
    } catch let error as BackendHealthError {
      XCTAssertEqual(error, .missingConvexURL)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}
