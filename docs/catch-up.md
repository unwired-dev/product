# Catch Up

Setup, coding rules, validation and observable requirements remain in this file.

[Catch Up](domain/organization.md) is a planned chat-style presentation of the
Inbox for getting through mail quickly. Each message appears as one bubble with its
[Background Message Summary](domain/assistance.md), or its preview when no summary
exists. Nothing here is implemented yet. The work is tracked in
[#807](https://github.com/unwired-dev/product/issues/807) and its sub-issues.

## Behavior

- A list/chat toggle in the Inbox header switches between the message list and
  Catch Up and remembers the last choice. The list is the default. Both views
  show the same mail and share archive, delete and read state.
- Each message is one bubble, with no grouping by Thread. A bubble shows the
  sender's avatar and name, the subject as one muted line, the summary or preview
  in up to three lines, the time, an unread dot and an attachment icon when the
  message has attachments. Messages the person sent appear as right-aligned
  bubbles.
- The newest message is at the bottom. Catch Up opens at an unread divider above
  the oldest message not yet seen in Catch Up. Scrolling past a bubble marks it
  seen in Catch Up only; it never changes [Message Read State](domain/messages-and-delivery.md).
- Mail in Gmail's Promotions, Social, Updates and Forums categories collapses into
  one bubble per run, such as "12 newsletters", which expands inline when tapped.
- Tapping a bubble opens the Thread view scrolled to that message and highlights
  it. The Thread view stacks every locally cached message of the Thread as a
  document, oldest first, with quoted history collapsed.
- Swiping right on a bubble opens quick reply: a composer bar at the bottom with a
  chip quoting the message and showing its recipients. It replies to everyone when
  the message had several recipients and sends through the Outbox with an undo
  window.
- Long-pressing a bubble opens archive, delete, mark unread, reply and open Thread.

## Summaries

- Background Message Summaries are created by Apple's on-device system language
  model through the binding described in [On-device message summaries](message-summaries.md).
  There is no cloud or product-backend model fallback.
- Summaries run only after the person turns on
  [Mail Assistance Enablement](domain/assistance.md) on that device. It defaults
  off, and Catch Up offers it with an explanation that summaries stay on the
  device. Until then, bubbles show previews.
- Only the message's new content is summarized; quoted history is removed first.
  Collapsed category mail is not summarized.
- Summarizing runs in background time when iOS grants it and whenever the app
  opens. Each pass takes unseen messages newest first, at most 50.
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
