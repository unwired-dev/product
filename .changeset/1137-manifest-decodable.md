---
'@private-email/macos': patch
'@private-email/mobile': patch
---

The categorization spike's `Manifest` and `Manifest.Labels` are now `Decodable` instead of `Codable`, and its unused label encoder is gone. Manifests still decode both label shapes.
