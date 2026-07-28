---
status: superseded by ADR-0028
---

# Allow legacy TLS versions

Mail connections may negotiate TLS 1.0 or newer, including bundled and manually configured providers, without a separate legacy-compatibility opt-in. The client still requires encryption before authentication, validates the server identity, provides no invalid-certificate override, and prefers implicit TLS while requiring a successful STARTTLS upgrade when configured. This supersedes ADR 0017 only where it required TLS 1.2 or newer, trading protection against deprecated TLS versions for broader server compatibility while retaining the rest of that ADR's security boundary.
