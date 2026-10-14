---
name: Unwired Mail
description: A calm, private, precise mail client for macOS 27 and iOS 27.
colors:
  accent-fill: '#3A3D44'
  accent-fill-dark: '#6A6E78'
  accent-on-fill: '#FFFFFF'
  accent-ink: '#3A3D44'
  accent-ink-dark: '#C8CBD2'
  accent-selection-subtle: 'rgba(58, 61, 68, 0.12)'
  accent-selection-subtle-dark: 'rgba(200, 203, 210, 0.16)'
  on-device-ink: '#A3321F'
  on-device-ink-dark: '#FF9E88'
  on-device-surface: '#FBEEEA'
  on-device-surface-dark: '#3A2420'
  brand-deep: '#15171B'
  brand-on-deep: '#FFFFFF'
  brand-seal: '#C2412A'
  brand-on-seal: '#FFFFFF'
  brand-monogram: '#15171B'
  brand-monogram-dark: '#6A6E78'
  apple-button: '#000000'
  apple-button-dark: '#FFFFFF'
  apple-on-button: '#FFFFFF'
  apple-on-button-dark: '#000000'
  text-primary: 'rgba(0, 0, 0, 0.85)'
  text-primary-dark: 'rgba(255, 255, 255, 0.85)'
  text-secondary: 'rgba(0, 0, 0, 0.6)'
  text-secondary-dark: 'rgba(255, 255, 255, 0.55)'
  surface-content: '#FFFFFF'
  surface-content-dark: '#1E1E1E'
  surface-sidebar: '#F3F2F5'
  surface-sidebar-dark: '#2A2A2C'
  surface-bubble: '#F1F1F4'
  surface-bubble-dark: '#2C2C2E'
  fill-quiet: 'rgba(0, 0, 0, 0.05)'
  fill-quiet-dark: 'rgba(255, 255, 255, 0.06)'
  fill-track: 'rgba(0, 0, 0, 0.09)'
  fill-track-dark: 'rgba(255, 255, 255, 0.16)'
  separator: 'rgba(0, 0, 0, 0.1)'
  separator-dark: 'rgba(255, 255, 255, 0.1)'
  status-warning: '#C93400'
  status-warning-dark: '#FFB340'
  status-destructive: '#D70015'
  status-destructive-dark: '#FF6961'
typography:
  macos-large-title:
    fontFamily: 'SF Pro'
    fontSize: '26px'
    fontWeight: 400
    lineHeight: '32px'
  macos-title-3-emphasized:
    fontFamily: 'SF Pro'
    fontSize: '15px'
    fontWeight: 600
    lineHeight: '20px'
  macos-body:
    fontFamily: 'SF Pro'
    fontSize: '13px'
    fontWeight: 400
    lineHeight: '16px'
  macos-body-emphasized:
    fontFamily: 'SF Pro'
    fontSize: '13px'
    fontWeight: 600
    lineHeight: '16px'
  macos-subheadline:
    fontFamily: 'SF Pro'
    fontSize: '11px'
    fontWeight: 400
    lineHeight: '14px'
  reading-subject:
    fontFamily: 'SF Pro'
    fontSize: '20px'
    fontWeight: 700
    lineHeight: '25px'
  reading-body:
    fontFamily: 'SF Pro'
    fontSize: '15px'
    fontWeight: 400
    lineHeight: '22px'
  ios-large-title:
    fontFamily: 'SF Pro'
    fontSize: '34px'
    fontWeight: 700
    lineHeight: '41px'
  ios-headline:
    fontFamily: 'SF Pro'
    fontSize: '17px'
    fontWeight: 600
    lineHeight: '22px'
  ios-body:
    fontFamily: 'SF Pro'
    fontSize: '17px'
    fontWeight: 400
    lineHeight: '22px'
  ios-subheadline:
    fontFamily: 'SF Pro'
    fontSize: '15px'
    fontWeight: 400
    lineHeight: '20px'
  ios-footnote:
    fontFamily: 'SF Pro'
    fontSize: '13px'
    fontWeight: 400
    lineHeight: '18px'
  ios-caption-1:
    fontFamily: 'SF Pro'
    fontSize: '12px'
    fontWeight: 400
    lineHeight: '16px'
  ios-title-3-emphasized:
    fontFamily: 'SF Pro'
    fontSize: '20px'
    fontWeight: 600
    lineHeight: '25px'
