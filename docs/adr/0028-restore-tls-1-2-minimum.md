---
status: accepted
---

# Restore the TLS 1.2 minimum

IMAP, SMTP, POP3, and Exchange Web Services connections require TLS 1.2 or newer with valid server identity before authentication. The client continues to prefer implicit TLS, requires a successful STARTTLS upgrade when configured, rejects authentication before TLS is established, rejects certificate failures, and provides no invalid-certificate override.

This supersedes ADR-0026 and restores the minimum established by ADR-0017. Compatibility with servers limited to TLS 1.0 or TLS 1.1 does not justify negotiating protocol versions deprecated by [RFC 8996](https://www.rfc-editor.org/rfc/rfc8996.html). A qualified third-party mail engine must apply the TLS 1.2 floor to every implicit TLS, STARTTLS, IDLE, and auxiliary connection. The product will configure that floor explicitly even when the engine currently uses TLS 1.2 as its default.
