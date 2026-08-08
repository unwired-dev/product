import Foundation
import Testing

@testable import unwired_mail

#if DEBUG || MAIL_TEST_BOOTSTRAP
  @Suite
  struct MailTestBootstrapTests {
    @Test
    func testLoadsRunScopedLoopbackConfiguration() throws {
      let runId = UUID().uuidString

      let loaded = try MailTestBootstrapConfiguration.load(
        environment: [
          "MAIL_TEST_BOOTSTRAP": "1",
          "MAIL_TEST_HOST": "127.0.0.1",
          "MAIL_TEST_IMAPS_PORT": "1993",
          "MAIL_TEST_RUN_ID": runId,
          "MAIL_TEST_SMTPS_PORT": "1465",
        ]
      )
      let configuration = try #require(loaded)

      #expect(
        configuration
          == MailTestBootstrapConfiguration(
            host: "127.0.0.1",
            imapsPort: 1993,
            runId: runId,
            smtpsPort: 1465
          )
      )
    }

    @Test
    func testOrdinaryLaunchDoesNotActivateBootstrap() throws {
      #expect(try MailTestBootstrapConfiguration.load(environment: [:]) == nil)
    }

    @Test
    func testRejectsNonLoopbackMailEndpoint() {
      #expect(throws: MailTestBootstrapError.self) {
        try MailTestBootstrapConfiguration.load(
          environment: [
            "MAIL_TEST_BOOTSTRAP": "1",
            "MAIL_TEST_HOST": "imap.example.com",
            "MAIL_TEST_IMAPS_PORT": "993",
            "MAIL_TEST_RUN_ID": UUID().uuidString,
            "MAIL_TEST_SMTPS_PORT": "465",
          ]
        )
      }
    }
  }
#endif