rounded:
  control: '6px'
  row: '7px'
  card: '10px'
  bubble: '20px'
  window: '16px'
  mailbox-group: '22px'
spacing:
  xs: '4px'
  s: '8px'
  m: '12px'
  l: '16px'
  xl: '20px'
components:
  button-primary:
    backgroundColor: '{colors.accent-fill}'
    textColor: '{colors.accent-on-fill}'
    typography: '{typography.macos-body-emphasized}'
    rounded: '{rounded.control}'
    padding: '0 12px'
    height: '28px'
  button-secondary:
    backgroundColor: '{colors.fill-quiet}'
    textColor: '{colors.text-primary}'
    typography: '{typography.macos-body}'
    rounded: '{rounded.control}'
    padding: '0 12px'
    height: '28px'
  button-brand:
    backgroundColor: '{colors.brand-seal}'
    textColor: '{colors.brand-on-seal}'
    typography: '{typography.macos-body-emphasized}'
    rounded: '{rounded.control}'
    padding: '0 12px'
    height: '28px'
  message-row-selected:
    backgroundColor: '{colors.accent-fill}'
    textColor: '{colors.accent-on-fill}'
    rounded: '{rounded.row}'
    padding: '8px 12px 9px 22px'
  sidebar-item-selected:
    backgroundColor: '{colors.accent-selection-subtle}'
    textColor: '{colors.text-primary}'
    typography: '{typography.macos-body-emphasized}'
    rounded: '{rounded.control}'
    padding: '0 8px'
    height: '28px'
  summary-card:
    backgroundColor: '{colors.on-device-surface}'
    textColor: '{colors.text-primary}'
    rounded: '{rounded.card}'
    padding: '12px'
  category-chip-selected:
    backgroundColor: '{colors.accent-fill}'
    textColor: '{colors.accent-on-fill}'
    typography: '{typography.macos-body-emphasized}'
    rounded: '14px'
    padding: '0 12px 0 10px'
    height: '28px'
  category-chip:
    backgroundColor: '{colors.fill-quiet}'
    textColor: '{colors.text-primary}'
    rounded: '14px'
    padding: '0 12px 0 10px'
    height: '28px'
  catch-up-bubble-received:
    backgroundColor: '{colors.surface-bubble}'
    textColor: '{colors.text-primary}'
    typography: '{typography.ios-subheadline}'
    rounded: '{rounded.bubble}'
    padding: '10px 14px 12px'
  catch-up-bubble-sent:
    backgroundColor: '{colors.accent-fill}'
    textColor: '{colors.accent-on-fill}'
    typography: '{typography.ios-subheadline}'
    rounded: '{rounded.bubble}'
    padding: '10px 14px 12px'
---

# Design System: Unwired Mail

This document records the agreed native design target, including planned screens
such as Catch Up. It does not describe shipped coverage or change release scope;
the feature guides and launch specification own those requirements. Layout
dimensions describe the Figma reference mockups. Both clients read the color,
type, spacing and radius tokens from `packages/mail-core/src/theme.ts`, and
render SF Symbols and Liquid Glass through the shared views in `native/design`.

The visual reference for screens and components is the Figma file
[Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T).
Its `Unwired` variable collection holds every color token below in Light and
Dark modes. Tokens with a `-dark` suffix are the Dark value of the token
without the suffix; a token without a `-dark` sibling is the same in both modes.
Dimensions in the frontmatter use `px` because the DESIGN.md format requires CSS
units. The Figma frames are drawn at 1×, so 1px equals 1pt on Apple platforms.
The linked product requirements and feature guides govern behavior, controls and
defaults wherever an earlier reference mockup differs.

## Overview

**Creative North Star: "The quiet desk"**

Unwired Mail should feel like a well-kept desk: calm, private and precise. It is
a native Apple app first. It uses Apple's system materials, controls, SF Pro and
SF Symbols, and adds brand only where it carries meaning. Almost every pixel is
an Apple system neutral; the brand shows in three places: the graphite accent,
the cinnabar seal on work done on the device, and the deep graphite of brand
moments such as Welcome and the Recovery Key.

The palette is called "Graphite & Cinnabar". Graphite keeps selection, buttons
and links close to Apple's own Graphite accent, so the interface recedes behind
the mail. Cinnabar is the seal: it marks summaries, incoming translations and
unaccepted Mail Assistance previews and suggestions as made on this device,
and the one brand action on Welcome. Accepted assistance becomes ordinary Draft
content without the marker.

