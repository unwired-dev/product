# Catch Up

Setup, coding rules, validation and observable requirements remain in this file.

[Catch Up](domain/organization.md) is a planned chat-style presentation of the
Inbox for getting through mail quickly. Except for collapsed category mail described
below, each message appears as one bubble with its
[Background Message Summary](domain/assistance.md), or its preview when no summary
exists. Only the Thread view is implemented so far (see
[Thread view](#thread-view)). The work is tracked in
[#807](https://github.com/unwired-dev/product/issues/807) and its sub-issues.

## Behavior

- A list/chat toggle in the Inbox header switches between the message list and
  Catch Up. Each device, and each Mac window, remembers its own last choice; it
  is never synchronized. The list is the default. Both views show the same mail
  and share archive, delete and read state.
- Each message is one bubble, with no grouping by Thread, except collapsed
  category mail described below. A message bubble shows the
  sender's avatar and name, the subject as one muted line, the summary or preview
  in up to three lines, the time, an unread dot and an attachment icon when the
  message has attachments. Messages the person sent appear as right-aligned
  “me” bubbles.
- The newest message is at the bottom. Catch Up opens at an unread divider above
  the oldest message not yet seen in Catch Up; with nothing unseen, it opens at
  the bottom.
- When the oldest unseen message is inside a collapsed category bubble, the
  divider sits above the bubble, which stays collapsed.
- Messages that enter Catch Up on first open, from a newly connected
  mailbox or through history backfill count as seen when already read and unseen
  otherwise; newly arriving mail is unseen.
- Scrolling past a bubble marks it seen in Catch Up only; it never changes
  [Message Read State](domain/messages-and-delivery.md).
- Seen markers are durable device-local state for one Product Account and
  Mailbox Connection. They survive relaunches, are never synchronized, and are
  removed with the message's local data, its Mailbox Connection or the Product
  Account. Each device keeps its own divider; another device starts from the
  read-state baseline.
- Each run of consecutive messages in Gmail's Promotions, Social, Updates and
  Forums categories collapses into one bubble, such as "12 newsletters", so the
  timeline stays in order; a run of one shows as a message bubble.
- Tapping a collapsed category bubble expands it inline into message bubbles;
  scrolling past it marks all its messages seen. It has no other interactions;
  the ones below apply to message bubbles.
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
- Mark unread changes Message Read State only; it does not clear seen markers or
  move the divider.

## Thread view

The Expo app's Thread view opens at `/thread/[id]?mailbox=<connection>`. The Inbox list
still opens the single-message reader; Catch Up bubbles will open the Thread view.

- It shows every locally cached message with the opened message's Gmail
  `threadId` (the listed Inbox and any open search results), newest at the top.
  A message that is not cached shows as unavailable.
- It scrolls to the opened message and highlights it
  (`accessibilityState.selected`). Until the person drags the reader, every new
  layout of that message scrolls to it again, so bodies loading above it keep it in
  place.
- Each message starts with its quoted history collapsed behind **Show quoted
  text**. Quoted history is Gmail's `gmail_quote` container, a
  `blockquote type="cite"` (Apple Mail, Thunderbird), everything from an
  "Original Message" marker, or the trailing run of `>` lines with the
  attribution line above it. Inline replies and Outlook HTML quotes stay
  shown. A body that would be empty without its quote shows in full.

Bodies initially load the opened message first, then the messages intersecting the viewport,
then the rest in distance-from-viewport order. Scrolling reorders reads that are
still waiting; reads already running finish. The order applies within each
Mailbox Connection's two body loads and the device-wide four, so other
connections keep their own loads. After dragging, visible messages take priority
over the opened message too. Leaving a Thread lowers its pending background reads
below the current Thread's work. Every cached message's body is brought onto the
device whether or not its view is mounted.

Every message header stays mounted, but a body view and its rich document mount
only while the message lies within one viewport of the visible range (the opened
message's body always stays mounted). A body that leaves that range keeps its
measured height, and returning to it opens the body from the device again,
including its quoted text collapsed and, under **Ask**, a new Remote Message
Content consent.

The `registration-thread` [Mock Mail Session](mock-mail-sessions.md) journey
checks scroll-to, the visible text position before and after a held newer body
above resolves following a drag, and body unmounting and remounting on iPhone and
iPad simulators. CI does not run it;
highlight accessibility and physical devices still require validation.

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
  message body. It counts toward the
  [Bounded Encrypted Body Cache](product/privacy-and-sync.md) limit and is removed
  when the body is evicted, the cache is cleared or the message is deleted.
  It is never synchronized, sent to a server or written into mail or Drafts.
- While a summary is pending, the bubble shows the preview with a "Summary coming
  soon" note and swaps in the summary when it arrives. Without enablement, or on a
  device where the model cannot run, bubbles show the preview without the note.
- The first version uses real synced Gmail with stand-in summaries behind the
  same interface the on-device summarizer will implement.

## Platforms

The Expo mobile app comes first. The [macOS app](macos-client.md) follows with the
same behavior.
