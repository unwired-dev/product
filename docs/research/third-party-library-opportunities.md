# Third-party library opportunities

Research date: 2026-10-10. This note ranks candidate libraries. It is not an
implementation, a dependency change, or a change to release scope. Versions,
licences and release dates were read from the npm registry (`npm view`) on the
research date. Bundle sizes and decoding results come from probes run under
Node 24 with esbuild, not from Hermes or a packaged app.

## Recommendation

Most of the stack is already covered. Effect 4 supplies schemas, Base64Url,
scheduling and errors; Expo 57 and React Native 0.86 supply navigation,
background tasks, gestures and animation; parse5 parses HTML. Native Swift
modules handle storage, keys and Gmail transport. Only a few needs are still
hand-rolled, and the strongest picks are small, pure-JavaScript libraries. On
the Mac host they need no change to the native-dependency allowlist
(`docs/macos-client.md:32-36`).

| Rank | Library                                                                  | Need                                                 | Verdict          |
| ---- | ------------------------------------------------------------------------ | ---------------------------------------------------- | ---------------- |
| 1    | `postal-mime` `addressParser`                                            | From-header parsing on Hermes (#775)                 | **Adopt**        |
| 2    | `@exodus/bytes`                                                          | Legacy message charsets (Czech, CJK)                 | **Adopt**        |
| 3    | `jose`                                                                   | Hand-rolled JWT signing and verification in Convex   | **Adopt**        |
| 4    | `@legendapp/list`                                                        | Catch Up's chat-style feed (#807, #810, #813)        | **Trial**        |
| 5    | `@csstools/css-tokenizer` and `css-parser-algorithms`                    | Hand-rolled CSS declaration parsing in the sanitizer | **Trial**        |
| 6    | `react-native-gesture-handler` `ReanimatedSwipeable` (already installed) | Catch Up swipe-to-reply on mobile (#811)             | **Use existing** |

Tracking issues: #775 (`postal-mime`), #838 (`@exodus/bytes`), #839 (`jose`),
#840 (`@legendapp/list`) and #841 (`@csstools`).

## Recommendation disposition, 2026-10-19

The rankings and probes below remain the 2026-10-10 assessment. Follow the
owning implementation issue and current feature contract for later decisions
and evidence:

| Recommendation                | Disposition owner                                                                                                           |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `postal-mime` From parsing    | [#775](https://github.com/unwired-dev/product/issues/775), [Gmail behavior](../gmail-inbox.md#behavior)                     |
| `@exodus/bytes` charsets      | [#838](https://github.com/unwired-dev/product/issues/838), [message reading](../gmail-inbox.md#reading-messages)            |
| `jose` token operations       | [#839](https://github.com/unwired-dev/product/issues/839)                                                                   |
| Legend List trial             | [#840](https://github.com/unwired-dev/product/issues/840), [Catch Up](../catch-up.md)                                       |
| CSS parser trial              | [#841](https://github.com/unwired-dev/product/issues/841), [sanitization contract](../gmail-inbox.md#sanitization-contract) |
| Existing mobile swipe actions | [#811](https://github.com/unwired-dev/product/issues/811), [Catch Up](../catch-up.md)                                       |

The current [mail-core manifest](../../packages/mail-core/package.json) lists
`postal-mime`, `@exodus/bytes` and the CSS parser libraries as runtime
dependencies; the [Convex manifest](../../packages/convex/package.json) lists
`jose`. These entries establish dependency availability only. They do not prove
complete migration, the Legend List trial, deployed compatibility or native
qualification. Keep the limitations of each dated probe distinct from later
implementation evidence.

## 1. `postal-mime` `addressParser`: parse From headers correctly on Hermes

**Problem.** `sender` in `packages/mail-core/src/gmail-inbox.ts:549-556` parses
the From header with one regex and reads `match.groups`. Hermes can leave
`groups` unset, so the whole header becomes both the name and the address
([#775](https://github.com/unwired-dev/product/issues/775)). The regex also cannot
handle quoted names that contain `<`, comments, or groups. Draft recipients use a
second hand-written scanner in `packages/mail-core/src/drafts.ts:108-168`.

**Library.** `postal-mime` 4.0.5, MIT-0, released 2026-10-07. It exports
`addressParser(str, { flatten })` and `decodeWords` next to the MIME parser
([README](https://github.com/postalsys/postal-mime#addressparser)). In 4.0.1 it
ported Nodemailer's address-parser fixes: quoted encoded words, domain literals,
and display names that hold encoded words
([changelog](https://github.com/postalsys/postal-mime/blob/master/CHANGELOG.md)).
The package is **already in the lockfile**: it is a `mail-core` devDependency
(`packages/mail-core/package.json`) and serves as the parsing oracle in
`packages/mail-core/test/outgoing-message.test.ts:1`.

**Compatibility.** It is pure ESM with no dependencies. `address-parser.ts`
contains no named capture groups (grep count 0), so the Hermes `groups` problem
does not apply. One constraint: `mime-node.ts:36` creates
`new TextDecoder('utf-8', { ignoreBOM: true })` when the module loads. Mobile has
a UTF-8 `TextDecoder`
([Expo 57 globals](https://docs.expo.dev/versions/v57.0.0/sdk/expo/)). The Mac
host loads `fast-text-encoding` before anything else (`apps/macos/index.js:1`),
which covers that call. If #2 is adopted, that polyfill must still load before
`mail-core`. Metro does not tree-shake by default, so importing the package
entry bundles the whole parser: about 26 KB gzipped. The address parser alone,
tree-shaken, is about 5 KB.

**Cost and risk.** Low. Move the package from `devDependencies` to
`dependencies`, then replace `sender` with
`addressParser(from, { flatten: true })[0]`. Gmail returns header values already
decoded, but `decodeWords` is harmless. Keep the Draft input scanner for now.
It deliberately accepts `;` and line breaks that header syntax does not, so
replace it only if tests show identical behaviour.

**Alternatives.** Positional captures, as #775 proposes, are the minimal fix but
keep a regex that is not RFC 5322. `email-addresses` was not assessed further
because a vetted parser is already installed.

## 2. `@exodus/bytes`: decode legacy message charsets

**Problem.** `decodeText` (`packages/mail-core/src/message-body.ts:617-666`)
decodes only UTF-8 and Western single-byte charsets correctly. For any other
label it calls the host `TextDecoder`, which accepts only UTF-8 on native Expo:
"The `TextDecoder` API is not spec-compliant on native platforms. Only the UTF-8
encoding is supported"
([Expo 57](https://docs.expo.dev/versions/v57.0.0/sdk/expo/)). It then falls back
to UTF-8 and produces mojibake. The repo records this as a known limit
(`docs/gmail-inbox.md:275-276`), and the tests model a UTF-8-only host
(`packages/mail-core/test/message-body.test.ts:68-175`). Czech is a target
language (#828, #829), and Czech mail is still sent as `windows-1250` or
`iso-8859-2`. Japanese, Chinese and Russian legacy mail (`shift_jis`,
`iso-2022-jp`, `gbk`, `koi8-r`) is affected the same way. The Mac host carries
a separate UTF-8-only polyfill, `fast-text-encoding` 1.0.6. Its last release was
in 2022 (`docs/macos-client.md:28-30`).

**Library.** `@exodus/bytes` 1.16.0, MIT, released 2026-09-22, with regular
releases through 2026. It is a WHATWG Encoding `TextDecoder` that "passes WPT",
with first-class Hermes and React Native notes
([README](https://github.com/ExodusOSS/bytes#textencoder--textdecoder-polyfill)).
`whatwg-encoding` is now deprecated with the message "Use @exodus/bytes instead"
(npm registry). Its one peer dependency, `@noble/hashes`, is optional.

**Compatibility evidence (probe).** The probe bundled the library with esbuild
and ran it under Node 24 with `TextDecoder`, `TextEncoder` and `Buffer` removed.
It decoded `windows-1250` (`žluťoučký`), `gbk` and `shift_jis` correctly.
Size, minified and gzipped:

- `@exodus/bytes/encoding-lite.js` is about 9 KB. It covers UTF-8, UTF-16 and
  every single-byte WHATWG encoding, which includes all the Czech encodings.
- `@exodus/bytes/encoding.js` is about 94 KB. It adds the CJK multi-byte tables.

The package ships `react-native` field overrides (`package.json`). These were not
exercised in a Hermes build.

**Cost and risk.** Low to medium. In `decodeText`, import the decoder explicitly
for labels outside UTF-8 and do not install it as a global. That keeps the Effect
and Hermes UTF-8 path unchanged. Start with `encoding-lite.js` and decide on CJK
size separately. The same import could later replace `fast-text-encoding` on the
Mac. Packaged Hermes behaviour is still unverified, and `docs/gmail-inbox.md`
must be updated.

**Alternatives.** `iconv-lite` 0.7.3 needs a `Buffer` (it depends on
`safer-buffer`), and its README positions it for Node. `text-encoding`, which the
Expo docs suggest, is marked "no longer maintained" on npm. `whatwg-encoding` is
deprecated. JSI decoders such as `react-native-fast-encoder` support UTF-8 only
([repo](https://github.com/maksimlya/react-native-fast-encoder)), and native
modules would need a Mac allowlist change.

## 3. `jose`: replace hand-rolled JWT signing and verification in Convex

**Problem.** Convex builds and checks JWTs by hand in three places:

- `packages/convex/convex/apns.ts:178-197` signs the ES256 APNs provider token.
- `packages/convex/convex/productAccountDeletion.ts:200-226` signs the Apple
  client secret. Lines 271-360 verify Apple identity tokens against
  `appleid.apple.com/auth/keys`.
- `packages/convex/convex/pushRelay.ts:90-340` fetches and caches Google's JWKS,
  then verifies RS256 Pub/Sub tokens with `crypto.subtle`.

Header and `alg` checks, segment decoding, claim timing and key selection are all
security-critical. Each is reimplemented in every file.

**Library.** `jose` 6.2.12, MIT, released 2026-09-05 (frequent patch releases),
with zero dependencies. It provides `SignJWT`, `jwtVerify`, `importPKCS8`,
`createLocalJWKSet` and `createRemoteJWKSet`. It runs on Web Crypto and Fetch
([repo](https://github.com/panva/jose)).

**Compatibility.** The default Convex runtime supports `crypto`/`SubtleCrypto`
and "most npm libraries that work in the browser, Deno, and Cloudflare workers".
`fetch` is available in actions only
([Convex runtimes](https://docs.convex.dev/functions/runtimes)). `pushRelay.ts`
runs in the default runtime. `apns.ts` and `productAccountDeletion.ts` are
`'use node'`, where jose's Node build applies. The jose README does not list
Convex by name. `pushRelay.ts:295-305` caches Google's keys per isolate
(`cachedGoogleSigningKeys`) until their HTTP cache lifetime ends. Keep that
cache, which honours `Cache-Control`, and pass its keys to `createLocalJWKSet`.
A persistent cache would be new work to scope and test separately.

**Cost and risk.** Medium. The code works and is covered by the Convex tests, so
migrate one site at a time and keep the existing negative tests. The gain is less
bespoke crypto, not a new feature. Adopt it, starting with the APNs signer; it
has the smallest blast radius.

**Alternatives.** `jsonwebtoken` requires Node crypto and so cannot run in
`pushRelay.ts`. Convex's built-in `auth.config.ts` providers already verify
sign-in tokens for queries, but they do not cover Pub/Sub push tokens, outbound
signing, or the explicit Apple check at deletion time.

## 4. `@legendapp/list`: list for the Catch Up feed

**Problem.** Catch Up is a chat-style feed with the newest message at the bottom.
It opens at an unread divider, marks items seen as they scroll past, and expands
collapsed bubbles inline (`docs/catch-up.md:24-53`;
[#807](https://github.com/unwired-dev/product/issues/807),
[#810](https://github.com/unwired-dev/product/issues/810),
[#813](https://github.com/unwired-dev/product/issues/813)). Today both hosts use
React Native `SectionList` (`apps/mobile/src/inbox.tsx:785`,
`apps/macos/src/inbox.tsx:800`). Bottom anchoring plus keeping the visible
position stable while items insert or expand are known weak spots of
`VirtualizedList`.

**Library.** `@legendapp/list` 3.6.0, MIT, released 2026-09-29 with several
releases a month. Its only dependency is `use-sync-external-store`. It needs "no
native module linking" ([repo](https://github.com/LegendApp/legend-list)). The
shipped types include `alignItemsAtEnd`, `initialScrollAtEnd`,
`initialScrollIndex`, `maintainScrollAtEnd`, `maintainVisibleContentPosition`,
`onStartReached`, `onViewableItemsChanged` and `stickyHeaderIndices`. There is
also a `section-list` entry point (package `react-native.d.ts`).

**Compatibility.** As pure JS with only a `react: *` peer, it adds nothing to
either host's native graph. It reads `global.nativeFabricUIManager`
(`react-native.mjs:377`) and branches only on `web` and `android`. **macOS is not
documented.** The Mac host runs React Native macOS 0.81.9 with Fabric
(`apps/macos/macos/Podfile:4`), but behaviour on that host is unverified.

**Cost and risk.** Medium. Trial it in the Catch Up feed only, on both hosts,
before touching the Inbox list. Measure scroll-to-divider accuracy, viewability
callbacks and expansion jumps against `FlatList` with `inverted` or
`maintainVisibleContentPosition`.

**Alternatives.** `@shopify/flash-list` 2.3.3 (MIT, active) is "built for RN's new
architecture" ([docs](https://shopify.github.io/flash-list/docs/)), but this
research did not establish its chat features or macOS behaviour. Built-in
`FlatList` costs nothing and is the baseline.

## 5. `@csstools/css-tokenizer` and `css-parser-algorithms`: spec CSS parsing in the sanitizer

**Problem.** `packages/mail-core/src/html-sanitizer.ts` has a hand-written CSS
declaration scanner in roughly lines 358-1110: `scanQuoted`, `splitDeclarations`,
`unescapeCSS`, `withoutCSSComments`, `readValue`, `readDeclaration` and
`parseDeclarations`. Its own comments say it tries to match what "WebKit would
reject" (line 1036). Any drift between this scanner and WebKit's CSS Syntax
parser is a parser-differential risk at the security boundary for sender HTML.

**Library.** `@csstools/css-tokenizer` and `@csstools/css-parser-algorithms` 4.0.2,
both MIT and released 2026-09-25/10-01, with no runtime dependencies. They are
implemented from [CSS Syntax Level 3](https://drafts.csswg.org/css-syntax/) and
are forgiving on parse errors
([tokenizer](https://github.com/csstools/postcss-plugins/tree/main/packages/css-tokenizer)).
Together they are about 70 KB unminified. They are pure ESM and need only Node
≥20.19 for tooling.

**Cost and risk.** Medium to high, because this is a security boundary. Replace
only the tokenizing and declaration splitting, and keep every admission and
normalization rule. Before switching, run both parsers over the existing
sanitizer fixtures plus adversarial CSS (escapes, comments, unterminated
strings, `;` and `}` inside strings and URLs). Use WebKit as the oracle: parse
each input through `CSSStyleDeclaration` in a WebKit engine, such as Playwright
WebKit or the host WebView. Adopt only if every divergence matches WebKit.
Otherwise, keep the current code.

**Alternatives.** `css-tree` 3.2.1 is larger (it depends on `mdn-data`) and its
last release was in March 2026. PostCSS targets Node and is not
spec-tokenizer-first.

## 6. Already installed: swipe actions on mobile

Catch Up's swipe-right quick reply (`docs/catch-up.md:49`,
[#811](https://github.com/unwired-dev/product/issues/811)) needs no new library on
mobile. `react-native-gesture-handler` 2.32.0 and Reanimated 4.5.1 are already in
the `mobile` catalog, though no `apps/mobile/src` file imports them yet.
`react-native-gesture-handler/ReanimatedSwipeable` is a drop-in Reanimated
swipeable row
([docs](https://docs.swmansion.com/react-native-gesture-handler/docs/components/reanimated_swipeable)).
Gesture Handler 2.32 supports React Native 0.84 and newer, and version 3 needs
0.82 ([README](https://github.com/software-mansion/react-native-gesture-handler)).
Keep the version that Expo pins rather than upgrading to 3.3.0 independently. The
Mac host has neither library, and the gesture-handler README does not claim
macOS support. On the Mac, provide the action through pointer, keyboard and
context menu, as `docs/product/organization.md:56` already requires.

## Considered and rejected

- **DOMPurify or sanitize-html** in place of the sanitizer. DOMPurify needs a DOM,
  which Hermes lacks. sanitize-html brings htmlparser2 and PostCSS, which target
  Node. Neither does the layout normalization or CID and tracking-pixel handling
  this sanitizer does on top of parse5.
- **`mimetext` or Nodemailer's MailComposer** for `outgoing-message.ts`.
  `mimetext` 3.0.28 brings `@babel/runtime-corejs3`, `js-base64` and
  `mime-types`, and its last release was in January 2026. MailComposer needs Node
  streams. The current 372-line builder is already checked against
  `postal-mime`.
- **`image-size`** for `inline-images.ts`. It reads dimensions, but the local code
  also validates structure (PNG CRCs and end markers), which is part of
  admission.
- **`minisearch` or `fuse.js`** for saved-mail search. Search covers sender and
  subject over the newest 200 Inbox messages per mailbox (`docs/gmail-inbox.md:60-84`).
  A linear accent-folding filter is enough at that size.
- **`text-encoding`, `whatwg-encoding`, `iconv-lite`.** These are unmaintained,
  deprecated or Node-oriented (see #2).
- **`zeego` for context menus.** Its last release was in March 2025, and it pins
  three native peer packages, which conflicts with the Mac native allowlist.
  Evaluate `@expo/ui` (already resolved through Expo 57) on mobile first.
- **Maestro or Detox.** The project already runs XCUITest suites on both hosts
  (`apps/*/native-tests`), and Expo's Maestro workflow does not cover macOS
  (`docs/research/expo-react-native-rewrite.md`).
- **`expo-sqlite` (SQLCipher), MMKV, Zustand, TanStack Query.** Storage is a
  native encrypted store behind TurboModules (`docs/private-inbox-storage.md`),
  and Effect owns state and async work. These would duplicate existing layers,
  and the Mac host forbids unlisted native modules.
- **Yjs or Automerge for Drafts.** The product keeps conflict copies by design
  (#821). A CRDT would change that behaviour, not just replace code.
- **On-device ML runtimes and Tiptap.** These are already covered by
  [DeBERTa v3 research](deberta-v3-email-classification.md) (#827-#831) and the
  [editor evaluations](editor-alternatives.md) (#818-#823).

## Unverified

- No candidate ran in a packaged Hermes build on iOS or macOS 27. That includes
  `@exodus/bytes`'s `react-native` field overrides and Legend List on React
  Native macOS 0.81.
- jose has not been run inside a deployed Convex action.
- The CSS differential test and the FlashList chat-feature comparison were not
  performed.
- New versions must also clear the workspace's pnpm release-age gate
  (`pnpm-workspace.yaml`).