**Key characteristics:**

- Native macOS 27 and iOS 27 structure, controls and type.
- Liquid Glass only on the navigation layer: sidebar, toolbar groups, the search
  bar, menus and sheets. Content surfaces stay opaque.
- One accent, used sparingly; meaning is never carried by color alone.
- Light and Dark are designed as separate modes, not an inversion.

## Colors

Graphite neutrals with a single warm seal.

| Role              | Token                     | Light         | Dark          | Use                                                           |
| ----------------- | ------------------------- | ------------- | ------------- | ------------------------------------------------------------- |
| Accent fill       | `accent/fill`             | `#3A3D44`     | `#6A6E78`     | Selected message row, primary button, unread dot, sent bubble |
| On accent         | `accent/on-fill`          | `#FFFFFF`     | `#FFFFFF`     | Text and icons on the accent fill                             |
| Accent ink        | `accent/ink`              | `#3A3D44`     | `#C8CBD2`     | Links, tinted sidebar icons, New Message                      |
| Subtle selection  | `accent/selection-subtle` | `#3A3D44` 12% | `#C8CBD2` 16% | Selected sidebar item, pressed controls                       |
| On device ink     | `on-device/ink`           | `#A3321F`     | `#FF9E88`     | The cinnabar seal: On device marker text and icon             |
| On device surface | `on-device/surface`       | `#FBEEEA`     | `#3A2420`     | Summary card and Mail Assistance surfaces                     |
| Brand deep        | `brand/deep`              | `#15171B`     | `#15171B`     | Welcome, Recovery Key, Undo Send toast                        |
| On brand deep     | `brand/on-deep`           | `#FFFFFF`     | `#FFFFFF`     | Text and icons on brand deep                                  |
| Brand seal        | `brand/seal`              | `#C2412A`     | `#C2412A`     | Welcome "Continue" only                                       |
| On brand seal     | `brand/on-seal`           | `#FFFFFF`     | `#FFFFFF`     | Text and icons on brand seal                                  |
| Monogram          | `brand/monogram`          | `#15171B`     | `#6A6E78`     | Mail Profile and account monograms                            |
| Apple button      | `apple/button`            | `#000000`     | `#FFFFFF`     | Sign in with Apple only, per Apple's button styles            |
| On Apple button   | `apple/on-button`         | `#FFFFFF`     | `#000000`     | Text and the Apple logo on the Apple button                   |
| Primary text      | `text/primary`            | black 85%     | white 85%     | Mirrors macOS Labels/Primary                                  |
| Secondary text    | `text/secondary`          | black 60%     | white 55%     | Previews, timestamps, captions                                |
| Content surface   | `surface/content`         | `#FFFFFF`     | `#1E1E1E`     | Message list and reading pane                                 |
| Sidebar surface   | `surface/sidebar`         | `#F3F2F5`     | `#2A2A2C`     | Opaque stand-in for the sidebar material                      |
| Bubble surface    | `surface/bubble`          | `#F1F1F4`     | `#2C2C2E`     | Received Catch Up bubbles                                     |
| Quiet fill        | `fill/quiet`              | black 5%      | white 6%      | Secondary buttons, search field, banners, chips               |
| Track             | `fill/track`              | black 9%      | white 16%     | Off switch track                                              |
| Separator         | `separator`               | black 10%     | white 10%     | Hairlines between rows and panes                              |
| Warning           | `status/warning`          | `#C93400`     | `#FFB340`     | Authorization needed, Pin indicator                           |
| Destructive       | `status/destructive`      | `#D70015`     | `#FF6961`     | Delete Product Account, Delete                                |

Contrast (WCAG 2.x, AA is 4.5:1 for text and 3:1 for non-text):

| Pairing                            | Light | Dark  |
| ---------------------------------- | ----- | ----- |
| On accent on accent fill           | 10.88 | 5.10  |
| Accent ink on content              | 10.88 | 10.26 |
| Primary text on content            | 15.08 | 12.30 |
| Secondary text on content          | 5.74  | 5.91  |
| Secondary text on bubble           | 5.54  | 5.34  |
| On device ink on on device surface | 6.11  | 7.22  |
| Warning on content                 | 5.28  | 9.35  |
| Destructive on content             | 5.38  | 5.91  |
| White on brand deep                | 17.94 | 17.94 |
| White on brand seal                | 5.14  | 5.14  |
| White on monogram                  | 17.94 | 5.10  |
| Unread dot (non-text) on content   | 10.88 | 3.27  |

