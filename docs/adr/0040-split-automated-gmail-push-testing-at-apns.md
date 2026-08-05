# Split automated Gmail push testing at APNs

Automated Gmail compatibility testing proves real watch registration, Pub/Sub delivery, isolated Convex routing, and the exact APNs background-push payload, then injects that payload into a Mail Test Device to prove device-side history synchronization. It does not claim to test live APNs transport; a manual physical-device pre-release check owns that remaining seam. This trades a single uninterrupted automated path for deterministic hosted-CI coverage of both sides without disguising simulator injection as production push delivery.
