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
rounded:
  control: '6px'
  row: '7px'
  card: '10px'
  bubble: '20px'
  window: '16px'
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
dimensions describe the Figma reference mockups. Adopting this palette in app
theme code is a separate follow-up.

The source of truth for screens and components is the Figma file
[Unwired Mail — Design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T).
Its `Unwired` variable collection holds every color token below in Light and
Dark modes. Tokens with a `-dark` suffix are the Dark value of the token
without the suffix; a token without a `-dark` sibling is the same in both modes.

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
the mail. Cinnabar is the seal: it marks Mail Assistance output (summaries,
translation, rewrites) as made on this device, and the one brand action on
Welcome.

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
| Primary text      | `text/primary`            | black 85%     | white 85%     | Mirrors macOS Labels/Primary                                  |
| Secondary text    | `text/secondary`          | black 60%     | white 55%     | Previews, timestamps, captions                                |
| Content surface   | `surface/content`         | `#FFFFFF`     | `#1E1E1E`     | Message list and reading pane                                 |
| Sidebar surface   | `surface/sidebar`         | `#F3F2F5`     | `#2A2A2C`     | Opaque stand-in for the sidebar material                      |
| Bubble surface    | `surface/bubble`          | `#F1F1F4`     | `#2C2C2E`     | Received Catch Up bubbles                                     |
| Quiet fill        | `fill/quiet`              | black 5%      | white 6%      | Secondary buttons, search field, banners, chips               |
| Track             | `fill/track`              | black 9%      | white 16%     | Off switch track                                              |
| Separator         | `separator`               | black 10%     | white 10%     | Hairlines between rows and panes                              |
| Warning           | `status/warning`          | `#C93400`     | `#FFB340`     | Authorization needed, flags                                   |
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

SF Pro throughout, using Apple's text styles; no custom typeface. The Figma file
keeps local copies of the macOS 27 and iOS 27 kit ramps (`macOS/…` and `iOS/…`
styles) so the file stays editable.

- **macOS:** Body 13/16 for lists, sidebars and controls; Body Emphasized 13/16
  semibold for unread senders and primary buttons; Subheadline 11/14 for
  timestamps and section headers; Title 3 Emphasized 15/20 for list and page
  titles.
- **Reading pane:** Reading Body 15/22 for message text (larger than Mac Body for
  long-form reading) and Reading Subject 20/25 bold for the Thread subject.
- **iOS:** Large Title 34/41 bold, Headline 17/22 semibold, Body 17/22,
  Subheadline 15/20 for bubble text, Footnote 13/18 for subjects and times.
- Emphasis comes from weight, not size. Never set long text in bold.

## Layout

- **macOS window:** 1280×800 reference, three columns. A floating glass sidebar
  236pt wide inset 8pt, a 340pt message list, and the reading pane. The reading
  pane uses 40pt side padding and starts below the toolbar at 72pt. A 900pt
  narrow window hides the sidebar.
- **Sidebar order:** the Mail Profile switcher (full column width) at the top,
  then Favorites, one collapsible section per Mailbox Connection
  ("Gmail · address"), Saved Searches, and a Settings item pinned to the bottom.
- **Message list header:** mailbox title, a subtitle carrying unread count and
  sync status, and a horizontally scrolling Category chip row.
- **Search bar:** a floating glass bar centered at the bottom of the window. The
  search field is 400pt wide, with New Message pinned to the trailing edge. On
  iPhone it spans the screen width. Rows scroll under it behind a 72pt scroll
  edge fade. It hides while the inline composer is open.
- **Toolbar:** glass button groups over the reading pane: Archive, Delete, Move;
  Reply, Reply All, Forward; Flag, Snooze.
- **Compose:** a separate 760×640 window, or an inline composer docked in the
  bottom 60% of the reading pane height. Order: body, attachments, Subject, To,
  Cc. The sender is a From pop-up beside Send.
- **Settings:** a 900×720 window with a glass sidebar grouped as Accounts, Mail,
  Composing, Automation and Application, and grouped forms on the right.
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
- Monograms and avatars are circles. Avatars appear only in Catch Up bubbles and
  the Thread view, as neutral initials, never photos.

## Components

The Figma Components page holds each component with its variants and a
description. Apple kit components are used wherever they fit (window controls,
form accessories, keyboards, status bar).

- **Button:** Primary (graphite), Secondary (quiet fill), Brand (cinnabar, Welcome
  "Continue" only). 28pt tall.
- **Message Row:** Mail.app-style hierarchy: sender and time, subject, two-line
  preview. Unread shows a bold sender and an accent dot; selected is the
  graphite fill with white text. No avatars and no hover actions.
- **Sidebar Item / Sidebar Section Header:** 28pt items with tinted SF Symbols
  and counts. Section headers collapse with a trailing disclosure chevron; the
  Settings sidebar turns that off.
- **Profile Switcher / Profile Menu:** monogram, Mail Profile name and chevron.
  The menu lists Mail Profiles with their Mailbox Connections, unread counts and
  a checkmark, then New Mail Profile… and Manage Mail Profiles….
- **Category Chip:** icon plus label, always both. The selected chip is graphite;
  others use the quiet fill with an unread dot. System Categories: People,
  Orders, Newsletters & Promotions, Invites, Flights.
- **On Device Marker / Summary Card:** the cinnabar lock with "On device" marks
  every piece of Mail Assistance output. The Summary card sits at the top of a
  Thread; while summarizing it shows quiet placeholder lines.
- **Banners:** Translation, Remote Content and Authorization Needed use the quiet
  fill and 10pt radius. Actions stack under the message so long localized
  strings stay readable in the 340pt list.
- **Undo Send Toast:** deep graphite, centered above the search bar, with an Undo
  action, for the undo window.
- **Compose:** Compose Format Bar (text style, bold, italic, underline,
  strikethrough, lists, link, Rewrite, attach file, attach photo; no glass),
  Compose Field (Filled, Placeholder, Recipients, Suggested), Attachment Chip,
  From Pop-up. A suggested subject is Mail Assistance output and carries the On
  device marker.
- **Catch Up:** received bubbles show the avatar, sender, a muted subject, the
  summary or preview (up to three lines), time, unread dot and attachment icon.
  Sent bubbles are right-aligned in the accent fill. Also: the collapsed Category
  bubble ("12 newsletters"), the unread divider, day separators and the List/Chat
  Inbox View Toggle.
- **Settings Row:** title, optional subtitle and icon, and one trailing control
  (switch, pop-up, value, button or disclosure). The switch track uses the accent
  fill when on and `fill/track` when off.
- **Icons:** SF Symbols only, regular weight, tinted with a color token. Never
  sparkle or "AI" iconography.

## Do's and Don'ts

- **Do** use cinnabar only for the On device seal and the Welcome "Continue"
  action. **Don't** use it on routine or destructive actions; it sits too close
  to system red.
- **Do** mark every summary, translation, rewrite and suggested subject with the
  On device marker.
- **Do** pair every Category icon and color with its text label. **Don't**
  communicate meaning by color alone.
- **Do** design Light and Dark explicitly, and check AA contrast in both.
  **Don't** invert one mode to get the other.
- **Do** keep glass on the navigation layer. **Don't** put glass on message
  content, cards or the compose format bar.
- **Do** keep hit targets at 28pt on the Mac and 44pt on iPhone, and test layouts
  with German strings.
- **Don't** add avatars or hover actions to message list rows.
