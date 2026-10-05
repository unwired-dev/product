---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Open Gmail message bodies on iPhone, iPad and Mac.

- **Rich reader:** HTML mail renders in an isolated WebKit view from a sanitized, app-generated document. It runs no page JavaScript, keeps no website data, makes no network loads, and cancels every navigation. Remote images become placeholders, tracking pixels are removed, and visible inline images are shown once their bytes are validated. Plain-text mail, and any message the rich view cannot render, shows as selectable text.
- **Multiple readers:** windows share the body download while each image presentation stays within the shared budget. Opening another window preserves the document and reading position in existing readers.
- **Links:** a link opens only after the person confirms its full destination. Suspicious links explain why and offer Copy link or Proceed, and every link is reachable from the keyboard.
- **Saved bodies:** opened bodies are saved in an encrypted cache on the device, so they reopen offline. After the Inbox is available, recent single-part messages from the last 30 days are prefetched one at a time, yielding to messages the person opens.
- **Cache limits:** saved bodies are sealed to their mailbox and message and stay within a 500 MB device limit. Opened older bodies are evicted before prefetched ones, and the recent working set is protected. Bodies leave with their message, another mailbox choice, sign-out or deletion.
- **Unavailable bodies:** a body that cannot be shown says whether it still needs downloading, needs Gmail permission again, or is no longer in Gmail.
