---
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Run Product Sync initialization and mailbox descriptor synchronization in
TypeScript. Deciding when to create and publish the account keys, reading every
page of descriptors, compare-and-set writes, removals and their tombstones, and the
Product Sync status shown on each device now run as Effect programs in
`@private-email/mail-core`. Native code keeps every key: it creates and stores the
key ring and Recovery Key before anything is published, and seals and opens each
record. iPhone, iPad and Mac behave as before.
