---
status: accepted
---

# Use a risk-weighted test portfolio

Related issue: `#297`.

Amended on 2026-09-28 at the maintainer’s request: prefer integration and end-to-end tests, with only the minimum unit tests needed for risks those layers cannot cover reliably or efficiently. This replaces the default preference for the cheapest reliable test layer.

Tests are admitted and retained when they protect a credible product risk through observable behavior. Test count and line coverage are evidence inputs rather than targets; duplicated mechanics, implementation-detail assertions, fixture echoes, incidental scheduler checks, and coverage for superseded behavior may be consolidated or retired when the protected risk is preserved or no longer exists.

Privacy and security boundaries, data loss, incorrect delivery, irreversible state changes, concurrency and recovery, migrations, and external contracts remain merge-blocking. Fast deterministic tests run for affected changes, while expensive performance, compatibility, visible-journey, live-provider, and physical-device evidence runs conditionally, on a schedule, or before release according to the risk it covers. This accepts less duplicated diagnostic granularity in exchange for faster feedback, lower maintenance cost, and investment in stronger boundaries such as the visible Core Mail Loop.

Operational test selection, admission, retirement, validation and feedback budgets live in [the testing policy](../agents/testing.md).
