---
'@private-email/mobile': patch
'@private-email/macos': patch
---

Summarize shows the summary as readable prose on iPhone, iPad and Mac. Apple's
on-device model answered with the JSON request's fields wrapped around the
summary. The model is now asked for plain prose, and a result that is still a
serialized object fails as a summary error instead of showing.
