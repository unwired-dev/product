---
status: accepted
---

# Sanitize message HTML before isolated WebKit rendering

## Amendment — 2026-10-06

The product owner approved these changes during
[#605](https://github.com/unwired-dev/product/issues/605) review round 3:

- An explicit message open resolves every visible, sanitized `cid:` reference
  within the existing attempted-image, admitted-image-count, per-image and
  aggregate byte, axis and decoded-pixel limits and the shared presentation
  budget. Inline Images are not viewport-scoped. Sanitizer visibility excludes
  hidden or non-rendering references; it does not require geometric proximity to
  the viewport. Missing or refused parts remain non-loading placeholders, and
  speculative recent-body prefetch still never loads Inline Images.
- Both the UIKit and AppKit hosts may measure the laid-out document after
  navigation finishes with an application-owned `callAsyncJavaScript` script in
  `WKContentWorld.defaultClientWorld`. Page JavaScript remains disabled through
  `allowsContentJavaScript = false`; message content cannot supply the script or
  use an application bridge. This supersedes the native-scroll-content-size-only
  measurement clause below. Invalid measurement or rendering failure uses the
  retained readable-text fallback.

These are accepted choices, not temporary implementation exceptions. Bounded
all-reference CID resolution avoids a viewport-position admission protocol;
isolated client-world measurement supplies the same layout boundary on both
hosts without enabling sender scripts. All other sanitization, isolation,
navigation, cache and resource constraints remain applicable.

Remote Message Content is unchanged: its consent, policy and isolated retrieval
requirements belong to [#763](https://github.com/unwired-dev/product/issues/763),
including the viewport or one-viewport-margin rule for Always Load. This amendment
does not authorize remote loading in #605. The following text preserves the prior
decision; only the clauses explicitly superseded here have changed.

## Sanitizer readability correction — 2026-10-06

The issue-605 tiny-font and layout feedback revealed a mismatch between retained
CSS and inspected text. This correction supersedes the prior paragraph's
font-size and negative-offset classification clauses. It preserves the isolated
renderer, consent, navigation, image bounds and fallback requirements.

Use a conservative 4-CSS-pixel legibility cutoff; tiny text may still paint a
smear. Normalize sender font sizes around that cutoff while preserving Dynamic
Type body text and ordinary relative scaling. Pin the root size for `rem` and
discard sender font-metric/viewport size units rather than guessing their value.
Placeholder descriptions use their emitted font size, including restoration and
hidden-size inheritance, rather than discarded source-image styling.

Normalize large negative leading margins and indents to zero rather than omit
text solely on offset magnitude: padding and wrapped lines can leave labels
painted. Normalize negative percentage, viewport and font-metric offsets whose
basis is unavailable here. Preserve ordinary small hanging indents, trailing
LTR margins, inner-table margins and emitted declaration order. Automatic
direction remains removed. This is a bounded style normalization policy, not a
complete geometric visibility model.

### Positive spacing correction — 2026-10-06

The issue-605 positive-offset feedback showed that retained masking text could
paint beyond the reader while still suppressing link inspection. Extend the
320-CSS-pixel normalization threshold to positive leading margins and indents.
Remove oversized padding, border-width and table border-spacing declarations on
every side; reset large letter-spacing and vertical-align offsets and normalize
oversized line heights. These changes can reduce deliberate large layout gaps;
the bound is a readability policy, not a geometric visibility classification.
Keep ordinary small spacing and the existing margin applicability exceptions.

Unresolved sender CSS functions are outside the retained style subset. Remove
any declaration containing an unresolved function outside quoted strings, rather than
guessing its geometry or omitting scroll-accessible text from inspection.
Plain `rgb`/`rgba` and `hsl`/`hsla` color functions contain no geometry and remain
allowed in border shorthands; nested functions and other unresolved functions
are removed. This deliberately drops newer color functions such as `hwb`, `lab`,
`lch`, `oklab`, `oklch`, `color` and `color-mix`; preserving those decorations is
outside the conservative subset. The same literal border-width bound applies
when a color function and dimension have no intervening whitespace, because the
closing parenthesis separates CSS tokens. Quoted font names containing parentheses remain allowed, and
reader-generated sizing functions remain outside the sender filter. The bound
still does not classify all viewport visibility: meaningful content with retained
`white-space:nowrap` and multiple ordinary small spacing values can overflow.

The vertical-sizing correction also removes literal heights and minimum heights
of at least 320 CSS pixels after unit resolution, with percentages resolved
against the same 320-pixel basis. Reset large bottom margins of either sign,
retaining the inner-table margin exception. Remove oversized table-cell HTML
height hints as well, so dropping CSS cannot reactivate a larger hint. Image
HTML height hints remain subject to the reader's `height:auto`; removed CSS
heights fall back to that rule. This can reduce deliberate hero-cell and banner
heights or restore intrinsic proportions where a sender stretched an image.
Hidden source-less image geometry follows these same emitted sizing bounds.

Bound oversized literal widths and minimum widths by the containing block rather
than discarding ordinary desktop email widths. An aligned inline-block can
otherwise paint its inspected label entirely beyond the right edge. Preserve the
source width where the containing block has enough room. This correction changes
only emitted styling, leaving inspected text, network isolation, consent and
resource limits under the existing rendering policy.

## Link and spacer bounds — 2026-10-06

Issue #605 review round 26 closes native-control amplification and repeated
spacer masking. Rich anchors, detected plain-text links and finalized readable
fallback href spans each have a 200-link limit per message. Later destinations
remain readable plain text, without active markers or link semantics; a new
budget exception must not discard HTML-only content. Counting collected anchors
alone is insufficient because one anchor can cross many fallback paragraphs.

Retain at most four consecutive `br`, `hr` or preserved text newlines between
readable text or visible images. Hidden and non-rendering Unicode content does
not reset that run. Within an active link, omit hidden text nodes and remove the
layout boxes of hidden images and containers with no readable text or visible images, retaining
descendants and inherited styles. Outside links, hidden source-less image geometry
remains unchanged. This narrows the ordinary-small-spacing
exception for empty linked wrappers: individually small padding, margins or
heights can otherwise accumulate into a displaced suffix. Real content,
visibility restoration and ordinary breaks remain intact. Inspect the complete
normalized label; revealing a previously displaced non-address suffix can
legitimately leave no mismatch warning. These bounds do not establish complete
viewport visibility or a general total-node/output-size budget.

### Spacer height correction — review round 27

The four-break count alone still allowed a retained 200-pixel line height to put
the inspected suffix below the viewport. Apply a conservative 160-CSS-pixel
allowance alongside the count. Track inherited line-height factors separately
from computed lengths, and charge at least the largest active ancestor line:
an inline child's smaller font or line height cannot shrink the parent's strut.
The system-font `normal` estimate is 1.2 times the font size; the reader body's
1.5 line strut remains a floor while it is an ancestor.
Discard sender line-height expressions and font-metric/viewport units before
rendering, since a retained value outside this model could still enlarge a run
while accounting substitutes its parent line height.
Carry whether the retained font family is the system font through traversal.
An arbitrary sender family can make `normal` much taller than 1.2, so represent
that state as unknown and grant no spacer breaks under it. Preserve the chosen
font and readable text; explicit factors and lengths remain modeled. This
conservative policy can collapse intentional spacing in such mail.

Normalize rule vertical geometry to zero height/minimum/maximum height and
vertical padding, half-em vertical margins and one-pixel vertical borders, with
overrides emitted after sender shorthands. Charge a rule for both its ordinary
box and the preceding line. Horizontal styling and divider semantics remain.
These conservative bounds can remove intended blank lines in large headings
and reduce thick or padded dividers. Ordinary body spacing remains. A single
oversized or wrapped text line and arbitrary meaningful layout remain outside
this bounded-spacer policy; this does not claim exact font metrics or complete
viewport visibility.

## Prior decision

Remote-image normalization treats an empty URL path as `/` before deduplication, CSS `height` and `max-height` symmetrically identify declared tracking pixels, inline CSS dimensions override matching HTML attributes during that classification, and permanently unloadable non-HTTPS image sources are not retained as consent or retry references.

Image-only remote messages retain their consent control when sibling preheader text is removed by
the sanitizer's hidden, visibility, opacity, zero-size, or off-canvas rules.

Retained message HTML is untrusted input. The Apple client will sanitize it on device with [SwiftSoup](https://github.com/scinfu/SwiftSoup) before passing it to WebKit. The Xcode package lock pins the reviewed 2.13.7 release. The sanitizer owns explicit allowlists for common text and table-based email elements, their attributes, the `http`, `https`, `mailto`, and `tel` link schemes, `cid:` image references, and a conservative set of inline CSS properties. It removes active elements, event handlers, forms, frames, embedded objects, metadata refreshes, unsafe URL schemes, CSS URL values, remote image sources, and author-defined foreground and background colors. Sanitized HTTPS image references become opaque local markers, with their URLs retained outside the WebKit document for an explicit presentation-scoped load. HTTP and other non-HTTPS image sources are removed and never retained for consent-scoped loading. Normalizing both colors onto the document's fixed light canvas prevents stripped background images or legacy background attributes from leaving unreadable text. Sanitization never mutates the retained encrypted source body.

Sanitized HTML renders in a shared `WKWebView` boundary used by every adaptive conversation-reader presentation. Page JavaScript is disabled, website data storage is non-persistent, and the generated document supplies a content security policy whose default, media, font, connection, frame, and object sources are `none`; the image source allows only local `data:` values assembled after sanitization. Inline CSS remains enabled only because the sanitizer filters both property names and values before WebKit receives them. On a Gmail body load initiated by an explicit open or visible-thread prefetch, the provider body reader URI-decodes sanitized HTML CID references while preserving MIME Content-ID header literals, fetches only matching inline parts from the recursively selected MIME alternative, its nearest enclosing related scope, or explicitly inline siblings in an enclosing mixed scope, and admits only visible, single-frame, signature-valid PNG, JPEG, GIF, or WebP data within per-image, admitted-image-count, total-size, attempted-image, pixel-dimension, and decoded-pixel-cost bounds. Content-ID matching ignores surrounding RFC-style comments and folding whitespace. Boolean-hidden, zero-width, zero-height, CSS max-width-zero, visibility-hidden, and non-positive numeric or percentage opacity image elements are excluded before those bounds are applied. During body decoding, ordinary HTML that cannot reference a CID skips the CID-discovery sanitizer pass; presentation still sanitizes it before WebKit. The selected alternative has highest CID precedence, followed by the nearest related scope and then outer scopes. Attachment-disposition, filename-bearing attachment, and `message/rfc822` containers are not traversed, while an inline image leaf may retain a filename; disposition matching skips leading RFC-style comments and folding whitespace, uses the header's leading token, and ignores following comments and filename parameters. Missing, malformed, oversized, unsupported, sanitized-away, and unreferenced parts stay non-loading placeholders without preventing the readable message from rendering. A cancelled explicit refresh propagates cancellation instead of returning cached HTML with unresolved CIDs. Background Gmail body prefetch checks body-free Content-Type metadata and fetches only single-part plain-text or HTML messages; multipart messages remain fail-closed in that workflow so they neither request nor receive inline resources. A completed provider body load stores admitted inline-image data and its trusted resolution state in the device-local bounded encrypted body cache, allowing later opens to remain cache-only; legacy entries without that state are revalidated from their sanitized CID references. Presentation replaces matched CID sources with local data only in memory, preserves one 20 MB aggregate encoded-image-byte budget that charges every resolved occurrence remaining in sanitized presentation HTML and one 32 Mi-pixel decoded-image budget across all simultaneously expanded messages, and releases each presentation reservation with its expanded message view, during cancelled preparation, when explicit cache removal signals every displayed body to discard its presentation or fallback text, or immediately when WebKit rendering fails and the reader discards the HTML presentation.

The reader commits one visual representation per body load. It keeps the stable message placeholder visible until sanitization, styling, and the initial WebKit document are ready, then reveals that styled presentation once; it never exposes cached plain text as an interim representation before swapping to HTML. Authorized remote images update inside the existing document without reloading the WebKit navigation or resetting its typography and scroll state. Plain text appears only as the terminal fallback when the HTML source is absent, sanitization fails, or WebKit cannot render the document.

The visible-image boundary also rejects non-rendering `display: contents` image elements and descendants of collapsed table tracks. Percentage tracking-pixel dimensions resolve through auto-width normal-flow blocks constrained by an explicit containing block. Negative image margins remain loadable when a known containing padding offsets them back into the viewport.

This revision supersedes the earlier rule that blocked every remote resource unconditionally. The accepted consequence is that explicit fetch consent reveals the device's IP address and the message-open time to the referenced host; without consent or an eligible encrypted-cache hit, no remote-image request leaves the device. Remote image markers produce a reader notice when sanitized readable HTML retains at least one reference or when the source body contains only retained remote images. Zero-dimension and explicitly declared 1×1 remote images are excluded as known tracking pixels whether their dimensions use HTML attributes, inline CSS width or max-width, or a mixture of attributes and CSS. Zero-sized containers retain descendants because the sanitized CSS boundary does not admit clipping declarations, so WebKit's default visible overflow can still paint them. Repeated occurrences of request-equivalent URLs share one marker identity so a consent action requests that resource only once; URL schemes and hosts are lowercased, default ports and fragments are removed before this deduplication. The notice explains that loading can reveal the device's IP address and that the message was opened. Explicit consent creates an isolated, ephemeral, cookie-free, credential-free, non-caching HTTPS request path with a 30-second aggregate load deadline that admits at most three HTTPS redirect hops per image and signature-valid single-frame PNG, JPEG, GIF, or WebP responses within the same per-image, admitted-image-count, total-size, attempted-image, pixel-dimension, and decoded-pixel-cost bounds used for inline images. Every received response byte counts against the transfer limit, including rejected responses. Remote images participate in the shared retained-image byte and pixel ledger across all expanded messages and any admitted CID images; repeated marker expansions are charged once per occurrence, and the attempted-image bound applies after unloadable URLs are filtered and only when enough transfer and pixel budget remains to issue a request. Authorization, Cookie, and Referer headers are absent from initial and redirected requests; non-TLS, authenticated-URL, oversized, unsupported, malformed, and unsuccessful responses stay as non-loading placeholders. Successful responses become local `data:` sources before WebKit sees them and enter the Authorized Remote Content Cache. Partial failures remain visible without replacing readable content, and retry attempts preserve both the loaded results and their shared-ledger reservations, rotate failed attempt batches behind unattempted references, and request only the unresolved references. Cancellation stops the transfer. Ending a message presentation releases only its in-memory byte and pixel reservations; the encrypted cache entry remains until eviction or manual removal.

Before every initial or redirected request, the client resolves the original HTTPS hostname once and rejects the destination unless every returned IPv4 or IPv6 address is globally reachable unicast space. Literal and resolved loopback, link-local, private, carrier-grade NAT, documentation, benchmark, multicast, unspecified, transition, and other non-public special-use addresses fail closed; an empty answer also fails closed. The client then opens a Network.framework TCP/TLS connection to one address from that validated answer set, advertises only HTTP/1.1, and sets the TLS server name to the original URL host. The system trust evaluator therefore continues to validate both the certificate chain and original hostname while the socket never performs a second hostname lookup, closing the DNS-rebinding interval. Redirect locations repeat the complete URL, DNS, address, and pinned-connection validation independently before their request is sent.

This direct pinned transport intentionally does not fall back to `URLSession`, hostname-based reconnection, or a newly resolved address. Remote images therefore remain placeholders when a hostname has mixed public and non-public answers, uses private or special-purpose addressing, requires an HTTP proxy, exposes only an HTTP/2 endpoint, or cannot complete a direct TLS 1.2-or-newer HTTP/1.1 connection. That compatibility cost is accepted because any fallback that reconnects by hostname would reopen the private-network and DNS-rebinding boundary.

The reader resolves a device-local Remote Message Content policy before invoking that same boundary. Ask remains the default and grants consent for one remote fetch plus encrypted device-local reuse by that message, Never omits the load action, and Always Load starts the bounded isolated load automatically. Under Always Load, sanitized remote images begin only when their message reaches the reader viewport or its one-viewport prefetch margin. Successful non-tracking remote results enter the Authorized Remote Content Cache and can be handed to later presentations without another network request, including after an app relaunch; Ask and Never never perform remote prefetch. A device-local per-Mailbox Connection override takes precedence over the global choice. Changing the effective policy to Never hides retained remote content immediately but does not delete it; restoring an eligible policy can reuse those encrypted bytes without a new request. Ending a presentation releases only its in-memory byte and pixel reservations, not the encrypted cache entry. Manual remote-content removal and normal bounded eviction delete the retained bytes. No policy or cache entry can re-admit a known Tracking Pixel or bypass the sanitizer, request isolation, redirect, cancellation, or resource bounds above, and a cache entry never authorizes a new network request.

An enclosing mixed scope also admits a filename-less CID image sibling with no disposition header, because the disposition is optional; explicit attachments and filename-only siblings remain excluded.

The navigation delegate cancels all message-originated navigation. Plain-text URL detection and user-activated sanitized HTML links use one device-local opener; automatic navigation and unsupported schemes remain blocked. Sanitization retains each visible anchor's text beside its allowed destination only in the in-memory presentation. Before system handoff, the opener compares URL-like displayed text with the destination and evaluates reviewed scheme mismatch, internationalized or numeric host, embedded credential, bidirectional-control, and cross-site redirect-query signals. A flagged link shows its exact destination and concise reasons with Cancel, Copy Link, and Proceed actions; the user may always proceed, and an unflagged link is never presented as safe. The check performs no reputation lookup, network request, persistence, logging, Product Sync, or backend call. Copy and open revalidate the current Trusted Device and Profile Lock boundary immediately before revealing the destination outside the reader. The exact destination is handed to the platform, whose later redirect behavior remains outside this detector. The web view observes its scroll content size instead of executing JavaScript to measure layout. An uncapped message stays pinned to the top of its embedded WebKit scroll view so horizontal overflow cannot introduce nested vertical scrolling inside the conversation reader; only a document taller than the presentation cap scrolls vertically inside WebKit. Readability ignores hidden, zero-sized and off-canvas preheader text, as well as content composed only of non-rendering Unicode format or combining characters. Margin classification follows emitted shorthand and longhand order; trailing margins and ignored inline or inner-table margins cannot suppress a painted label. Large negative horizontal margins in bidi contexts and top margins on inline-blocks or inline images are normalized to zero in the emitted document rather than used to guess glyph displacement. Automatic direction is removed so the document inherits explicit direction. Text-indent is inherited through inline elements but applies to their containing block's line: only a block-container reset can restore that line's readable text. That readability-only filtering does not remove ordinary negative-offset layout content or CID images from zero-line-height or zero-font-size presentation wrappers. Background sanitization checks cancellation between its full-document cleaning and parsing passes. A missing HTML alternative, empty sanitized result, sanitizer error, WebKit load failure, or terminated WebKit content process falls back to the retained readable plain text.

This boundary uses UIKit-backed `WKWebView` integration available on the supported iOS 17 and Mac Catalyst 14 targets and does not depend on the OS 26 SwiftUI WebView API.
