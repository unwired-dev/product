# Fail closed when mail-test cleanup ownership is uncertain

The Mail Test Harness may terminate, delete, or reset only resources identified by a valid Mail Test Ownership Record and must fail closed when exact ownership cannot be proven. Interrupted or ambiguous cleanup leaves a reported orphan for an explicit ownership-checked recovery command rather than matching processes, simulators, or files by a broad name or pattern. This accepts occasional manual cleanup to prevent an automated run or agent from damaging unrelated developer state.
