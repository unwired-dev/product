# Gmail Inbox synchronization

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/gmail-inbox.md).

[#604](https://github.com/unwired-dev/product/issues/604) shows a connected
Gmail mailbox's Inbox on iPhone, iPad and Mac, and
[#606](https://github.com/unwired-dev/product/issues/606) adds more
[Gmail mailboxes](#gmail-mailboxes) with a unified Inbox. After
[registration](google-registration.md) connects a mailbox and account setup needs
nothing more from the person, launch opens the Inbox. The **Account** button opens the account page, and **Open Inbox**
returns. The account page opens instead while a Recovery Key needs confirming or
entering, a device approval is waiting on either side, the mailbox is not yet
saved to private sync, or a sign-out or deletion is unfinished.

An explicit choice of **Account** stays through status updates. Choosing **Open
Inbox** can leave already-pending setup for later, but different pending setup
that appears afterward, including a renewed device approval code, opens the
account page again. Sign-out, pending removal,
loss of mailbox access or a different Product Account forgets the earlier choice.

## Gmail mailboxes

Each Gmail account the person authorizes is one **Mailbox Connection** of the
Product Account, with its own Gmail credential, verification, encrypted cache,
waiting changes and synchronization. Adding a mailbox never adds a Product Sign-In.

- **Adding.** The account page's **Gmail mailboxes** section lists every connection
  with its state and offers **Add another Gmail mailbox**, which asks Google for an
  account and explicit Gmail consent. Choosing a Google account that is already
  connected authorizes that connection again instead of adding a second one; the
  Google account, not the address, identifies it. A cancelled or refused addition
  leaves every connection as it was.
- **Unified Inbox.** With more than one mailbox, the Inbox shows **All inboxes**,
  newest first. Messages received at the same moment keep the order the mailboxes
  were added, then Gmail's message ID, so rows never reorder between updates. Every
  row, and the reader, names its mailbox (`In alex@example.com`), and VoiceOver
  reads it with the row. Choosing a mailbox's address above the list shows only that
  mailbox; **All inboxes** returns. Each window chooses on its own. A removed
  mailbox's view falls back to **All inboxes**.
- **Separate states.** Each mailbox reports its own **Checking Gmail…**, **Gmail
  could not be reached** and storage notices, waiting changes, **Undo**, and
  **Retry change** or **Discard change**, prefixed with its address when there are
  several. **Allow Gmail access** authorizes only that mailbox, with the same Google
  account. When a verification finds one mailbox's grant refused, that mailbox shows
  **Gmail needs your permission again** and **Allow Gmail access for** its address,
  and its saved mail stays closed, while every other mailbox stays open and usable.
  Each verification checks a refused mailbox again. Only when every mailbox needs
  Gmail does the account page open with **Connect your Gmail**.
- **Removing.** **Remove** asks first and explains that the mailbox's Gmail access
  and the mail saved for it, including changes still waiting for Gmail, leave this
  device and the person's other devices, while mail stays in Gmail. Removal is
  **Remove Mailbox Connection Everywhere**: it invalidates the mailbox's running work,
  clears its credential, deletes its cache and bodies, and marks its
  [synchronized descriptor](private-product-sync.md#keys-and-envelopes) removed.
  Other devices purge that mailbox on their next synchronization. Nothing is sent to
  Gmail. Failed local cleanup and unfinished private-sync removal stay visible as
  mailbox changes waiting to finish, and retry without reopening the removed mailbox.

Gmail message IDs are unique only within a mailbox, so the Inbox addresses a
message by its mailbox and ID. Only one recent-body prefetch lane runs per mailbox;
all mailboxes share the [four concurrent body loads](#recent-body-prefetch), and
prefetch in any mailbox yields to an explicit open in any other.

## Searching saved mail

[#608](https://github.com/unwired-dev/product/issues/608) searches the Inbox mail
saved on this device. The field above the list, **Search senders and subjects**,
matches the **Durable Message Metadata** already in each mailbox's encrypted cache:
the sender's name and address and the subject. Every word of the query must appear
in one of them, ignoring case and accents, so `cafe oliver` finds Oliver's
`Café on Saturday`. Search asks Gmail nothing and needs no network, so it also works
in a [Saved Gmail Inbox](#mailbox-sync-status) during an outage; no search index
leaves the device or reaches Convex. It covers the newest 200 Inbox messages each
mailbox keeps; older mail stays in Gmail, and [searching Gmail online](#searching-gmail-online)
reaches it.

- **Scope.** Search follows the [chosen view](#gmail-mailboxes): **All inboxes**
  searches every mailbox, newest first in the unified order, and a mailbox's address
  searches only its own mail. A removed mailbox's mail leaves the results at once,
  as it leaves the Inbox.
- **Results.** Each result is an ordinary Inbox row that opens in the reader. While
  searching, each row also says whether its body is **Saved on this device**, so it
  opens without Gmail, or **Downloads from Gmail when opened**. Messages that recent-body
  prefetch leaves for on-demand download count as not saved. The answer is checked when the results
  change, when a result is opened or the reader closes, and whenever this device saves or
  prunes a body while the results are shown, such as recent-body prefetch finishing. When nothing matches, the
  list says **No mail saved on this device matches “…”**.
- **Responsiveness.** Typing never waits for the list. Each saved-body answer belongs
  to the query, view and mailboxes it was asked for; a slower answer for an earlier
  search is discarded rather than shown.

## Searching Gmail online

[#609](https://github.com/unwired-dev/product/issues/609) adds Gmail's own full-text
search below the saved results. Typing never asks Gmail; once there is a query,
**Search Gmail for “…”** sends it to Gmail unchanged, with Gmail's search semantics
and operators, for each Gmail mailbox in the [chosen view](#gmail-mailboxes): one
mailbox, or every mailbox under **All inboxes**. The API search excludes spam and trash, including the bodies and mail that left the Inbox.

- **Results.** They appear under **From Gmail**, after the saved results, which stay
  as they were. Each mailbox returns 20 results per page, newest first across
  mailboxes, and **More from Gmail** asks every mailbox with another page for it.
  When nothing matches, the section says **Gmail found no mail matching “…”**.
- **Reading.** A result opens in the reader, read from Gmail with the mailbox's own
  access. A result outside the cached Inbox keeps its metadata and body in memory
  while that mailbox's Inbox is open, without writing them to the encrypted cache.
  A result also listed in the Inbox opens and caches as the Inbox message. A result
  outside the Inbox shows no organizing actions.
- **Failures.** Each mailbox that Gmail could not search says why, naming the mailbox
  when the view holds several, while the other mailboxes' results and the saved
  results stay: no connection, a refused grant, which also offers **Allow Gmail
  access** as a reader would, or another failure. **Search Gmail again** asks every
  mailbox afresh; a failed next page keeps its place, so **More from Gmail** retries it.
- **Stale requests.** An answer belongs to the query and the mailboxes' Inboxes it
  was asked of. Changing the query or view, a removed or changed mailbox, or another
  Product Account leaves it unshown until Gmail is asked again, and a reply for an
  Inbox that closed or locked meanwhile is dropped. Locking a mailbox also discards
  the view's earlier online rows. A slower reply for an earlier request never
  replaces a later one. The request itself runs to completion; only its answer is
  discarded.

Native code passes the query as one percent-encoded `q` value, encoding `+` as well,
so `from:a+b@example.com` keeps its plus sign.

## Behavior

The Inbox lists **Durable Message Metadata** for Gmail's `INBOX` label: sender,
address, subject, Gmail's snippet, received time, unread state and Gmail's label
IDs. Opening a message shows its body, as described in
[Reading messages](#reading-messages). The detail view also shows the message's
own labels and the [organizing actions](#organizing-mail).

A first synchronization reads the mailbox's current history ID, then lists the
Inbox newest first, 50 messages per page. Each page is shown as soon as it is
committed, so the newest 50 are usable before the rest arrive (**Initial Mailbox
Availability**). The device keeps the newest 200 Inbox messages; older ones stay
in Gmail. **Historical Metadata Backfill** of the complete mailbox is not part of
this slice.

Later synchronizations read Gmail history from the committed history ID and apply
arrivals, deletions, archiving and read changes. If Gmail no longer has that
history, the Inbox is listed again; the cached messages stay visible meanwhile,
and messages that left the Inbox are removed when the new listing completes.
Synchronization runs when the Inbox opens and whenever the app becomes active;
see [Freshness across app lifecycles](#freshness-across-app-lifecycles) for
background work.

A rejected saved listing token starts a fresh listing. When a full cache loses an
entry, a fresh listing admits the next older Inbox message. Unreadable cache
documents are preserved and reported as unavailable rather than replaced.

Every step commits its messages together with the checkpoint that resumes after
them. An interruption repeats at most the uncommitted step, and changes are
applied by Gmail message ID, so nothing is lost or duplicated. Two windows or
store instances cannot overwrite each other's newer commit; the later one starts
again from the committed cache.

If a foreground account check interrupts synchronization and verifies the same
mailbox again, synchronization starts again from its committed cache, at most
twice. Its saved Inbox stays visible. Repeated interruptions make the Inbox
unavailable until **Try again** or the next activation.

## Organizing mail

[#607](https://github.com/unwired-dev/product/issues/607) organizes Gmail mail with
Gmail's label semantics. These are **Provider Mail Actions** for Gmail only; future
IMAP or Microsoft connections need their own actions rather than pretending to match
Gmail's labels.

| Action                            | Gmail change                                     |
| --------------------------------- | ------------------------------------------------ |
| **Mark as read** / **unread**     | Removes or adds `UNREAD`                         |
| **Star** / **Remove star**        | Adds or removes `STARRED`                        |
| **Archive**                       | Removes `INBOX`                                  |
| **Move to Trash**                 | Adds `TRASH`, removes `INBOX`                    |
| **Report spam**                   | Adds `SPAM`, removes `INBOX`                     |
| A label checkbox under **Labels** | Adds or removes that label                       |
| **Move to** a label               | Adds the label, removes `INBOX`, keeps others    |
| **Undo**                          | Reverses the latest archive, move, trash or spam |

The reader has keyboard-focusable action buttons and label checkboxes with visible
focus rings. After a removal, **Undo** appears in the Inbox. VoiceOver also offers read, star, archive, trash and spam as actions on each
Inbox row, and announces each outcome once, however many Mac windows show it. **Labels** lists the mailbox's own labels, read from Gmail once per
synchronization and kept with the cache. Restoring from Trash or Spam is the
**Undo** of the latest removal; browsing Trash, Spam or a label is not part of
this slice.

A change shows at once with **Saving the change on this device…** until local
storage confirms it. It then becomes a durable **Pending Provider Action** before
Gmail is asked. A current Gmail request may finish before the local save completes;
**Saving** remains visible until the change is durable. Gmail's answer replaces
the pending change. Changes are
sent one at a time, in the order they were made, each by Gmail message ID and only
to the mailbox they were made in. A message that leaves the Inbox, from the reader
or its row, closes the reader and shows **Undo** in the Inbox until the next
organizing action. The Inbox states the outcome of every action, such as
**Starred** or **Marked as read**, so it is announced even when the row does not
show it. A change saved while Gmail is still being checked does not
interrupt that check: the synchronization keeps the newly saved changes and goes on.
A change another window or store instance already settled is not sent again.
One that another store instance is sending stays pending until that attempt ends;
an interrupted attempt can be retried on the next synchronization, including after relaunch.

- **Offline or interrupted:** the change stays saved and is sent on the next
  synchronization, including after relaunch. The Inbox says how many changes wait
  for Gmail while it cannot be reached or needs permission again.
- **Lost response:** synchronization checks Gmail's current labels before another
  attempt. An already-applied change needs no second write. Otherwise the same
  requested labels are retried; repeating an action leaves the same labels.
- **Repeated failure:** automatic synchronization makes at most five dispatch
  attempts per change, with exponential delay and jitter between attempts.
  Unconfirmed changes and later intents stay saved. The status names the action
  and message awaiting confirmation. **Retry change** starts a new
  retry budget; **Discard change** restores Gmail's current state and lets later
  intents continue.
- **Refused:** when the message or label no longer exists in Gmail, the change is
  dropped, the Inbox shows the message as Gmail has it, and an alert names the
  refused change. Later changes still apply. The refusal is saved before Gmail's
  current labels are read, so an interrupted read settles it later without sending
  the refused change again.
- **Changed in Gmail:** label changes made elsewhere arrive through Gmail history.
  A waiting change shows on top of them until Gmail confirms it; Gmail keeps labels
  the change does not name.

While only the saved Inbox opens after a known network outage, nothing can be
saved, so the reader explains that organizing waits until Gmail can be checked.
A change made just before the Inbox learns this is rolled back rather than kept
unsaved. The Inbox names the latest change that could not be saved, reports how
many requests were rolled back when several were still saving, and VoiceOver
announces the outcome, including when the action closed the reader. Reconnect,
then repeat the unsaved changes.
A change still displaying **Saving…** has not been acknowledged durable; locked
or unavailable storage reports a failure. Unsaved changes are forgotten if the
Inbox changes owner. Same-mailbox verification can renew access without dropping
those changes. **Undo** preserves labels the message already had before a move. Reconnecting Gmail keeps the same mailbox; another Google account is
[added](#gmail-mailboxes) as its own mailbox. Removing a mailbox removes its cache,
including its waiting changes, after the account page explains that. A cache written before message labels were kept is listed again once, with its messages visible meanwhile; a message offers organizing actions once its labels are read. Previously saved changes still resume in order, including a change saved before those labels were known.

## Reading messages

[#605](https://github.com/unwired-dev/product/issues/605) requires isolated rich
HTML presentation and recent-body prefetch on iPhone, iPad and Mac. The requirements
below cover the current single-mailbox Inbox with its newest 200 cached metadata
entries. They do not add Sent Mailbox, pins, multiple Profiles or a complete
historical metadata backfill.

Opening a listed message first reads the **Bounded Encrypted Body Cache** on this
device. A valid hit, including after an offline relaunch, contacts nothing and
restores its rich presentation. A miss downloads through the authorized mailbox,
saves the complete body when capacity permits, and shows it. An explicit open and
prefetch of the same message share one load. Opening or prefetching never changes
Gmail's read state.

The reader selects a renderable HTML alternative before plain text, decoded from
the part's charset. Only a complete `charset` parameter outside comments and
other quoted values selects the encoding. Explicit reads stop parsing at a
malformed parameter and use UTF-8 when no complete charset was parsed.
Image-only HTML with an admissible CID reference or a
blocked-image placeholder remains renderable. Every Content-Disposition occurrence
must have a recognized inline token; empty, malformed, attachment and extension
dispositions are excluded from body selection and prefetch. Absent dispositions
remain eligible. Attached files and `message/rfc822` containers are excluded from
body selection. Conflicting repeated Content-Type tokens exclude a part from body
selection and prefetch. Signed and report containers contribute only their first
child to the readable body and inline-image resolution; signature and report-data
children never supply either. The first child may itself contain readable
alternatives and related images, including when the container is nested in mixed
mail. A message nested more than 32 multipart levels deep, or with more than
10,000 parts, is reported as not downloaded instead of being read. A separately served body part is shown and saved only after all bytes
arrive and the decoded byte count matches Gmail's declared size. Interrupted or
incomplete downloads publish no partial cache entry. Retained bodies include
readable text and the original decoded HTML alternative; sanitization changes
only the presentation, never the encrypted source body. The current decoder's
qualified charset coverage is UTF-8 and Latin-1; its UTF-8 fallback for other legacy
charsets remains a compatibility limit, not evidence of correct decoding.

### Isolated rich presentation

Both hosts render only a sanitized, app-generated document in a `WKWebView`
boundary. The Expo host uses UIKit-backed WebKit on iOS and iPadOS 27; the native
React Native macOS host uses AppKit-backed WebKit on macOS 27. Mac Catalyst and
the prototype's older deployment floors do not qualify the replacement Mac host.
The approved WebView dependency must support the following boundary on both hosts.

- Page JavaScript is disabled with
  `WKWebViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false`.
  Message content cannot install scripts or call an application bridge. Layout
  measurement may use only an application-owned script in WebKit's isolated
  client content world; it never enables page JavaScript.
- `WKWebViewConfiguration.websiteDataStore` is non-persistent. No persistent
  cookies, website storage, browser cache or shared authenticated browser session
  is available to the message. Remote requests cannot carry cookies or credentials.
- WebKit makes no network or remote-resource loads. Images reach it only as local
  `data:` values assembled from admitted bytes after sanitization. Fonts, media,
  frames, objects, stylesheets and connection requests cannot load externally.
- The generated document enforces this CSP, or an equivalently restrictive boundary:
  `default-src 'none'; img-src data:; media-src 'none'; style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`.
  Inline styles are safe only after filtering.
- The initial app-owned document loads with no base URL. A message cannot supply a
  `base` element, inherit a sender's origin or resolve relative references against
  a network or filesystem location. Relative references remain non-loading.
- Only the initial app-owned document navigation is allowed. The navigation delegate
  cancels every message-originated navigation, redirect and new-window request.
  A user-activated allowed link goes through the separate confirmation below,
  including links that request another window. Automatic navigation is blocked.
  Link previews cannot make an unconfirmed remote request; disable them on iOS
  and iPadOS and enforce the same behavior on Mac.

These are native configuration requirements, not assumptions about a wrapper's
`incognito` or JavaScript flags. A host that cannot enforce them uses the safe
plain-text fallback. On-device MIME decoding and presentation sanitization belong
in shared TypeScript; native code supplies the platform WebKit boundary.

Both hosts render with `react-native-webview` 13.16.1 under the repository patch
`patches/react-native-webview@13.16.1.patch`. The patch disables page JavaScript
through `allowsContentJavaScript` and reports the laid-out document size. It
measures with an app-owned script in WebKit's isolated client content world after
load; page JavaScript stays disabled. This is the owner-approved measurement
boundary on both hosts. The [architecture companion](architecture/gmail-inbox.md#message-reading)
records the accepted decision. The reader passes `javaScriptEnabled={false}`, `incognito`,
`allowsLinkPreview={false}`, no base URL, and `originWhitelist={['*']}`. With that
origin list, every navigation reaches the reader, which cancels it; otherwise the
wrapper would open unlisted origins itself. The sanitizer parses HTML as a
document with `parse5`.

### Sanitization contract

Sanitization runs on this device before any untrusted HTML reaches WebKit,
including cached HTML and before discovery of resolvable CID image references.
It uses explicit element, attribute, CSS-property and URL allowlists. Parse HTML
as a document; malformed markup cannot escape cleaning. Cancelled preparation
stops without revealing a stale presentation.

The existing reviewed rich-rendering contract admits these passive elements:
`a`, `b`, `blockquote`, `br`, `caption`, `center`, `cite`, `code`, `col`, `colgroup`,
`dd`, `div`, `dl`, `dt`, `em`, `h1` through `h6`, `hr`, `i`, `img`, `li`, `ol`, `p`,
`pre`, `q`, `s`, `small`, `span`, `strike`, `strong`, `sub`, `sup`, `table`, `tbody`,
`td`, `tfoot`, `th`, `thead`, `tr`, `u` and `ul`. Preserve paragraphs, lists,
formatting and table reading order. Active or unsupported elements cannot become
executable output. Remove scripts, event handlers, forms and their controls,
frames, embedded objects, author metadata including refresh, `base`, SVG and
MathML, external stylesheets and author `style` blocks.

The passive attribute boundary is:

| Elements              | Allowed attributes                                                                                          |
| --------------------- | ----------------------------------------------------------------------------------------------------------- |
| All admitted elements | `dir`, `lang`, `title`, filtered `style`; consume `hidden` to exclude hidden content                        |
| `a`                   | Vetted `href`; app-enforced `rel="noreferrer noopener"`                                                     |
| `blockquote`, `q`     | `cite` restricted to `http` and `https`, never fetched                                                      |
| `col`, `colgroup`     | `align`, `span`, `valign`, `width`                                                                          |
| `img`                 | `alt`, `height`, `width`, sanitized `cid:` source or an app-generated opaque marker                         |
| `li`; `ol`; `ul`      | `value`; `start` and `type`; `type`, respectively                                                           |
| `table`               | `align`, `border`, `cellpadding`, `cellspacing`, `role`, `summary`, `width`                                 |
| `td`, `th`            | `abbr`, `align`, `colspan`, `headers`, `height`, `rowspan`, `valign`, `width`; `th` may also retain `scope` |

Drop other attributes, including `on*`, `srcset`, background URLs and sender-supplied
application markers. Attribute values still require validation; an allowed name
does not authorize an unsafe value or URL.

CSS comments are removed outside strings and unquoted URL tokens, preserving
escapes and token boundaries so hidden images never become eligible for download. Values containing an unresolved CSS function outside quoted strings, such as
`calc()`, are removed. Plain `rgb`/`rgba` and `hsl`/`hsla` border colors and quoted
font names containing parentheses remain allowed; nested functions are removed.
Other color functions, including `hwb`, `lab`, `lch`, `oklab`, `oklch`, `color` and
`color-mix`, are removed. Colored borders remain subject to the same spacing
bounds, including when the color and width have no separating whitespace.
Repeated declarations of the same property resolve importance before source
order: the last accepted value wins at equal priority. Validate supported hiding,
size and offset values before choosing that winner; invalid important values
cannot block valid normal ones. Source acceptance and output retention are
separate: valid unretained values such as `display:flex` or viewport font sizes
still replace earlier declarations. Hiding accepts WebKit display keywords and
outside/inside pairs, visibility keywords, numeric/percentage opacity (including
exponents), CSS-wide resets and bounded constant `calc`, `min`, `max` and `clamp`
opacity arithmetic, with at most 64 scalar values and nested groups. Calculations
with layout units, variables or other functions remain outside that supported
grammar.
Retained styles drop importance annotations; shorthand/longhand ordering,
normalization and label inspection use the resulting emitted CSS.

A backslash escape never ends a quoted string or declaration. Declaration names and the importance marker are
read with escapes decoded after recognizing the source tokens. An escaped value
counts only when it is one source identifier whose decoded spelling can be
emitted as an identifier; escaped whitespace and punctuation never become CSS
syntax, and an escaped digit never forms a number. An escape in the importance
identifier does not invalidate a literal numeric value. Values with decoded
delimiters or quotes are not emitted. Hex escapes consume
up to six digits and one following CSS whitespace character; escaped newlines
inside strings are continuations. Inline styles split into declarations at semicolons outside quoted strings and
matching parentheses or square brackets; mismatched closing brackets do not end
an open block. A declaration whose quoted string a line break or the end of the
attribute interrupts is removed. Filtered inline CSS may preserve borders and border spacing/collapse, display,
font family/size/style/weight, dimensions and min/max dimensions, letter spacing,
line height, margins, padding, alignment, decoration, indent, text transform,
vertical alignment, white space and word wrapping/breaking. Both property names
and values are checked. Remove `url()` values, `@import`, executable expressions,
external fonts, clipping and other unapproved declarations. Remove sender-defined
foreground and background colors, including legacy color/background attributes.
The app controls both colors together so stripped backgrounds cannot hide text.
Image width and height preserve literal lengths, percentages and supported sizing
keywords, including `auto`, subject to the reader's sizing bounds below.
Unvalidated sizing functions and invalid values are discarded; discarded
declarations do not override HTML tracking-pixel attributes.
The accepted sanitizer's fixed light canvas is valid in dark app chrome; matching
rich content to a dark theme requires app-controlled readable foreground,
background and link colors, never restored sender colors. Dark rich-content
styling and configurable reading appearance have no assigned replacement slice.

Author-supplied `data:` URLs are not trusted image bytes. They are removed, as are
unsafe schemes and remote image sources. Only sanitized `cid:` references may
enter MIME resolution. Only the app may replace an admitted image with a local
`data:` source after validating its bytes. HTTPS remote-image references become
opaque non-loading placeholders, with destinations held outside the document.
HTTP and other non-HTTPS image sources are removed and never become consent or
retry references. Hidden preheaders, text below the reader's 4-CSS-pixel
legibility cutoff, and text made only of non-rendering format/combining characters
do not establish readability or mask an inspected address. The cutoff is
conservative: smaller text can still paint a smear. Body text continues to follow
Dynamic Type. The reader normalizes sender text sizes around this cutoff,
retains ordinary relative scaling, and pins the root font size to 16 pixels for
`rem`. Sender viewport and font-metric size units (`vw`, `vh`, `vmin`, `vmax`,
`ex`, `ch`) are removed; percentages and `em` remain supported. Placeholders use
their emitted size rather than the source image's discarded font styling.
Large negative leading margins and indents (at least 320 CSS pixels after unit
resolution) are normalized to zero. Negative percentage, viewport and
font-metric offsets are also normalized because their displacement depends on
unknown reader geometry. Large positive margins and indents are normalized the
same way, and padding or border-width declarations with a token of at least 320
CSS pixels are removed, because they can push a label past the reader's right
edge or below the viewport. This includes vertical sides and table border spacing.
Large letter spacing and vertical alignment offsets are reset, and line heights
of at least 320 CSS pixels become normal line spacing. Widths and minimum widths
of at least 320 CSS pixels are bounded by their containing block, preserving
ordinary desktop widths when room permits. At most four consecutive line breaks or rules are kept between readable text or
visible images, including newlines preserved by `pre` or `white-space` styles,
and share a conservative 160-CSS-pixel spacing allowance, so tall lines or large text
keep fewer breaks. Smaller inline children cannot reduce an ancestor's line-height
charge. Line-height expressions and font-metric or viewport units are removed
before rendering. Rules use ordinary vertical geometry: zero height and padding, half-em top
and bottom margins, and one-pixel top and bottom borders; their charge includes
that box and the preceding line. This may reduce intended blank lines in large
headings, or thick and padded dividers. Ordinary two-break body spacing remains.
When a retained sender font family uses `normal` line height, its metrics are
unknown to the spacing allowance, so spacer breaks are omitted while its font
and text remain. Explicit line-height factors and lengths retain their allowance.
Hidden text and non-rendering Unicode characters do not restart this allowance.
Inside links, empty containers and hidden images have no layout box and hidden text is omitted,
while descendants that restore visibility remain readable. Repeated empty
padding, margins and heights therefore cannot separate the rest of a link's text
from its label. Heights and minimum heights of at
least 320 CSS pixels are removed, including oversized table-cell height
attributes, and large bottom margins reset, so a tall spacer cannot push the
rest of a link's text below its visible label. Removed image heights fall back
to automatic sizing. This threshold is a readability policy; it can reduce
intentional large gaps, fixed-height banners and hero cells, and changes images
whose oversized CSS height deliberately altered their proportions. It does not
establish complete geometric visibility. Padding, wrapped lines and bidi layout can leave text
visible despite such offsets; they never justify discarding a painted label.
Small hanging indents and trailing left-to-right margins remain intact. Margin
normalization follows emitted declaration order and physical shorthand sides;
inner table roles retain their margin behavior. Automatic direction is removed,
leaving inherited explicit direction.
Descendants can restore readable text by resetting an inherited illegible font
size to a legible absolute or relative size, or declaring `visibility: visible`
or `initial` under a hidden ancestor; their text, links and inline images then
count as visible. Collapsed table rows, row groups and columns
still remove everything in them, including when collapse is inherited. Outside
links, hidden images retain normalized dimensions without fetching their bytes or adding a
readable placeholder. Restored visible images keep a visible placeholder when
their bytes cannot be shown. Links whose retained descendants contain no visible
content add no reader link control and do not consume the link limit. Visible
text, image placeholders and horizontal rules can still activate a link, including
descendants that restore inherited visibility.
Relative font sizes still scale a zero parent size to zero. Unsupported font-size
expressions and invalid values are removed before rendering and inspection. Zero
line height or maximum box dimensions alone do not clip overflowing text.

### Links and blocked remote content

HTML and detected plain-text links allow only `http`, `https`, `mailto` and `tel`. A message offers at most 200 links, in rich and plain
presentation alike, including the readable fallback. The fallback applies the
same limit even when one HTML anchor spans many paragraphs. Later anchors,
addresses and fallback link spans stay readable plain text without a link action
or link accessibility role.
Detected plain-text links preserve brackets required by IPv6 hosts and balanced
parentheses or brackets in URL paths. Sentence punctuation and unmatched trailing
closing brackets remain readable text outside the link.
Other sender schemes and automatic opening remain blocked. Sanitized anchors use
app-owned opaque navigation markers; their exact vetted destinations and visible
text remain outside the document for confirmation. Choosing a link shows its
exact full destination with **Open link** and **Cancel**; system handoff occurs
only after **Open link**. A queued link choice rechecks its body and reader owner
before showing any destination. A pending confirmation hides immediately when its message or mailbox changes,
even before the previous reader finishes closing. Confirmation is discarded when the body presentation
or Inbox owner changes, and the current ownership boundary is checked again
immediately before handoff. No link inspection needs a network lookup, backend,
persistence or URL logging.

The accepted link inspection additionally compares URL-like visible anchor text
with the destination and checks scheme mismatch, internationalized or numeric
hosts, embedded credentials, bidirectional controls and cross-site redirect-query
signals. A flagged link shows concise reasons and offers Cancel, Copy Link and
Proceed. Copy and Proceed recheck current access before revealing the destination.
Displayed web addresses with an explicit HTTP or HTTPS scheme, bare domains,
dotted-quad IPv4 addresses and bracketed IPv6 addresses participate in the host
comparison, including an optional port, path, query or fragment.
Bare domains with a punycode (`xn--`) final label also participate, including
uppercase labels and the same port, path, query or fragment suffixes.
Equivalent percent-encoded host spellings and IPv4/IPv6 spellings compare as the same host,
both for displayed-address comparison and redirect-query warnings;
the exact destination remains unchanged. Ordinary version, time and date labels
and displayed addresses without a host do not produce an address-mismatch caution.
An admitted image's description labels its link only when the link paints no text,
so it cannot mask a painted address; placeholder descriptions are painted and
count as link text. The readable fallback keeps every description.
An unflagged link is never labelled safe. The exact destination goes to the
system; its subsequent redirects are outside this inspection.

**Remote Message Content** stays blocked without authorized retrieval. Preserve
image descriptions and non-loading placeholders and visibly explain that images
are not loaded. Known **Tracking Pixels** remain blocked even if other images are
authorized. Zero-dimension and declared 1×1 remote images are rejected using HTML
and inline CSS dimensions, including max dimensions and CSS overrides.

Rich rendering alone does not authorize a **Load images** action. The accepted
remote-loading feature requires a notice explaining disclosure of the device's
IP address and message-open time, explicit presentation-scoped consent under
Ask, a separate isolated bounded HTTPS fetch outside WebKit, and encrypted reuse
in the separate **Authorized Remote Content Cache**. Its device-local policies
are Ask by default, Never and Always Load, with per-connection overrides. Known
tracking pixels never become loadable. Consent, policies and the remote-content
cache belong to [#763](https://github.com/unwired-dev/product/issues/763). Until
that retrieval boundary is implemented, the reader shows placeholders and the
blocked-content notice without a load action.
Remote Message Content retains its viewport or one-viewport-margin loading rule,
including Always Load; the Inline Images decision below does not change it.

### MIME Inline Images

Explicitly opening a message resolves every visible, sanitized `cid:` reference
within the per-message bounds and shared presentation budget below, without
viewport admission. Sanitizer visibility excludes hidden and non-rendering
content; it does not mean geometric visibility within the reader viewport.
This is the owner-approved rule recorded in the
[ADR 0029 amendment](adr/0029-sanitize-html-before-webkit-rendering.md#amendment--2026-10-06);
this is part of #605 rich presentation, separate from received attachment
controls in [#610](https://github.com/unwired-dev/product/issues/610).
Normalize Content-ID comments and surrounding folding whitespace (whitespace inside
an ID makes it unresolvable), URI-decode references,
and preserve MIME header literals. Search the selected MIME alternative first,
then its nearest enclosing related scope, then eligible outer scopes. Do not
traverse attachment-disposition or `message/rfc822` containers, or filename-bearing
attachment subtrees. An inline image leaf may have a filename; a filename-less CID
image sibling without a disposition in a mixed scope is eligible. Unreferenced,
hidden, zero-sized and non-rendering image parts, including those in cells of
collapsed table columns, are never fetched. Native table elements keep their
table display roles after sanitization. Table spans are normalized before
rendering and visibility inspection. Excessive table-layout work falls back to
retained readable text without resolving inline images. Conflicting
normalized Content-ID values remain unresolved. Image parts with children and
descendants of unrecognized or conflicting MIME containers are never fetched.

Admit only complete, signature-valid, single-frame PNG, JPEG, GIF or WebP images.
The reviewed image bounds are 5 MiB per image, at most 20 attempts and 20 admitted
images, 20 MiB aggregate image bytes, at most 8,192 pixels on either axis, 16 Mi
pixels per image and 32 Mi pixels in aggregate. Every requested image reserves its
declared bytes against the 20 MiB aggregate before download, whether or not it is
admitted. Only the first 20 unique visible Content-ID references are collected for
resolution; later ones render as placeholders, and every occurrence still counts
toward the presentation budget. Check provider-declared sizes
before requests and bound received and decoded data. Missing, malformed,
unsupported or oversized parts remain placeholders without failing the readable
body. The presentation also shares a 20 MiB encoded-image-byte and 32 Mi-pixel
budget across simultaneously displayed messages; charge every resolved occurrence,
including duplicates, and release reservations when presentation ends, is
cancelled or fails. Inline Images are not viewport-scoped; references outside the
viewport remain eligible on that explicit open within these same bounds.
Count every independent reader, including multiple Mac windows displaying the
same message. Each reader admits its own prepared presentation; if adding a
reader would exceed the budget, images that do not fit remain placeholders only
in that new reader. Existing readers keep their document and position. Closing
one reader returns only its own cost. A stale
load or close from an earlier Inbox owner cannot change the current budget.

Save admitted inline bytes and their validated resolution state with the encrypted
body so later opens remain provider-free. A legacy entry without resolution state
must be checked against sanitized CID references before an explicit online
refresh. A cancelled explicit refresh remains cancelled. Speculative recent-body
prefetch never fetches Inline Images.

### Presentation, accessibility and fallback

Keep a stable loading placeholder until sanitization, styling and initial WebKit
layout finish, then reveal one representation. A cache hit must not flash plain
text before switching to rich HTML. Preserve the reader's text position when
content resolves and reserve validated image dimensions when available.

Measure content size after navigation finishes using only the application-owned
`callAsyncJavaScript` script in `WKContentWorld.defaultClientWorld` on both hosts,
with page JavaScript disabled. Fit the view to the detail column and bound its
height. Invalid or failed measurement uses the retained readable-text fallback.
Normal-height documents stay pinned to the top of WebKit and use the
reader's outer vertical scroll; horizontal overflow cannot introduce a second
vertical scroll. Only a document above the presentation height cap scrolls
vertically inside WebKit. The reader's cap is 20,000 points on both hosts, and a
document above it stays fully reachable by scrolling inside the view.

Rich and plain text remain selectable. VoiceOver can read content in order,
identify links and image descriptions, and reach confirmation and retry actions.
Text respects supported accessibility sizing. Links have an accessible name and
a keyboard activation path; the current separate **Open link: …** control may
provide it. **Try again**, **Open link**, **Cancel**, and any flagged-link actions
are focusable. iPad Full Keyboard Access and Mac keyboard navigation can enter,
read, scroll, activate links and leave the rich view without a focus trap.

Plain-text bodies render as selectable readable text with preserved line breaks
and vetted URL detection. Missing HTML, an empty sanitized result, sanitizer
failure, unavailable isolated rendering, WebKit load failure or content-process
termination use retained readable text as the terminal fallback for that
presentation; a later presentation of the message, such as one with newly
downloaded images, renders again. Release HTML and image reservations on failure. Never fall back to unsanitized HTML or relax
isolation to make a message render. If no readable text remains, show the empty
body state rather than an indefinite loader.

### Recent-body prefetch

Prefetch begins after **Initial Mailbox Availability**, without delaying the
first usable newest-50 list. It follows committed synchronized metadata, can
continue as later Inbox pages commit and recomputes selection at later
synchronizations. It does not require completion of all metadata work. Use one
reference instant per synchronization selection, not a moving per-message clock.

The general rule selects at most 500 distinct messages per connection across
Inbox and Sent Mailbox in the inclusive interval from that reference instant
minus 30 days through the instant. Order by newest applicable timestamp first,
then ascending **Stable Provider Message Identity**. A message in both roles
counts once using its later applicable timestamp. For #605, select only the
currently cached newest 200 Inbox entries using their received timestamp;
there is no extra listing to discover 500 bodies, Sent query or historical scan.
Exclude Spam and Trash even when they also carry `INBOX`. Future-dated and older
messages are outside the window. Each [mailbox](#gmail-mailboxes) selects its own
working set from its own cached Inbox. Sent and pinned-Thread expansion have no
assigned scope in this slice, and advanced Profiles are deferred.

Each connection has at most one speculative prefetch/historical-work lane. All
body pipelines together permit at most two concurrent loads per connection and
four account-wide, shared across windows, explicit opens and prefetch. A provider
may lower only its own limit if its transport cannot safely multiplex. Explicit
opens and visible reader content take priority; speculative work yields immediately,
and interactive requests can overtake or cancel queued speculative requests.
The remaining general priority order is authorized remote images, then speculative
prefetch/historical work. No mail-loading task creates an account-wide busy state
or disables navigation or interaction with already available mail.

Prefetch requires wholly well-formed Content-Type and Content-Disposition values;
any malformed header keeps the body on demand. Mail with malformed MIME parameters
can still be opened explicitly when its body type is readable. Prefetch saves
readable body text and any decoded HTML alternative, not attachments
or Inline Images. Gmail first checks body-free Content-Type metadata and fetches
only single-part `text/plain` or `text/html` messages. If the optional header is
absent, use the provider payload MIME type. Multipart or attachment bodies remain
on demand; speculative fetching must neither request nor receive their embedded
resources. An encrypted exclusion marker avoids repeating the preflight for an
unchanged excluded message. Refuse that marker if admitting it would evict a
protected readable body. A later changed revision is eligible for reevaluation.
Exclusion markers saved before #608 may report their messages as saved until
their bodies are downloaded and cached. Newly saved markers report that the body needs downloading.

Offline or network loss stops provider prefetch; cached reading remains usable.
Cache-only registration permits reads but no prefetch, cache write or pruning
until registration verifies again. Authentication failure stops authorized provider
work and uses **Gmail needs your permission again**, whether prefetch, inline-image
resolution for a cached or opened body (whose readable text stays shown) or an
explicitly opened body met the rejection, so the Inbox offers **Allow Gmail access**.
An overlapping metadata synchronization keeps that notice; the next load after
authorization can recover the Inbox, retry unavailable bodies and resolve pending
Inline Images in already shown bodies.
Gmail quota/rate-limit and
server failures pause speculative work and follow the existing retry/activation
path without a tight retry loop. A usage-limit 403 must not trigger reauthorization.
Ownership changes, Inbox closure and removal invalidate speculative work and
fence late completions just as they do explicit downloads.

Prefetch is entirely device-local. It uses only the authorized Gmail connection
and never asks Convex per message, uploads bodies or exposes mail activity to a
backend. Logs contain only allow-listed codes, HTTP statuses and decode paths,
never content, addresses, message identifiers, destinations or raw failures.

### Cache admission and eviction

The hard body-cache limit remains 500 MB device-wide, shared across windows and
connections. Count all stored body bytes, encrypted inline bytes and cache
bookkeeping toward it. Lists remain separate and are never evicted to admit a
body. Reserve capacity before publication and reconcile interrupted over-budget
state only when cache writes/pruning are authorized.

Each selection admits recent candidates in the working-set order above into a
cache-fitting protected set. Only candidates that fit receive protection. A
candidate may evict eligible bodies outside that set, but admitted candidates
from one selection never evict each other. If no eligible space suffices, refuse
admission and leave that body on demand until a later synchronization finds space.
Do not cycle through selected bodies by repeatedly evicting protected peers.

Evict eligible opened older non-pinned bodies first, then eligible non-pinned
prefetched bodies. Within a tier, use least-recently-read order with the current
opaque cache-entry identifier's lexicographic tie-break. The general final tier
is least-recently-read pinned-Thread bodies outside the cache-fitting protected
set; #605 has no pins and therefore no such tier. Opening a selected cached body
does not demote its protection or prefetch status. An oversized on-demand body
may be shown for the current open but is not saved.

A prefetched body leaving the 30-day/selected set loses protection and becomes
eligible for the prefetched eviction tier; leaving the set alone does not require
immediate deletion. A message leaving the cached Inbox removes its saved body,
including a late download that finishes after the metadata was removed. A failed
prune is retried at the end of the next successful synchronization, even after a
relaunch or when no metadata changes remain. A stale synchronization retries
rather than deleting bodies from a newer list. Pruning,
mailbox removal, sign-out and account removal retain the existing ownership and
cache-only fences. A valid cached body is not re-fetched just because it was
opened or selected for prefetch. Invalidate it only for a changed provider revision
or identity, security/rendering-version change, explicit reload or cache removal;
read-state and other metadata changes alone do not invalidate it. Damaged or
mismatched bodies read as absent and may be downloaded again.

### Unavailable bodies

A body that cannot be shown says why, beside **Try again**:

- **This message is not saved on this device, and Gmail could not be reached to
  download it.** This appears offline, or after a network, quota or server
  failure. Retry or the next eligible synchronization can download it again.
- **Gmail needs your permission again to download this message.**
- **This message is no longer in Gmail.** This one has no **Try again**.
- Locked or unreadable storage shows the storage message, as the Inbox does.

Packaged keyboard, VoiceOver, native WebKit isolation and real Gmail qualification
remain required under the protected checks below. The earlier structured-text
reader's results do not qualify rich rendering, CID resolution or recent prefetch.

## Freshness across app lifecycles

The application, not a window or screen, owns Gmail synchronization
([#617](https://github.com/unwired-dev/product/issues/617)).

- **Mac.** Synchronization continues after the last window closes: every five
  minutes the running app verifies registration and synchronizes every open mailbox, and a reopened window
  shows the committed mail at once. Explicit Quit ends it with the process. No
  helper process runs.
- **iPhone and iPad.** A background task asks iOS for refresh opportunities at
  most every 15 minutes. iOS decides whether and when each runs, and none runs
  after the person force-quits the app or turns Background App Refresh off.
  Each opportunity verifies registration before it reads Gmail. Becoming active
  always catches up, so the app never depends on background time. While the app
  stays active, a five-minute fallback poll keeps an open Inbox fresh; it stops
  when the app leaves the foreground.
- **Interrupted work.** Every opportunity resumes from each mailbox's committed
  checkpoint. One that the system suspends or ends repeats at most its
  uncommitted step, and the next activation catches up on mail it never reached.

**Push wake hints** carry only an opaque route. The handler reads that route and
synchronizes only its mailbox after registration verifies. It never decodes,
keeps or logs Gmail's history ID or address, because the mailbox's checkpoint
says where to resume. A malformed hint, a route this device does not know, or a
route removed while verification runs, or whose mailbox was removed or needs Gmail again, reads nothing. Registering
routes with Gmail and the Convex relay, and receiving APNs wake hints, belongs to
[#781](https://github.com/unwired-dev/product/issues/781). Until then no device
registers a route, and the Mac's five-minute interval is its only background
trigger.

## Received attachments

[#610](https://github.com/unwired-dev/product/issues/610) lists each opened message's
received **Attachments** below its body on iPhone, iPad and Mac. Each shows its name,
size and availability. Listing makes no separate attachment request; prefetch never
requests attachments. Gmail can include small attachment bytes in the full MIME
response required to open a body. Every Gmail Inbox response, including an attachment
download, is refused once it exceeds 40 MiB while it is received, separately from the
25 MiB attachment download limit below. The encrypted body cache retains only
attachment descriptors.

- **Listing.** The list comes from the message structure Gmail returns with the
  body and is kept with the encrypted body, so it also shows offline. A body cached
  before attachment metadata was kept reads it from Gmail once, on its next online
  open; offline, that body shows no list. Attachments are named or
  attachment-disposition parts outside the readable body. Inline Images the body
  resolves are not listed. Attached messages and their contents are not offered for
  download, even when their type declarations conflict. Containers are searched only
  when their declared media types are non-empty and agree, including Gmail's type
  and every Content-Type header when present. An ordinary file whose Content-Type
  header tokens conflict remains available as a generic file. Rows appear 20 at a time,
  with **Show N more** for the rest, so a message with thousands of parts stays usable.
- **Names.** Names drop path separators, control and direction-override characters,
  lone surrogates and leading dots. Names longer than 1,024 UTF-16 units retain only
  their first 960 and last 64 units before Unicode cleanup; dots in the retained start
  become underscores, so only the retained ending can supply a file extension.
  The cleaned name is shortened to 120 characters and 255 UTF-8 bytes when needed.
  That shortening keeps the final suffix when it has 1–16 characters without dots or
  spaces; otherwise dots in the shortened name become underscores, so an earlier
  suffix cannot become the file extension. An empty name becomes `attachment`.
  The shortened name is shown in the list and used as the saved filename, with
  surrounding whitespace removed on save.
- **Download.** **Download** reads the message again from that attachment's
  mailbox, at that mailbox's current generation. It downloads the attachment only if
  its position, name, type and size are unchanged. The download counts against the
  mailbox's body loads as an explicit open. The bytes are kept only when Gmail's
  base64url data decodes to exactly the declared size. Native code decodes and checks
  them again before writing the file. Attachments over 25 MiB are listed as **Too
  large to download on this device.** without a download action.
- **Cancel.** **Cancel** aborts the authorized Gmail transfer in progress. A file that native code was
  already writing is deleted when the write finishes.
- **Failure.** The row says why and offers **Try again**:
  **Gmail could not be reached to download this attachment.** (offline, network,
  quota or server failure),
  **Gmail needs your permission again to download this attachment.** (the Inbox also
  offers **Allow Gmail access**),
  **Gmail sent an incomplete or damaged copy of this attachment.**,
  **This attachment could not be saved on this device.**, or the locked-storage
  message. **This attachment is no longer in Gmail.** has no **Try again**.
- **Attach.** A Downloaded Attachment also offers **Attach to New Message**, which
  copies its bytes into a new Draft through the mailbox's current generation; see
  [Drafts](drafts.md#files-and-images).
- **Open and share.** A **Downloaded Attachment** offers **Open** and **Share**.
  **Open** shows the system **Attachment Preview** with Quick Look
  (`QLPreviewController` on iPhone and iPad, the Quick Look panel on Mac). Quick
  Look never launches another app or runs the file. On Mac, changing focus while the file is being prepared does not move its preview or share sheet to another window. If that window closes, presentation is refused. **Share** opens the system share
  sheet (`UIActivityViewController`, or `NSSharingServicePicker` on Mac) with only
  that file. If the file is gone, the row offers **Download** again.

Downloaded Attachments are plaintext so the system can preview them. They are
written under the app's private Application Support directory, in a folder per Mailbox Connection,
with a random name per file and complete file protection on iPhone and iPad. They
are excluded from backups and never uploaded. The store holds at most 250 MiB,
evicting the least recently used files before another save. A missing or evicted
file offers **Download** again. Their owner deletes them:

- closing the message's last reader, or a listed message leaving the Inbox;
- the Inbox closing or changing owner;
- removing the mailbox, sign-out, account deletion and device removal, which also
  delete the connection's folder in native code;
- relaunch, which deletes files left by an earlier process.

Attachments in an online Gmail search result outside the Inbox have the same
explicit Download, Open and Share actions. Their downloaded files last only while
a reader stays open. If a listed message also appears in search, leaving the Inbox
deletes its downloads even while the search reader stays open; another explicit
Download acquires a new copy. Opening an off-Inbox result does not save its body
in the encrypted body cache.

A file still shown in Quick Look, or handed to a share that has not finished, is
deleted after its reader closes, its message leaves the Inbox, or the Inbox closes or
changes owner only once that preview closes or the share ends.
It also stays through eviction and counts toward the 250 MiB limit. A download
that cannot fit without deleting a presented file fails and can be retried after
the preview closes or the share ends.
Removal, sign-out, deletion and relaunch delete it immediately.

Attachment controls ignore input queued for a reader that has changed or closed,
including a queued **Cancel** after another reader starts a new download.
A file saved before the mailbox was verified again is not presented; the row offers
**Download** again. If verification interrupts a download, the row also offers
**Download** again without reporting a storage failure or automatically retrying.

## Mailbox Sync Status

The cached list stays visible while Gmail work proceeds. A known network outage
during relaunch opens only the last verified mailbox's saved Inbox. No provider
read or cache update runs until registration verifies again. The account page
calls this **Saved Gmail Inbox**, rather than claiming verified Gmail access.
**Try again** verifies registration before resuming synchronization. Rejected
grants, identity mismatches, unknown failures and pending removals cannot use
this cache-only path.

The Inbox reports:

- **Checking Gmail…** while synchronizing. An empty cache shows a progress
  indicator instead of an empty Inbox.
- **Gmail needs your permission again** after Gmail refuses the mailbox's grant.
  **Allow Gmail access** runs Gmail authorization for the same mailbox and
  synchronizes again.
- **Gmail could not be reached** after a network failure, quota or rate limit, server
  error or malformed Gmail response. **Try again** resumes from the last commit;
  so does the next activation.

Locked or unreadable storage hides the cached mail, as the
[preview Inbox](private-inbox-storage.md#failure-behavior) does, and offers
**Try again**. Without a connected mailbox, nothing is cached or shown.

## Boundaries

Every Gmail request, cache and body call names its mailbox and that mailbox's
current generation. Removing a mailbox, or verifying it again, invalidates its work
already in progress; stale work cannot read Gmail or repopulate a cache. One
mailbox's work never reaches another's credential or cache, including another
Google account that reuses the same address, which is a separate mailbox.

Gmail tokens and refresh credentials never enter JavaScript or Convex. Each Gmail
write changes only the selected message's labels. Message metadata and bodies stay
on the device and are never uploaded. Logs carry only allow-listed
codes, HTTP statuses and failing decode paths, never mail content or addresses.

Each saved body is sealed to its Google account, address and Gmail message ID. A
saved body that does not match the message being opened is discarded and downloaded
again, never shown. Bodies held in memory are forgotten with the rest of the open
Inbox's mail, and a download that finishes after its Inbox closed is dropped.

Removing a mailbox removes its cache and bodies and forgets its mail held in memory.
A synchronization that loses mailbox ownership stops and clears its displayed mail.
Sign-out, deletion and a removal of this device by another device remove every
mailbox's cache with the rest of the account's data. A mailbox's mail held in memory
is forgotten as soon as its Product Account, connection or address changes, its
grant is refused, or the Inbox closes, so another account or mailbox never renders
it, even from a synchronization that was still running.

Gmail reads do not ask Convex about this device. The removal check runs when a
synchronization opens or commits the cache, so the backend learns nothing about
per-message read activity. Every provider mutation first revalidates the Trusted
Device. Unavailable validation sends nothing; a revoked device purges local mail
and credentials. Whether a provider mutation or opening or saving the cache finds
the removal, the Inbox hands over to the account page, which explains
**This device was removed**; it never claims the purged data was kept.
The explanation survives foreground verification while the device stays signed
out. Explicit sign-out clears it, and a concurrent account deletion keeps its own
explanation.

## Deterministic evidence

The shared integration tests drive the real synchronization through a controlled
Gmail API and mailbox cache (`@private-email/mail-core/testing/gmail-mailbox`).
They cover pagination, relaunch with history only, interrupted pages and commits,
expired history, authorization and retry classification, competing stores,
mailbox reselection and log privacy. The #605 body reading cases cover:

- untrusted HTML sanitized into the CSP-bound document, with vetted links, sender
  colors and remote loads removed, tracking pixels dropped and hidden preheaders
  excluded;
- plain text, Latin-1, separately served parts, partial-body rejection, plain
  fallback and forwarded-part exclusion;
- inline images within their bounds (animated, oversized, truncated, hidden and
  unreferenced parts refused or never fetched), kept for provider-free opens and
  resolved later for bodies cached without them; explicit opens resolve all
  visible, sanitized CID references without viewport admission;
- the image budget shared by displayed bodies and independent readers of the
  same message, stable existing documents when another reader joins, and
  owner-generation fencing of reservation mutations and reader closure;
- recent-body prefetch: selection, the Content-Type preflight and exclusion
  markers, the eviction tier and protected set, two concurrent loads, and
  authentication failure;
- link inspection signals;
- offline reopening, failures and recovery, mismatched cached bodies, removal with
  a message or mailbox, and late results after the Inbox closes;
- received attachments (#610): listing names, sizes and availability without
  attachment requests, oversized attachments, safe names, exact-byte downloads,
  incomplete and undecodable data, transfer-abort propagation, cancellation including during the native save,
  interrupted download and retry, refused grants, removed messages, a file the device
  no longer has, legacy bodies without metadata, deletion on reader close and Inbox
  forget (including closure during a pending body refresh), and isolation and removal
  across two connections that reuse message IDs. Host adapter tests use the real
  stores with a synthetic native boundary to verify transfer cancellation and retry
  when AbortSignal lacks modern convenience methods.

Organizing tests cover every action's Gmail labels, changes kept through an outage
and relaunch, lost responses, refused and repeated changes, Undo after Gmail
confirmed a trash, labels changed in Gmail, changes bound to their mailbox, intake
during a blocked history read, lost local save replies, changes saved under each
step of a long listing and during action preparation and settlement, mailbox
changes during conflict reopening, preserving labels on Undo, five-attempt
stopping and resolution, revoked access, and the cache upgrade. Shared
registration tests cover queued foreground verification, concurrent sign-out and
deletion after a mailbox removal hand-off.

The #606 shared tests drive two or three controlled Gmail mailboxes, which reuse the
same Gmail message IDs, through the app's composition of registration and mailboxes.
They cover the unified newest-first order with stable ties and one-mailbox views;
organizing that reaches only its own mailbox; one mailbox's refused grant leaving
the other usable until it is authorized again; removal during a running
synchronization forgetting only that mailbox's mail and changing nothing in Gmail; a
new Inbox for another Product Account; and at most two body loads per mailbox and
four across mailboxes, using explicit download-start signals; a single image budget
across readers from different mailboxes, with independent release on removal. Rendered journeys on both hosts add a second mailbox, add the
first again without duplicating it, switch between **All inboxes** and one mailbox,
recover a refused mailbox while the other stays readable, and confirm a removal.

The #617 shared tests drive two controlled Gmail mailboxes through application
lifecycles:

- the Mac interval synchronizing with no window open, and a reopened window
  showing the result without a Gmail request, including recovery from cache-only
  access after connectivity returns;
- no Gmail request after Quit, and relaunch reading only history after the
  committed checkpoint;
- a background synchronization suspended after its first page, then foreground
  catch-up after a missed wake, resuming from the committed page with no
  duplicates;
- a wake hint synchronizing only its routed mailbox, with its history ID neither
  committed nor logged;
- malformed, unknown-route and removed-mailbox hints reading nothing, including
  a route removed while verification is pending.
- a newly revealed unrelated connection remaining unloaded during valid or
  invalidated routed verification, then synchronizing on foreground catch-up.

The mobile host's headless-entry test loads its entry without mounting a Router
layout, restores a saved synthetic mailbox and observes the resulting committed
mail through the shared store. It also covers restricted scheduling and failure
to register a background task without an unhandled rejection or private error log,
a failed background refresh reporting failure with only a fixed diagnostic, and the
five-minute active-app poll synchronizing the real stores from a controlled Gmail
boundary while active, stopping in the background, resuming and disposing.

During #617 review, a signed simulator Release build with the background-task
modules passed the packaged synthetic open/read/relaunch journey on iPhone 18 Pro
and iPad Pro 11-inch M5 with iOS 27.0. This verifies launch and persisted sample
read state; simulator background tasks remain restricted.

Real iOS background scheduling, APNs delivery and packaged Mac journeys with no
window open are pre-release evidence.
Native wake delivery in #781 also requires mounted-screen journeys while
restored connections change. Shared-store tests do not qualify whether those
host updates independently trigger synchronization of unrelated mailboxes.

The #608 shared test searches two controlled mailboxes after an offline relaunch
that opens only their saved Inboxes, with no Gmail request: word, case and accent
matching, scoped and unified results, saved bodies against exclusion markers, opening
a saved result, and removal. Rendered journeys on both hosts search across mailboxes,
show each result's saved state, see a result become saved when held prefetch finishes,
open a result and see it saved after the reader closes, keep only the current answer when an earlier lookup replies late, and drop a
removed mailbox's results.

The #609 shared test searches two controlled mailboxes online through the native
Gmail request boundary: the request's query and page size, results across mailboxes
newest first, a second page from only the mailbox that has one, mail outside the Inbox
and trashed mail, opening an archived result without saving its body (also through a
synchronization), one mailbox's outage or refused grant beside the other's results, a
failed next page kept for retry, and storage locking or a removal while its search runs. The controlled
Gmail matches every word of `q` in sender, subject and content; Gmail's own operators
need the protected tenant. Rendered journeys on both hosts search Gmail only on
request below the saved results, open an archived result in the reader without saving
it, drop the answer when the query changes, show one mailbox's outage beside the
other's and the saved results, search again, and discard a reply for a query that
changed while it ran, even after returning to that query or scope. The hosted native
suite sends search GET requests through the real URLSession transport with controlled
first and next pages, independent authorization/server refusals, and literal `+` and `&`
query encoding.
Real Gmail search semantics are pre-release evidence.

The attachment/search integration journey downloads and presents an archived
result without caching its body, preserves the file through ordinary synchronization,
and deletes it on remote or optimistic Inbox removal, last-reader closure and Inbox
forget. The cancellation journey also runs on an archived search result. Both rendered
host search journeys download, open and share that result and verify cleanup when
another message is selected. These use controlled provider and native presentation
boundaries; they do not qualify the system preview or share sheet.

Rendered host tests drive the isolated reader's configuration, measurement, link
cancellation and confirmation, flagged-link copying, keyboard link access and
WebKit failure fallback. They also cover the Inbox states, organizing from the
reader and a row with Undo, closing the reader after a row removes its message, a
device found removed reaching the account page's explanation, one announcement
across two Mac windows, the account page round trip, and two Mac windows over one
store. The #610 rendered journeys list a message's attachments, download, open and
share one, cancel a slow download, retry after Gmail fails, ignore queued Open and
Cancel input after the reader changes, and delete the file when the reader closes. The native Quick Look and share-sheet presentation, and a packaged
attachment journey, remain deferred: no packaged journey downloads an attachment yet.
Before release, check delayed **Open** and **Share** requests while another Mac
window gains focus, the original window closes, or the iPhone/iPad app moves into
the background during file preparation.
The owner-approved isolated client-world measurement and bounded all-reference
CID loading satisfy the amended requirements. Component tests exercise height
events and fallback; they do not alone prove native content-world isolation.
The patched native source, iOS Release and Mac Testing builds, and packaged
iPhone/iPad WebKit journeys supply the native evidence described below. Mac
runtime and protected accessibility qualification remain deferred.

The hosted native storage suite checks the Gmail path allow-list, the label
change's identifiers and body, query encoding,
cache revision and address rules, ciphertext, and removal on reselection and
purge. For bodies, it checks:

- sealing to the mailbox and message, and discarding of moved or damaged files;
- eviction of opened bodies before prefetched ones under a small limit;
- refusal when only protected bodies could make room, and oversized-body refusal;
- over-budget reconciliation when pruning;
- cache-only reading and listing without writing;
- removal with the message, mailbox or account.

All 34 tests passed on a fresh iOS 27 simulator before #606. #606 adds seven native
tests, bringing the suite to 41: connections deduplicated by Google account, mixed
authorization and reauthorization with the same account, removal of one connection's
credential and cache, the upgrade of a single-mailbox record and cache into one
connection, and descriptor removal and epochs through the synthetic Product Sync
boundary, including unreadable descriptions, remove/re-add before publication,
offline consent encountering a removal, interrupted cache cleanup with relaunch retry,
concurrent additions of one mailbox converging on one epoch, and bodies written before
Mailbox Connections counting toward the device-wide limit. The concurrency case
also checks competing recreations, read-back failure with relaunch, offline-grant
and address-update conflicts, a winning removal, and removal/recreation after a
successful write. Legacy-body checks cover later adoption and connection-scoped
listing and membership pruning. An offline authorization of a mailbox another device
published keeps it when the descriptor is unchanged since this device last read it,
and loses it when that descriptor was removed and added again meanwhile. An absent
observation cannot authorize adoption of a later descriptor. The suite also checks
that an address-update conflict or a later connection's failed publication cannot
discard a learned removal. Existing native tests now name each connection. For #608, the native cache test
also distinguishes an exclusion marker from a saved body and replaces it after
the body is downloaded.
Connections and descriptors written before epochs converge on one legacy epoch and
keep their connection, unless the mailbox was removed and added again elsewhere, and
legacy adoption keeps bodies already saved for the connection across opened and
prefetched tiers. It also checks concurrent legacy upgrades, first authorization
on another device, legacy removal intent against later incarnations, and retained
offline recreation after a legacy upgrade. #610 adds two tests, bringing the suite to
43: Downloaded Attachments are saved only with their exact declared bytes, under a
name confined to their folder, for the current generation and address, and are
deleted by discard, connection removal, removal of every cache and launch cleanup.
The tests also cover bounded storage with oldest-file eviction, cleanup after a
post-write ownership rejection, and attachment cleanup even when another cache
removal fails. A URLProtocol fixture drives the real URLSession transport through
response-length overflow, streamed overflow and cancellation; it does not contact
Gmail.
All 43 tests passed in the hosted storage suite on a fresh iOS 27 simulator with
Xcode 27.0 for #610. Before it, all 41 tests passed in
the hosted storage suite on a fresh iOS 27 simulator with Xcode 27.0, real Keychain
storage, CryptoKit and the filesystem. The Convex and provider boundaries remain
synthetic. An earlier run replacing only Keychain with an in-memory stand-in passed
the then 40 tests; that run is logic evidence, not Keychain qualification.

Registration Mock Mail Sessions answer Gmail requests, including the prefetch
preflight, from a synthetic mailbox of three Inbox messages over two pages and one
label. Each message has an HTML or plain-text body; label changes apply for the
rest of that launch. The session is compiled only into the selected test build.
The packaged iPhone and iPad journeys confirm setup, open the synchronized Inbox,
render the opened HTML body in WebKit, confirm and cancel a link destination,
star and archive a message and undo the archive, relaunch from the encrypted
cache and return to the account page. The reading steps and the organizing steps
each passed on iOS 27 simulators before they were combined; the combined journey
runs in the Expo native CI jobs.

The standalone synthetic-provider check calls the actual Swift provider with
attachment, inline and absent-disposition fixtures. It verifies repeated MIME
header selectors, body-free preflight responses, full body responses and the
unchanged packaged mailbox pagination. Run it with
`zsh native/private-inbox/integration/metadata.zsh`; the native storage runner also
executes it. This checks synthetic Gmail response fidelity and does not establish
live-provider attachment exclusion or a packaged native journey.

The Mac `Testing` build compiles the patched WebView. The packaged Mac journey
remains deferred while the desktop is locked, and hosted Mac storage tests remain
deferred pending a provisioning profile.

Those native builds, storage checks and packaged journeys are round-2 evidence
for their then-current artifacts. Round 3's per-reader admission and
owner-generation fixes are covered by updated public-store regressions, host
component suites and production bundle checks. They do not claim a new packaged
native journey or completed release qualification.

```sh
mise exec -- pnpm exec turbo run lint format check-types test --filter=// \
  --filter=@private-email/mobile... --filter=@private-email/macos...
mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

For packaged journeys, select `registration-declined` with the
[native Mock Mail Session commands](mock-mail-sessions.md).

## Protected Gmail qualification

These checks are deterministic application evidence, not real Gmail evidence. With
the [protected Gmail test tenant](gmail-provider-test-tenant.md) and signed hosts,
verify on iPhone, iPad and Mac before release:

- the first listing of a large Inbox, with the newest 50 usable first;
- arrival, archive, delete and read changes made in Gmail after relaunch;
- recovery after Gmail expires the stored history ID;
- a revoked grant reaching **Gmail needs your permission again**, then recovering;
- offline launch from the encrypted cache, and rate-limit handling;
- non-ASCII senders and subjects, as Gmail returns them in metadata headers;
- opening real HTML, plain-text and non-UTF-8 bodies, including a large body Gmail
  serves separately, then reopening them offline;
- isolated rich HTML with scripts, external CSS, remote images, unsafe URLs,
  navigation and storage attempts blocked on both native hosts;
- bounded CID images on explicit open, independent invalid-image placeholders,
  and a provider-free cached reopen;
- recent prefetch after initial availability, interactive priority, inclusive
  date/identity ordering and protected-set admission under the hard cache limit;
- received attachments listed without download, then downloaded, previewed and
  shared from both hosts, with a large real attachment, cancellation and the files'
  removal with the mailbox;
- that opening and prefetching mail make no request other than Gmail's while
  remote content is blocked, and that links open only after confirmation, with
  VoiceOver, Full Keyboard Access and Mac keyboard focus.
- every organizing action and **Undo**, as seen in Gmail on the web;
- changes made offline, then sent after reconnecting or relaunching;
- a refused change after the label or message is deleted in Gmail;
- two protected mailboxes added to one Product Account, the same Google account
  added again without a duplicate, the unified Inbox and each mailbox alone, one
  mailbox's revoked grant while the other stays usable, and removal of one mailbox
  on one device reaching another Trusted Device, with Gmail unchanged.

Do not record mailbox content, addresses or tokens in screenshots, logs or test
artifacts. No real Gmail synchronization pass is claimed until this protected
path has actually run.
