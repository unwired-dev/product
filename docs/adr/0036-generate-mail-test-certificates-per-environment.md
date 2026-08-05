# Generate mail-test certificates per environment

Each disposable Mail Test Run generates a short-lived certificate authority and hostname-valid server certificate, and each persistent Manual Mail Sandbox generates and retains its own separate certificate material. The authority is trusted only by that environment's Mail Test Device; private keys remain in generated environment state, are never committed, and are deleted with disposable runs. This preserves the production TLS 1.2-or-newer and server-identity checks without introducing a permanent repository-wide trust anchor.
