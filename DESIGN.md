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
  accent-focus-ring: 'rgba(58, 61, 68, 0.32)'
  accent-focus-ring-dark: 'rgba(106, 110, 120, 0.28)'
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
  brand-well: 'rgba(255, 255, 255, 0.08)'
  brand-well-border: 'rgba(255, 255, 255, 0.16)'
  profile-blue: '#0A58CA'
  profile-blue-dark: '#3B6FD6'
  profile-indigo: '#3634A3'
  profile-indigo-dark: '#5E5CE6'
  profile-purple: '#8944AB'
  profile-purple-dark: '#9558BB'
  profile-pink: '#C2185B'
  profile-pink-dark: '#D6336C'
  profile-teal: '#0E7490'
  profile-teal-dark: '#117C97'
  profile-green: '#237A3A'
  profile-green-dark: '#2A8443'
  profile-brown: '#7A5C3E'
  profile-brown-dark: '#8C6A4A'
  apple-button: '#000000'
  apple-button-dark: '#FFFFFF'
  apple-on-button: '#FFFFFF'
  apple-on-button-dark: '#000000'
  text-primary: 'rgba(0, 0, 0, 0.85)'
  text-primary-dark: 'rgba(255, 255, 255, 0.85)'
  text-secondary: '#4F4F54'
  text-secondary-dark: '#B0B0B5'
  surface-content: '#FFFFFF'
  surface-content-dark: '#1E1E1E'
  surface-sidebar: '#F3F2F5'
  surface-sidebar-dark: '#2A2A2C'
  surface-panel: '#F8F8F8'
  surface-panel-dark: '#1A1A1A'
  material-sidebar-backing: 'transparent'
  material-sidebar-backing-dark: 'rgba(42, 42, 44, 0.92)'
  material-glass-tint: '#C6C6C6'
  material-glass-tint-dark: '#3B3B3B'
  surface-bubble: '#F1F1F4'
  surface-bubble-dark: '#2C2C2E'
  fill-quiet: 'rgba(0, 0, 0, 0.05)'
  fill-quiet-dark: 'rgba(255, 255, 255, 0.06)'
  fill-control: 'rgba(0, 0, 0, 0.08)'
  fill-control-dark: 'rgba(255, 255, 255, 0.07)'
  fill-track: 'rgba(0, 0, 0, 0.09)'
  fill-track-dark: 'rgba(255, 255, 255, 0.16)'
  separator: 'rgba(0, 0, 0, 0.1)'
  separator-dark: 'rgba(255, 255, 255, 0.1)'
  scrim-touch: 'rgba(0, 0, 0, 0.22)'
  scrim-touch-dark: 'rgba(0, 0, 0, 0.4)'
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
  settings-detail: '16.923076629638672px'
  format-panel: '34px'
  touch-card: '18px'
  badge-mac: '4px'
  badge-touch: '8px'
  brand-panel: '24px'
  ipad-sheet: '29.095px'
  profile-switcher: '14px'
  close-question: '36px'
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
type, spacing and radius tokens from `packages/mail-core/src/theme.ts`.

The visual reference for screens and components is the Figma file
[Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T).
Its `Unwired` variable collection holds every color token below in Light and
Dark modes. Tokens with a `-dark` suffix are the Dark value of the token
without the suffix; a token without a `-dark` sibling is the same in both modes.
Dimensions in the frontmatter use `px` because the DESIGN.md format requires CSS
units. The Figma frames are drawn at 1×, so 1px equals 1pt on Apple platforms.
Component recipes and dimensions below describe design intent and supported
customization; they do not require rebuilding system controls or overriding
their intrinsic metrics.

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
  bar, menus, sheets and toasts. Content surfaces stay opaque.
- One accent, used sparingly; meaning is never carried by color alone.
- Light and Dark are designed as separate modes, not an inversion.

## Colors

Graphite neutrals with a single warm seal.

