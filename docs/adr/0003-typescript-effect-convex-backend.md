# TypeScript, Effect, and Convex backend

The backend will use TypeScript with Effect for explicit error, dependency, and async workflow handling, and Convex for the backend database and server functions. Convex is a good fit for product account data, encrypted sync blobs, device records, minimal push metadata, webhook handling, and operational state, but it must not become a mailbox sync engine or store backend-readable mail content, categories, classifications, provider tokens, or message bodies.
