# Isolate mail testing in harness-owned simulators

Every automated Mail Test Run creates and later deletes its own iPhone 17 Simulator, while the Manual Mail Sandbox uses a separately named persistent simulator. The Mail Test Harness installs local mail-server certificate trust only into these Mail Test Devices and never changes the developer Mac or an ordinary simulator. This accepts simulator startup overhead to isolate application data, Keychain state, certificate trust, cleanup, and concurrent agent runs.