`text/secondary` is 60% black, not the macOS Labels/Secondary 50% black, which
reaches only 3.95:1 on white and fails AA for text.

## Typography

SF Pro throughout the app UI, using Apple's text styles; no custom UI typeface. The Figma file
keeps local copies of the macOS 27 and iOS 27 kit ramps (`macOS/…` and `iOS/…`
styles) so the file stays editable.

- **macOS:** Body 13/16 for lists, sidebars and controls; Body Emphasized 13/16
  semibold for unread senders and primary buttons; Subheadline 11/14 for
  timestamps and section headers; Title 3 Emphasized 15/20 for list and page
  titles.
- **iPad message list:** the Inbox frames use the Mac recipe at 1.15× in both
  orientations: Body 14.95/18.4, Subheadline 12.65/16.1 and Title 3 Emphasized
  17.25/23. Row insets, unread indicators and dividers use the same scale;
  interactive controls retain at least 44pt touch targets.
- **Reading pane:** Reading Body 15/22 for message text (larger than Mac Body for
  long-form reading) and Reading Subject 20/25 bold for the Thread subject. These
  reference sizes respect the [reader's accessibility sizing](docs/gmail-inbox.md#presentation-accessibility-and-fallback).
- **iOS:** Large Title 34/41 bold, Headline 17/22 semibold, Body 17/22,
  Subheadline 15/20 for list subjects, timestamps, previews and bubble text,
  Footnote 13/18 for supporting labels,
  Caption 1 12/16 for the inline title's subtitle and Title 3 Emphasized 20/25
  for empty-state titles.
- UI emphasis comes from weight, not size. Never set long UI text in bold.
  Received message content retains permitted sender formatting, including fonts,
  sizes and emphasis, under the [sanitization contract](docs/gmail-inbox.md#sanitization-contract).

## Layout

- **macOS window:** 1280×800 reference, three columns. A floating glass sidebar
  236pt wide inset 8pt, a 340pt message list, and the reading pane. The reading
  pane uses 40pt side padding and starts below the toolbar at 72pt. A 900pt
  narrow window hides the sidebar. Compact layouts collapse the three destinations
  into native navigation, per the [organization requirements](docs/product/organization.md).
- **Sidebar order:** the Mail Profile switcher (full column width) at the top,
  then the primary Unified Mailboxes (Inbox, Snoozed, Pins, Drafts and Sent),
  secondary Archive, All Mail, Spam and Trash, one collapsible section per
  Mailbox Connection ("Gmail · address") with
  its folders and labels, Saved Searches, and Settings pinned to the bottom.
  Synchronization and authorization problems appear beside the affected Mailbox
  Connection. Conditional [Outbox](docs/outbox.md#sending) sits above Drafts.
  Profile scoping follows the [mailbox requirements](docs/product/mailboxes.md#unified-mailboxes).
  The reference mockups show Favorites and per-list banners and omit the secondary mailboxes.
- **Message list header:** mailbox title, a subtitle carrying unread count and
  sync status, and a row of up to five Mail View chips, as the
  [organization requirements](docs/product/organization.md) specify: Important and
  All Messages first and second, then up to three configured Category views
  (Orders, Newsletters & Promotions and Flights for new users).
  The reference mockups show an earlier System Category row with All selected.
- **Search bar:** search and New Message share one floating glass bar at the
  bottom of the window, as the [organization requirements](docs/product/organization.md)
  specify. The search field is 400pt wide and centered, with New Message pinned
  to the trailing edge. On compact layouts it spans the screen width. Rows scroll
  under it behind a 72pt scroll edge fade. It hides while the composer is open.
- **Command Palette:** on the Mac a 36pt glass command input (command
  symbol, "Commands", ⌘P key cap) stays in a bar at the top of the window; open,
  it becomes the focused query with an esc key cap and a 460pt glass panel with
  the menu shadow beneath it.
  Rows are 28pt with an SF Symbol, the name, a disabled reason in secondary text
  or a chevron for a picker, highlighted in the accent fill; section headers read
  Selected Message · subject, App and Go To, and a footer names the keys. iPhone
  and iPad show a panel attached to the top with the input, Cancel and 44pt rows;
  iPad keeps the command input in the Inbox heading and, pending a compact
  frame, in the reader and composer headers too; iPhone opens by header swipe
  with a one-time hint. See the [Command Palette guide](docs/command-palette.md).
- **Synchronization status:** retain the bottom-anchored, non-blocking progress
  overlay, Retry on failure, aggregate progress with expandable connection details,
  and globally visible refresh and last success from the
  [sync-status requirements](docs/product/privacy-and-sync.md#local-storage-and-background-freshness).
  Status never shifts visible Threads; the header subtitle does not replace the
  overlay or connection-local problem indicators.
- **Conversation reader:** one flat scroll, subject and Thread summary first,
  then every message expanded newest to oldest with compact sender-and-date headers,
  disclosed recipients, bodies and thin separators, per the
  [reader loading and image requirements](docs/product/messages-and-delivery.md#thread-identity-and-reader-behavior).
  Received attachments sit below their message body, with availability and actions
  following the [received-attachment contract](docs/gmail-inbox.md#received-attachments).
- **Toolbar:** one fixed reader toolbar of glass button groups over the reading
  pane, per the
  [conversation reader requirements](docs/product/messages-and-delivery.md):
  Reply, Reply All, Forward and the multi-select Category control, which target
  the newest message; Archive, Delete, Move, Spam, Pin, Muted Thread, and Mark
  Read or Unread target the whole Thread. Snooze also targets the whole Thread,
  per the [Thread Snooze requirements](docs/product/organization.md#snooze-and-follow-up-notes). The reference
  mockups show only Archive, Delete, Move, Reply, Reply All, Forward, a flag and
  Snooze.
- **Compose:** follows the
  [composer presentation requirements](docs/product/messages-and-delivery.md#prototype-composer-presentation).
  On regular width it opens as a bottom-anchored, nonmodal overlay inside the
  reading pane with 12pt outer insets and 70% of the available height, clamped
  from 420 to 720pt. Expanding it takes over the whole app window with the same
  Draft; there is no separate Compose window and no freeform resizing. Compact
  layouts push the composer onto the navigation stack. Order: body, attachments,
  Subject, To, then Cc and Bcc, which a trailing "Cc/Bcc" control on the To
  field reveals together. The sender is a From pop-up beside Send. The reference
  mockups still show an earlier separate window and a 60% inline composer.
  One composer per window keeps expand/collapse visible on regular width, Close
  directly accessible and destructive Discard in overflow. The sidebar and list
  remain interactive beneath the overlay; save failures appear inline.
- **Settings:** the Mac reference is a 900×720 independent window, opened with
  `Command-,`, with a glass sidebar grouped as Accounts, Mail, Composing,
  Automation and Application, and grouped forms on the right. iPad uses an in-app
  two-column workspace; iPhone pushes one column into the existing navigation
  stack. Detail errors and Retry stay inline beside retained values, with other
  destinations usable, per the
  [Settings requirements](docs/product/organization.md#prototype-mail-views-and-interface-behavior).
- **Spacing scale:** 4, 8, 12, 16, 20pt. Hit targets are at least 28pt on the Mac
  and 44pt on iPhone.

## Elevation & Depth

Depth comes from Apple's Liquid Glass and opaque layering, not from shadows on
content.

- Liquid Glass is reserved for the navigation layer: sidebar, toolbar groups,
  search bar, menus, popovers and sheets. Use the macOS 27 and iOS 27 kit
  material ("Liquid Glass - Medium") in its Light or Dark variant.
- Small glass controls (48pt or less) use a soft shadow: 8pt blur, 2pt down, 8%
  black in Light and 30% in Dark. Large glass (sidebar) uses 16pt blur, 4pt
  down. Menus and sheets keep a deeper 24pt shadow so they read as floating.
- Content rows are transparent so the list surface and edge effects show
  through. Never stack glass on glass.
- Where floating chrome overlaps content, use a scroll edge fade instead of a
  divider.

## Shapes

- Controls 6pt, message rows 7pt, cards and banners 10pt, windows 16pt.
- Pills and chips are fully rounded (14pt at 28pt tall). Catch Up bubbles are
  20pt. Glass groups take half their height.
- Monograms and avatars are circles. Message list rows show a real contact photo
  only when the contact-images preference is on and a photo exists, and never
  generate initials. Catch Up bubbles and the Thread view show the contact photo
  or neutral initials.
- iPhone Mailboxes uses 22pt rounded groups of 52pt rows, as shown in the Mailboxes frames.

## Components

The Figma Components page holds each component with its variants and a
description. Apple kit components are used wherever they fit (window controls,
form accessories, keyboards, status bar).

- **Button:** Primary (graphite), Secondary (quiet fill), Brand (cinnabar, Welcome
  "Continue" only). 28pt tall.
- **Message Row:** Mail.app-style hierarchy: sender and time, subject, then the
  preview. The preview is one line by default and follows the person's saved
  density and zero-to-three-line preview preference; the reference mockups show
  two lines. Essential attachment, Pin, Category and source-connection status
  accompany the preview, with Category badges and attachment indicators following
  the saved Inbox presentation preferences; every unified-list Thread identifies its Mailbox Connection,
  per the [list requirements](docs/product/mailboxes.md#unified-list-behavior).
  Unread shows a stronger sender and subject weight and an accent
  dot; selected is the graphite fill with white text. No generated initials and
  no hover actions; a real contact photo may appear, per the
  [list requirements](docs/product/organization.md#prototype-mail-views-and-interface-behavior).
- **Sidebar Item / Sidebar Section Header:** 28pt items with tinted SF Symbols
  and counts. A selected item uses the subtle selection fill and an emphasized
  label, so selection does not rely on the low-contrast fill alone. Section
  headers collapse with a trailing disclosure chevron; the Settings sidebar
  turns that off.
- **Profile Switcher / Profile Menu:** monogram, Mail Profile name and chevron.
  The menu lists Mail Profiles with their Mailbox Connections, unread counts and
  a checkmark, then New Mail Profile… and Manage Mail Profiles….
- **Mail View Chip (Figma: Category Chip):** the `category-chip` token recipes
  style each header chip with an icon, label and unread-Thread count badge capped
  at 99+. Selected chips are graphite with an emphasized label; others use the quiet fill.
  Settings exposes
  Important membership and three configurable Category slots, without overflow.
  Details follow the
  [Mail View requirements](docs/product/organization.md#prototype-mail-views-and-interface-behavior).
- **Category Control:** the reader's multi-select control shows Apply, Cancel and
  Add New, per the
  [Category control requirements](docs/product/organization.md#category-controls).
- **On Device Marker / Summary Card:** the cinnabar lock with "On device" marks
  Mail Assistance output while it is a summary, an incoming translation, or a
  preview or suggestion awaiting acceptance. Accepted rewrites, Draft
  translations and subjects become ordinary Draft content without the marker.
  The Summary card sits at the top of a Thread; while summarizing it shows quiet
  placeholder lines with Cancel. Dismissible, non-authoritative previews sit beside unchanged mail
  and show source, truncation and unavailable-state explanations, per
  [message summaries](docs/message-summaries.md#behavior) and
  [translation](docs/message-translation.md#behavior). Thread summary items follow
  the source-linking and disclosure contract for
  [Understanding Assistance](docs/product/assistance.md#assistance-inputs-previews-and-acceptance).
  Reader Summarize and Translate
  sit side by side when the body is local and assistance is enabled. Hide explicit
  assistance controls while device-local, default-off
  [Mail Assistance Enablement](docs/message-summaries.md#mail-assistance-enablement)
  is off.
- **Banners:** Translation, Remote Content and Authorization Needed use the quiet
  fill and 10pt radius. Actions stack under the message so long localized
  strings stay readable at the available width. Translation and remote-content
  consent belong beside their message in the reader, per
  [translation](docs/message-translation.md#behavior) and
  [remote-content requirements](docs/gmail-inbox.md#links-and-blocked-remote-content);
  authorization problems identify the affected Mailbox Connection.
- **Undo Send Toast / Outbox Row:** the toast is deep graphite, centered above the
  search bar, with Undo during the Undo Send Window. Window preferences follow the
  [delivery requirements](docs/product/messages-and-delivery.md#authored-content-and-delivery-attempts).
  [Outbox rows](docs/outbox.md#sending) show waiting, refusal and unknown-outcome
  states with recovery controls after the toast ends.
- **Compose:** Compose Format Bar (text style, bold, italic, underline,
  strikethrough, inline code, lists, link, Translate and Rewrite side by side;
  no glass),
  Compose Field (Filled, Placeholder, Recipients, Suggested), Attachment Chip,
  From Pop-up. A suggested subject carries the On device marker until explicit
  Use Subject acceptance makes it ordinary Draft content. A subject the person
  types is ordinary Draft content.
- **Compose editing and assets:** text styles cover paragraphs, headings 1–3,
  quotes and code blocks. Link editing, Undo/Redo, native text behavior, Markdown
  shortcuts, the caret-anchored Slash Command Menu and nonmodal assistance panels follow
  the [authored-content contract](docs/product/messages-and-delivery.md#authored-content-and-delivery-attempts).
  The global Formatting Toolbar Preference hides only the bar. Attachment and
  image affordances follow [Files and images](docs/drafts.md#files-and-images):
  iPhone/iPad offer Attach File, Attach Photo, Insert Image and Paste Image; Mac
  offers Attach Files… and Insert Image… plus paste/drop. Attachment Chips show
  name, size, Remove, import progress/Cancel and failure state; Inline Images retain
  their authored position, with explicit conversion actions between images and
  attachments. Keep unsaved state and reasons for blocked Send visible, per
  [Draft saving and asset availability](docs/drafts.md#saving).
- **Compose recipients and sender:** Recipient Suggestions appear beneath the
  active To/Cc/Bcc field; recipients are removable tokens. Invalid entries stay
  editable with an inline explanation; duplicates show Already added. Populated
  Cc/Bcc remain visible. From always shows the selected Sending Identity and
  explains blocked Send beside the retained address, per the
  [recipient and sender requirements](docs/product/messages-and-delivery.md#sending-identities-and-recipient-entry)
  and [Draft sender contract](docs/drafts.md#composing).
- **Draft assistance panels:** Rewrite, Translate and Suggest reply show progress,
  Cancel, Keep original and Replace text, Replace selection or Use reply, per
  [Draft assistance](docs/draft-assistance.md#behavior) and
  [Draft translation](docs/message-translation.md#behavior). In a Reply or Reply
  All Draft, the [Response Assistance](docs/domain/assistance.md) chooser offers
  three concise directions and one full contextual reply; each opens an editable
  preview with a read-only, source-linked check of addressed and unresolved
  questions.
- **Catch Up:** received bubbles show the avatar, sender, a muted subject, the
  summary or preview (up to three lines), time, unread dot and attachment icon.
  Sent bubbles are right-aligned in the accent fill. Also: the collapsed category
  bubble ("12 newsletters"), the unread divider, day separators and the List/Chat
  Inbox View Toggle in the Inbox header. The list is default; the timeline is
  newest-at-bottom, per the [Catch Up requirements](docs/catch-up.md#behavior).
  Quick reply uses a bottom composer bar with
  a quote/recipient chip. Long-press offers Reply and Open Thread for the pressed
  message, then Archive, Delete and Mark Unread labelled as acting on the whole
  Thread. Quoted history is collapsed and expandable.
  [Background-summary states](docs/catch-up.md#summaries) show a preview with
  Summary coming soon while pending, or a preview alone when assistance is disabled
  or unavailable.
- **Settings Row:** title, optional subtitle and icon, and one trailing control
  (switch, pop-up, value, button or disclosure). The switch track uses the accent
  fill when on and `fill/track` when off.
- **Icons:** SF Symbols only, regular weight, tinted with a color token. Never
  sparkle or "AI" iconography.

## Do's and Don'ts

- **Do** use cinnabar only for the On device seal and the Welcome "Continue"
  action. **Don't** use it on routine or destructive actions; it sits too close
  to system red.
- **Do** mark summaries, incoming translations and unaccepted assistance
  previews and suggestions with the On device marker. **Don't** keep the marker
  on accepted Draft content.
- **Do** pair every Category icon and color with its text label. **Don't**
  communicate meaning by color alone.
- **Do** design Light and Dark explicitly, and check AA contrast in both.
  **Don't** invert one mode to get the other.
- **Do** keep glass on the navigation layer. **Don't** put glass on message
  content, cards or the compose format bar.
- **Do** keep hit targets at 28pt on the Mac and 44pt on iPhone, and test layouts
  with German strings.
- **Don't** generate initials avatars or add hover actions in message list rows.
