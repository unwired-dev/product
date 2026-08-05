# Keep mail-test control outside the app

The test-only application surface accepts only Mail Test Bootstrap configuration at process startup to establish its Test Product Account and local Mailbox Connection. The external Mail Test Harness exclusively owns scenario seeding, server inspection, reset, and cleanup; the app exposes no fixture loader, test control server, provider bypass, or reset backdoor. This keeps XCUITest on the visible product interface and limits test-only application code that could accidentally become reachable in production.
