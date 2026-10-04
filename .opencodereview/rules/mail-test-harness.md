Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. These rules cover the retained legacy Mail Test Harness under ADR 0042; its dependency-free Effect exemption remains in force.

#### Preserved failures remain recoverable

- In `ownership.ts`, `cleanupOwnedRun` leaves a preserved failure state from which explicit ownership-checked recovery cannot proceed. Check every persisted state, including the old valid record retained when the preservation write itself fails after process termination; tests must start with the production process marker rather than an already-cleared record.
- In `ownership.ts`, a failed process probe is treated as proof of absence. Only a no-such-process result proves the recorded process is gone; permission or unknown failures must preserve the record and resources rather than allow destructive cleanup.
- In `harness.ts`, a caller or finalizer automatically retries cleanup after `cleanupOwnedRun` reports preservation, potentially removing the run before `doctor` or explicit recovery can inspect it. Verify preservation through the public scenario lifecycle, including transient Simulator failures.