| Role              | Token                      | Light         | Dark          | Use                                                            |
| ----------------- | -------------------------- | ------------- | ------------- | -------------------------------------------------------------- |
| Accent fill       | `accent/fill`              | `#3A3D44`     | `#6A6E78`     | Selected message row, primary button, unread dot, sent bubble  |
| On accent         | `accent/on-fill`           | `#FFFFFF`     | `#FFFFFF`     | Text and icons on the accent fill                              |
| Accent ink        | `accent/ink`               | `#3A3D44`     | `#C8CBD2`     | Links, tinted sidebar icons, New Message                       |
| Subtle selection  | `accent/selection-subtle`  | `#3A3D44` 12% | `#C8CBD2` 16% | Selected sidebar item, pressed controls                        |
| Focus ring        | `accent/focus-ring`        | `#3A3D44` 32% | `#6A6E78` 28% | iPad Command Palette outline around the focused query          |
| On device ink     | `on-device/ink`            | `#A3321F`     | `#FF9E88`     | The cinnabar seal: On device marker text and icon              |
| On device surface | `on-device/surface`        | `#FBEEEA`     | `#3A2420`     | Summary card and Mail Assistance surfaces                      |
| Brand deep        | `brand/deep`               | `#15171B`     | `#15171B`     | Welcome, Recovery Key                                          |
| On brand deep     | `brand/on-deep`            | `#FFFFFF`     | `#FFFFFF`     | Text and icons on brand deep                                   |
| Brand seal        | `brand/seal`               | `#C2412A`     | `#C2412A`     | Welcome "Continue" only                                        |
| On brand seal     | `brand/on-seal`            | `#FFFFFF`     | `#FFFFFF`     | Text and icons on brand seal                                   |
| Monogram          | `brand/monogram`           | `#15171B`     | `#6A6E78`     | Account monograms; a Mail Profile in Graphite                  |
| Brand well        | `brand/well`               | white 8%      | white 8%      | iPhone Recovery Key's well on brand deep                       |
| Brand well border | `brand/well-border`        | white 16%     | white 16%     | The Recovery Key well's outline                                |
| Profile Blue      | `profile/blue`             | `#0A58CA`     | `#3B6FD6`     | A Mail Profile monogram in this Color                          |
| Profile Indigo    | `profile/indigo`           | `#3634A3`     | `#5E5CE6`     | A Mail Profile monogram in this Color                          |
| Profile Purple    | `profile/purple`           | `#8944AB`     | `#9558BB`     | A Mail Profile monogram in this Color                          |
| Profile Pink      | `profile/pink`             | `#C2185B`     | `#D6336C`     | A Mail Profile monogram in this Color                          |
| Profile Teal      | `profile/teal`             | `#0E7490`     | `#117C97`     | A Mail Profile monogram in this Color                          |
| Profile Green     | `profile/green`            | `#237A3A`     | `#2A8443`     | A Mail Profile monogram in this Color                          |
| Profile Brown     | `profile/brown`            | `#7A5C3E`     | `#8C6A4A`     | A Mail Profile monogram in this Color                          |
| Apple button      | `apple/button`             | `#000000`     | `#FFFFFF`     | Sign in with Apple only, per Apple's button styles             |
| On Apple button   | `apple/on-button`          | `#FFFFFF`     | `#000000`     | Text and the Apple logo on the Apple button                    |
| Primary text      | `text/primary`             | black 85%     | white 85%     | Mirrors macOS Labels/Primary                                   |
| Secondary text    | `text/secondary`           | `#4F4F54`     | `#B0B0B5`     | Previews, timestamps, captions, section headers                |
| Content surface   | `surface/content`          | `#FFFFFF`     | `#1E1E1E`     | Message list and reading pane                                  |
| Sidebar surface   | `surface/sidebar`          | `#F3F2F5`     | `#2A2A2C`     | Opaque stand-in for the sidebar material                       |
| Panel surface     | `surface/panel`            | `#F8F8F8`     | `#1A1A1A`     | iPad floating sidebar panels, as the frames' glass reads       |
| Sidebar backing   | `material/sidebar-backing` | transparent   | `#2A2A2C` 92% | Mac sidebars only, between the glass and its text              |
| Glass tint        | `material/glass-tint`      | `#C6C6C6`     | `#3B3B3B`     | iPhone and iPad Liquid Glass tint; over content reads as panel |
| Bubble surface    | `surface/bubble`           | `#F1F1F4`     | `#2C2C2E`     | Received Catch Up bubbles                                      |
| Quiet fill        | `fill/quiet`               | black 5%      | white 6%      | Secondary buttons, search field, banners, chips                |
| Control fill      | `fill/control`             | black 8%      | white 7%      | Pop-up button disc within a grouped row                        |
| Track             | `fill/track`               | black 9%      | white 16%     | Off switch track                                               |
| Separator         | `separator`                | black 10%     | white 10%     | Hairlines between rows and panes                               |
| Scrim             | `scrim/touch`              | black 22%     | black 40%     | iPad composer and setup sheet; link alert backdrops on touch   |
| Warning           | `status/warning`           | `#C93400`     | `#FFB340`     | Authorization needed, Pin indicator                            |
| Destructive       | `status/destructive`       | `#D70015`     | `#FF6961`     | Delete Product Account, Delete                                 |

