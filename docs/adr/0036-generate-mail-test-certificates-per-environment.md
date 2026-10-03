# Generate mail-test certificates per environment

Amended on 2026-10-03 at the maintainer's request to match the harness: each
environment generates one short-lived, self-signed, hostname-valid certificate
instead of a separate certificate authority and server certificate. That
certificate is installed as a trusted root only on the environment's Mail Test
Device. Key retention, ownership-checked deletion and the absence of a
permanent repository-wide trust anchor are unchanged. The paragraph below
records the original decision.

Each disposable Mail Test Run generates a short-lived certificate authority and hostname-valid server certificate, and each persistent Manual Mail Sandbox generates and retains its own separate certificate material. The authority is trusted only by that environment's Mail Test Device; private keys remain in generated environment state, are never committed, and are deleted only after cleanup validates exact ownership. When ownership is uncertain, the keys remain only for the documented ownership-checked recovery process. This preserves the production TLS 1.2-or-newer and server-identity checks without introducing a permanent repository-wide trust anchor.
