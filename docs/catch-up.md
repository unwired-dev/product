# Catch Up

Setup, coding rules, validation and observable requirements remain in this file.

[Catch Up](domain/organization.md) is a planned chat-style presentation of the
Inbox for getting through mail quickly. Except for collapsed category mail described
below, each message appears as one bubble with its
[Background Message Summary](domain/assistance.md), or its preview when no summary
exists. Nothing here is implemented yet. The work is tracked in
[#807](https://github.com/unwired-dev/product/issues/807) and its sub-issues.

## Behavior

- A list/chat toggle in the Inbox header switches between the message list and
  Catch Up and remembers the last choice. The list is the default. Both views
  show the same mail and share archive, delete and read state.
- Each message is one bubble, with no grouping by Thread, except collapsed
  category mail described below. A message bubble shows the
  sender's avatar and name, the subject as one muted line, the summary or preview
  in up to three lines, the time, an unread dot and an attachment icon when the
  message has attachments. Messages the person sent appear as right-aligned
  “me” bubbles.
- The newest message is at the bottom. Catch Up opens at an unread divider above
  the oldest message not yet seen in Catch Up. On first open, already read
  messages count as seen and unread ones as unseen; with nothing unseen, Catch Up
  opens at the bottom. Afterwards, scrolling past a bubble marks it seen in
  Catch Up only; it never changes [Message Read State](domain/messages-and-delivery.md).
- Mail in Gmail's Promotions, Social, Updates and Forums categories collapses into
  one bubble, such as "12 newsletters", which expands inline into message bubbles
  when tapped. It has no other interactions; the ones below apply to message
  bubbles.
- Tapping a bubble opens the Thread view scrolled to that message and highlights
  it. The Thread view is the existing
  [conversation reader](product/messages-and-delivery.md), with its message order,
  and keeps quoted history collapsed and expandable.
- Swiping right on a bubble opens quick reply: a composer bar at the bottom with a
  chip quoting the message and showing its recipients. It replies to everyone when
  the message had several recipients and sends through the Outbox with an undo
  window. Quoted history follows the existing Reply All Draft behavior.
- Long-pressing a bubble opens archive, delete, mark unread, reply and open Thread.
  Archive, delete and mark unread are labelled as Thread actions and act on the
  whole Thread, changing all its bubbles together. Reply and quick reply target
  the pressed message.

## Summaries

- Background Message Summaries are created by Apple's on-device system language
  model through the binding described in [On-device message summaries](message-summaries.md).
  There is no cloud or product-backend model fallback.
- Summaries run only after the person turns on
  [Mail Assistance Enablement](domain/assistance.md) on that device. It defaults
  off, and Catch Up offers it with an explanation that summaries stay on the
  device. Until then, bubbles show previews.
- Only bounded new content already on the device is summarized; quoted history
  is removed first. Inference never fetches missing bodies, attachments, Inline
  Images or Remote Message Content. Collapsed category mail is not summarized.
- Results belong to their owning account, mailbox and message input revision.
  Disabling assistance or losing account or Profile access cancels active work
  and rejects late results; changed source text invalidates the summary.
- Summarizing runs in background time when iOS grants it and whenever the app
  opens. Each pass prioritizes unseen messages, newest first, at most 50.
- A summary is stored only in the device's encrypted local cache beside its
  message and is deleted with it. It is never synchronized, sent to a server or
  written into mail or Drafts.
- While a summary is pending, the bubble shows the preview with a "Summary coming
  soon" note and swaps in the summary when it arrives. Without enablement, or on a
  device where the model cannot run, bubbles show the preview without the note.
- The first version uses real synced Gmail with stand-in summaries behind the
  same interface the on-device summarizer will implement.

## Platforms

The Expo mobile app comes first. The [macOS app](macos-client.md) follows with the
same behavior.