Contrast (WCAG 2.x, AA is 4.5:1 for text and 3:1 for non-text):

| Pairing                            | Light | Dark  |
| ---------------------------------- | ----- | ----- |
| On accent on accent fill           | 10.88 | 5.10  |
| Accent ink on content              | 10.88 | 10.26 |
| Primary text on content            | 15.08 | 12.30 |
| Secondary text on content          | 8.14  | 7.72  |
| Secondary text on sidebar          | 7.30  | 6.63  |
| Secondary text on panel            | 7.67  | 8.06  |
| Secondary text on bubble           | 7.22  | 6.45  |
| On device ink on on device surface | 6.11  | 7.22  |
| Warning on content                 | 5.28  | 9.35  |
| Destructive on content             | 5.38  | 5.91  |
| White on brand deep                | 17.94 | 17.94 |
| White on brand well                | 14.46 | 14.46 |
| White on brand seal                | 5.14  | 5.14  |
| White on monogram                  | 17.94 | 5.10  |
| White on Profile Colors (lowest)   | 5.36  | 4.62  |
| Unread dot (non-text) on content   | 10.88 | 3.27  |

`text/secondary` uses the solid colours approved for #1195. The ratios above use
the opaque surface tokens. In Dark, the Mac Inbox and Settings sidebars lay
`material/sidebar-backing` over their glass, so secondary text keeps 4.5:1
whatever is behind the window
([#1574](https://github.com/unwired-dev/product/issues/1574)). Other labels the
Mac contrast audit flags are tracked in
[#1550](https://github.com/unwired-dev/product/issues/1550).
The macOS Labels/Secondary 50% black reaches only 3.95:1 on white and fails AA for text.
`brand/well` is measured over `brand/deep`. `material/glass-tint` is measured on iOS 27 so the
glass over `surface/content` renders `surface/panel`. The `accent/focus-ring` outline follows the
iPad Palette frames at 1.79:1 (Light) and 1.35:1 (Dark) against `surface/panel`; it is not the
field's only focus indicator, as its caret and the keyboard show focus. The Dark `scrim/touch`
dims `surface/content` to `#121212`, as the iPad Compose frames draw it.

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
- **iPad reader:** the Reading pane recipe at the same 1.15×: Reading Body
  17.25/25.3 and Reading Subject 23/28.75.
- **iPad onboarding:** Welcome, Sign In and the Recovery Key use the same 1.15×:
  Title 1 25.3/29.9, Body 14.95/18.4, and 41.4pt and 46pt buttons with 6.9pt
  corners.
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

- **iPhone account setup:** the approved #907 adaptations use 24pt side margins
  and 10pt content gaps. Scrollable setup content starts 62pt below the top safe
  area and ends 26pt above the bottom safe area. Respect the horizontal safe area
  when the phone rotates.
- **macOS window:** 1280×800 reference, three columns. A floating glass sidebar
  236pt wide inset 8pt, a 340pt message list, and the reading pane. The reading
  pane uses 40pt side padding and starts below the toolbar at 72pt. A 900pt
  narrow window hides the sidebar. Compact layouts collapse the three destinations
  into native navigation, per the [organization requirements](docs/product/organization.md).
- **Sidebar order:** the Mail Profile switcher (full column width) at the top,
  then the primary Unified Mailboxes (Inbox, Snoozed, Pins and Sent),
  secondary Archive, All Mail, Spam and Trash, one collapsible section per
  Mailbox Connection ("Gmail · address") with
  its folders and labels, Saved Searches, and Drafts above Settings pinned to the bottom.
  Synchronization and authorization problems appear beside the affected Mailbox
  Connection. Conditional [Outbox](docs/outbox.md#sending) follows Sent.
  Drafts opens its own screen: the Drafts list, grouped Needs Attention first, with
  the selected Draft editable beside it on Mac and iPad. On iPhone, where Drafts is
  the last row of Mailboxes, selecting a Draft opens the composer as a sheet, per
  the [composer requirements](docs/product/messages-and-delivery.md). Drafts shows a badge only
  when a Draft is offline or needs action, and the main screen's status capsule
  says when Drafts are not synced, as the approved #1269–#1276 frames show.
  Profile scoping follows the [mailbox requirements](docs/product/mailboxes.md#unified-mailboxes).
  iPhone Mailboxes puts Settings in a glass **Account** circle at the header's trailing
  edge and a glass New Message at the bottom trailing corner.
- **Message list header:** mailbox title, a subtitle carrying unread count and
  sync status, and a row of up to five Mail View chips in the order the
  [Mail View requirements](docs/product/organization.md#prototype-mail-views-and-interface-behavior)
  set. On iPhone the title and subtitle sit centered in the system navigation bar,
  whose Back returns to Mailboxes; the bar hides while searching.
- **Search bar:** search and New Message share one floating glass bar at the
  bottom of the window, as the [organization requirements](docs/product/organization.md)
  specify. The search field is 400pt wide and centered, with New Message pinned
  to the trailing edge. On compact layouts it spans the screen width and sits 4pt
  above the bottom safe area, or 12pt above the software keyboard. Rows scroll
  under it behind a 72pt scroll edge fade. On iPhone, Filter, the system search
  field and New Message are items of the system toolbar instead, which UIKit
  places and lifts above the software keyboard: 48pt glass with its bottom edge
  28pt above the screen's bottom and 28pt from each side, a 226pt field and 12pt
  gaps. The Quick Look, Select Messages and Ask About Calendar bars sit on the
  same line. Whether it shows while composing
  follows [Drafts](docs/drafts.md#composing).
- **Command Palette:** on the Mac a glass command input (command symbol,
  "Commands", ⌘K key cap) sits in the window's toolbar row: 36pt at the leading
  end of the Inbox reader's row, beside its glass groups, and 32pt at the trailing
  end of the Settings title row and in the New Message toolbar; open,
  it becomes the focused query with an esc key cap and a 460pt glass panel with
  the menu shadow beneath it.
  Rows are 28pt with an SF Symbol, the name, a disabled reason in secondary text
  or a chevron for a picker, highlighted in the accent fill; section headers read
  Selected Message · subject, App and Go To, and a footer names the keys. iPhone
  and iPad show a panel attached to the top with the input, Cancel and 44pt rows;
  iPad keeps the command input in the Inbox heading and in the reader and
  composer headers too. The [Command Palette guide](docs/command-palette.md) owns
  its entry points, including iPhone's header swipe.
- **Synchronization status:** a bottom-anchored overlay whose states, progress
  and controls follow the
  [sync-status requirements](docs/product/privacy-and-sync.md#local-storage-and-background-freshness).
  The header subtitle does not replace the overlay or connection-local problem
  indicators.
- **Conversation reader:** one flat scroll, subject and Thread summary first,
  then every message expanded newest to oldest with compact sender-and-date headers,
  disclosed recipients, bodies and thin separators, per the
  [reader loading and image requirements](docs/product/messages-and-delivery.md#thread-identity-and-reader-behavior).
  On iPhone the navigation bar's system Back returns to the list and shows the
  mailbox's unread count on a disk beside its chevron, as Mail does; the subject
  sits on a fixed row beneath the bar.
  Received attachments sit below their message body, with availability and actions
  following the [received-attachment contract](docs/gmail-inbox.md#received-attachments).
- **Toolbar:** one fixed reader toolbar of glass button groups over the reading
  pane. On iPhone its 52pt glass groups and New Message sit 2pt above the bottom
  safe area, and the reading pane runs to the screen's bottom edge beneath them.
  On Mac and iPad it holds Archive, Delete, Move, Reply, Reply All, Forward, Pin,
  Snooze and More; on iPhone Archive, Move and Reply. More holds Mark as Unread,
  Mute Thread and Move to Spam, and the multi-select Category control sits in
  the reader header;
  the [conversation reader requirements](docs/product/messages-and-delivery.md#thread-identity-and-reader-behavior)
  and [Thread Snooze requirements](docs/product/organization.md#snooze-and-follow-up-notes)
  set what each targets.
- **Compose:** the
  [composer presentation requirements](docs/product/messages-and-delivery.md#prototype-composer-presentation)
  and [Drafts](docs/drafts.md#composing) own its states, Expand, Close, Discard,
  interactivity beside it and save behavior.
  On the Mac it opens as a bottom-anchored overlay docked across the reading
  pane's full width, as the inline composer frame shows, at 70% of the available
  height, clamped from 420 to 720pt. On regular-width iPad a reply or forward
  docks across the reading column's lower two thirds, and a new message opens as
  a card centred on the window, at most 874pt wide. Expand covers the app window on iPad and moves the Draft into
  its own New Message window on the Mac
  ([38 · #1058](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=528-66002)).
  Compact
  layouts present the composer as a sheet. Order: body, attachments,
  Subject, To, then Cc and Bcc, which a trailing "Cc/Bcc" control on the To
  field reveals together. The sender is a From pop-up beside Send. The Send
  button's menu, a long press on iPhone and iPad and a right click on the Mac,
  lists Remind Me to Send… after Send Later; no composer carries a reminder bell.
  The Mac New Message window has no composer header or bottom row: its toolbar
  row holds the window controls, the "New Message" title, the Command Input, the
  From pop-up, the Compose actions overflow and Send.
  In the approved compose design ([iPhone](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=279-19140),
  [iPad](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=295-50811),
  [Mac](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=297-46535)),
  which the Tiptap evaluation editor follows and the regular composer adopts in
  [#991](https://github.com/unwired-dev/product/issues/991), iPad also uses the glass
  close cross, and Delete Draft and Save Draft grow out of Close on iPhone and
  iPad; the Mac asks in an alert sheet. iPhone moves the format bar into a floating Liquid Glass
  pill (Aa and paperclip) with a separate Writing tools button above the keyboard;
  Aa replaces the keyboard with the glass Format panel.
- **Settings:** the Mac reference is a 900×732 independent window, opened with
  `Command-,`, with a glass sidebar grouped as Accounts, Mail, Composing,
  Automation and Application, and grouped forms on the right. iPad uses an in-app
  two-column workspace whose sidebar starts with a 44pt glass back button that
  returns to mail; iPhone pushes one column into the existing navigation
  stack. Detail failures follow the
  [Settings requirements](docs/product/organization.md#prototype-mail-views-and-interface-behavior).
- **Modal placement:** alerts and sheets are centred in the Mac window and on the
  iPad screen. iPhone alerts are centred, and partial-height sheets attach to the
  screen edges. A backdrop covers the whole window or screen. Popovers have no
  arrow.
- **Dates and times:** the system formatter writes them in the interface
  language's conventions, and one language never mixes formats. The English
  reference frames write `13 Oct`, `Tue 13 Oct, 8:00` and `Today, 18:00`.
- **Spacing scale:** 4, 8, 12, 16, 20pt. Hit targets are at least 28pt on the Mac
  and 44pt on iPhone.

## Elevation & Depth

Depth comes from Apple's Liquid Glass and opaque layering, not from shadows on
content.

- Liquid Glass is reserved for the navigation layer: sidebar, toolbar groups,
  search bar, menus, popovers, sheets and toasts. Use the macOS 27 and iOS 27 kit
  material ("Liquid Glass - Medium") in its Light or Dark variant. On iPhone
  and iPad, toolbar control groups use interactive system glass with their
  controls inside the material and no opaque backing fill; menus, sheets and
  structural surfaces keep passive material.
- Small glass controls (48pt or less) use a soft shadow: 8pt blur, 2pt down, 8%
  black in Light and 30% in Dark. Large glass (sidebar) uses 16pt blur, 4pt
  down. Menus and sheets keep a deeper 24pt shadow so they read as floating.
  A toast keeps the glass material's own shadow.
- Content rows are transparent so the list surface and edge effects show
  through. Never stack glass on glass.
- Where floating chrome overlaps content, use a scroll edge fade instead of a
  divider.

## Shapes

- Controls 6pt, message rows 7pt, cards and banners 10pt, windows 16pt.
- iPhone Settings root groups and account cards use the 22pt inset-group token.
  Settings detail groups use `radius.settingsDetail`, 16.923076629638672pt,
  matching their Light and Dark reference frames. Mac and iPad keep 10pt groups.
- iPhone sheets have 34pt top corners. Partial-height sheets sit flush with the
  screen's bottom edge.
- iPad popovers, such as Filters, are system popovers and keep the iOS corner
  radius. They are drawn without an arrow.
- iPad Sign In's deep brand panel uses `radius.brandPanel`, 24pt, and the iPad's
  centred setup sheet, as Add a Mailbox draws it, `radius.ipadSheet`, 29.095pt.
  iPhone's Profile Switcher above the Mailboxes groups uses `radius.profileSwitcher`,
  14pt.
- Pills and chips are fully rounded (14pt at 28pt tall). Catch Up bubbles are
  20pt. Glass groups take half their height.
- The iPhone meeting invitation card uses `radius.touchCard`, 18pt; iPad keeps the
  10pt `radius.card`. Its status badge, such as Cancelled, uses `radius.badgeMac`,
  4pt, on Mac and `radius.badgeTouch`, 8pt, on iPhone and iPad.
- The iPhone compose Format panel uses `radius.formatPanel`, 34pt. Its inset
  control groups use 22pt corners and 18pt inset selections.
- The iPhone and iPad composer Close question (Delete Draft / Save Draft) is a
  220pt glass panel with `radius.closeQuestion`, 36pt, 12pt padding and 8pt gaps
  between 48pt `fill/quiet` capsules with centred Body labels.
- Monograms and avatars are circles. A Mail Profile monogram fills the circle
  with its Profile Color (Graphite is `brand/monogram`) and shows its Icon, an SF
  Symbol at regular weight, or its name's first letter in `brand/on-deep`. On Mac
  the glyph scales with the circle: 24pt in Settings with a 10pt symbol or an
  11pt semibold letter, 22pt in the Profile Switcher with 9pt or 10pt, and 20pt
  in the Profile Menu with 8pt or 9pt. On iPhone and iPad the symbol is 40% and
  the semibold letter 45% of the circle, rounded up: 30pt in iPhone Settings, 28pt
  in iPad Settings and in the Profile Switcher, and in the Profile Menu 28pt on
  iPhone and 24pt on iPad.
  Message list rows show a real contact photo
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
  preview. The preview is one line by default; density and preview length follow
  the person's saved preferences. Essential attachment, Pin, Category and source-connection status
  accompany the preview, with Category badges and attachment indicators following
  the saved Inbox presentation preferences; every unified-list Thread identifies its Mailbox Connection,
  per the [list requirements](docs/product/mailboxes.md#unified-list-behavior).
  Unread shows a stronger sender and subject weight and an accent
  dot. On iPhone and iPad, search uses regular sender and subject text with only
  the query's matching words emphasized; unread results retain the dot.
  A hairline separator ends each row, except a selected row and a row directly
  above a date divider.
  Selected is the graphite fill with white text. No generated initials and
  no hover actions; a real contact photo may appear, per the
  [list requirements](docs/product/organization.md#prototype-mail-views-and-interface-behavior).
- **Sidebar Item / Sidebar Section Header:** 28pt items with tinted SF Symbols
  and counts. A selected item uses the subtle selection fill and an emphasized
  label, so selection does not rely on the low-contrast fill alone. Section
  headers collapse with a trailing disclosure chevron; the Settings sidebar
  turns that off.
- **Profile Switcher / Profile Menu:** monogram, Mail Profile name and chevron.
  The menu lists Mail Profiles with their Mailbox Connections, unread counts and
  a checkmark, then New Mail Profile… and Manage Mail Profiles…, which opens
  [Settings › Mail Profiles](https://github.com/unwired-dev/product/issues/1038). It is the system
  menu, so each Profile's connections and unread count share its subtitle, the
  checkmark leads and the Profile's monogram is the item image. The Default Profile is named Primary
  Profile.
- **Mail View Chip (Figma: Category Chip):** the `category-chip` token recipes
  style each header chip with an icon, label and unread-Thread count badge capped
  at 99+. Selected chips are graphite with an emphasized label; others use the quiet fill.
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
- **Toast / Outbox Row:** a toast is a Liquid Glass capsule with no fill of its
  own, 48pt tall with a 24pt radius, centred with its bottom edge 12pt above the
  search bar: 16pt leading and 20pt trailing padding, an 18pt symbol and the
  message in 15/20 semibold `text/primary`, and at most one action in 17/22
  semibold, `accent/ink` in Light and `text/primary` in Dark. On iPhone a
  message that does not fit one line wraps to a 64pt two-line toast. The Undo
  Send toast offers Undo during the Undo Send Window. Window preferences follow the
  [delivery requirements](docs/product/messages-and-delivery.md#authored-content-and-delivery-attempts).
  [Outbox rows](docs/outbox.md#sending) show waiting, refusal and unknown-outcome
  states with recovery controls after the toast ends. Its refusal state follows
  the [Outbox delivery rules](docs/outbox.md#delivery-rules).
- **Compose:** Compose Format Bar (text style, bold, italic, underline,
  strikethrough, inline code, lists, link, the Writing tools sparkles menu with
  Rewrite, Suggest reply, Proofread, Break into Paragraphs, Translate, Expand
  Text, Shorten Text, the tone tools and Generate a Draft…, whose prompt
  follows the Generate a Draft frames: a popover on Mac and iPad, a sheet on
  iPhone, without the prompt-history control, in the
  [grouped order](docs/draft-assistance.md#behavior)), the file controls and
  Templates; no glass on iPad and Mac),
  Compose Field (Filled, Placeholder, Recipients, Suggested), Attachment Chip,
  From Pop-up. On iPhone a Compose Field is 44pt tall. A suggested subject carries the On device marker until explicit
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
  attachments. Keep reasons for blocked Send visible. No client shows save status;
  saving follows [Draft saving and asset availability](docs/drafts.md#saving).
- **Compose recipients and sender:** Recipient Suggestions appear beneath the
  active To/Cc/Bcc field; recipients are removable tokens. Entry, validation and
  From follow the
  [recipient and sender requirements](docs/product/messages-and-delivery.md#sending-identities-and-recipient-entry)
  and [Draft sender contract](docs/drafts.md#composing).
- **Draft assistance panels:** Rewrite, Translate and Suggest reply show progress,
  Cancel, Keep original and Replace text, Replace selection or Use reply, per
  [Draft assistance](docs/draft-assistance.md#behavior) and
  [Draft translation](docs/message-translation.md#behavior). The
  [Response Assistance](docs/domain/assistance.md) chooser's options and previews
  follow the
  [assistance requirements](docs/product/assistance.md#assistance-inputs-previews-and-acceptance).
- **Catch Up:** received bubbles show the avatar, sender, a muted subject, the
  summary or preview (up to three lines), time, unread dot and attachment icon.
  Sent bubbles are right-aligned in the accent fill. Also: the collapsed category
  bubble ("12 newsletters"), the unread divider, day separators and the List/Chat
  Inbox View Toggle in the Inbox header. Order, quick reply, long-press actions
  and quoted history follow the [Catch Up requirements](docs/catch-up.md#behavior).
  Quick reply uses a bottom composer bar with a quote/recipient chip.
  [Background-summary states](docs/catch-up.md#summaries) show a preview with
  Summary coming soon while pending, or a preview alone when assistance is disabled
  or unavailable.
- **Settings Row:** title, optional subtitle and icon, and one trailing control
  (switch, pop-up, value, button or disclosure). The switch track uses the accent
  fill when on and `fill/track` when off.
- **Icons:** SF Symbols only, regular weight, tinted with a color token. The
  approved compose Writing tools control uses `sparkles`; other controls never use
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
  content, cards or the iPad and Mac compose format bar; toasts, the iPhone
  compose pill, Writing tools button and Format panel float above content as
  controls.
- **Do** keep hit targets at 28pt on the Mac and 44pt on iPhone, and test layouts
  with German strings.
- **Don't** generate initials avatars or add hover actions in message list rows.

## Known frame differences

Everywhere else the frames win over this document, as the
[frames rule](AGENTS.md#design) says.

One frame size differs from the device on purpose. Here the system wins:

- **iPad Settings height:** frames whose Settings sidebar lists more rows than
  the screen holds are drawn 912pt tall to show the whole list. On the device
  the sidebar scrolls.

These frames show a decision the app has not built yet. The frame wins, and the
app follows under the issue named:

- **Edit Favorites:** the sidebar's Edit mode, and **Edit** beside Account in the
  iPhone Mailboxes frames, wait for #2106.
- **Message list header:** the iPhone frames' List/Chat toggle beside the title
  waits for #810. Their **…** menu waits for an issue that names what it offers.
- **iPhone composer:** the frames draw the composer as a sheet, as
  [ADR 0057](docs/adr/0057-present-composing-inside-the-mail-shell.md) now
  decides. The app pushes it onto the navigation stack until #2113.
- **Send menu:** on the Mac it lists Send and Remind Me to Send… (#2123); on
  iPhone and iPad it lists Remind Me to Send… (#2136). Send and Archive, Send
  Now and Send Later wait for #1673, #1674 and #1262.
- **Reminder menu:** Choose Date and Time… waits for a frame of what it opens
  (#658). The Mac offers This Evening at 20:00 and Tomorrow Morning at 9:00, as
  M3 draws them; iPhone and iPad offer the times their frames draw (#2136). The
  Mac menu shows each time on the item's second line and the note
  as a dimmed item on one line, as AppKit draws them, where M3 draws the time
  trailing and the note wrapped in small type. Until #658 schedules
  notifications, no device reminds the person yet.
- **Mail Views:** the row of Mail View chips in the Inbox list waits for #2131.
- **Mac Settings › Appearance:** the page offers Light, Dark and System (#2153).
  The frame's Message list group, with its Preview lines pop-up, waits for a
  later slice of #1727.
- **Reader More menu:** Move to Spam waits for #2132.
- **Compact iPad window:** the Command input in the reader's navigation bar and
  on the composer's From row waits for #2133.
- **iPhone composer body:** the body fills the sheet and the fields are below
  the fold, which waits for #2119.
- **Slash Command Menu:** the menu and Show Formatting Toolbar wait for #2117
  and #2118.
- **Toasts:** the frames draw glass toasts. The app draws a deep graphite toast
  until #2104.
- **Command Palette key cap:** the frames and the Layout section show ⌘K, as
  [ADR 0077](docs/adr/0077-remove-friction-that-privacy-does-not-require.md)
  decides. The app opens the palette with ⌘P until #1993.
- **Outbox:** the frames draw the conditional Outbox as a sidebar row after Sent.
  The app lists its rows at the top of the Inbox column until #2101.
- **Reader date:** the frames write `Today, 8:12`. The app writes a full UTC date
  until #2102.
- **Trusted Devices:** the rows' device symbol, Current Device, last activity and
  disclosure chevron wait for #2107.
- **Recovery Key:** Copy, Save to Files, Print… and Save to Passwords… wait for
  #2108.
