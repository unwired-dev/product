# Pinned notice supplements

`index.json` maps exact npm/pod versions or Swift revisions to recovered notices.
The native build verifies each text's SHA-256. Immutable source URLs and embedded
component revisions remain in the index. Files preserve the supplied notice text;
Hermes source-comment extracts identify their source hash and extraction.

Use these together with installed source-map packages, CocoaPods acknowledgement
`FooterText`, local package licences and Swift checkout notices. A root notice
cannot replace embedded vendor terms. Known BoringSSL and Hermes collections need
an exact reviewed vendor supplement when their versions change.

ReactCodegen's generated podspec declares Unlicense. Its supplement reproduces
that canonical body from a pinned SPDX source, and separately preserves Meta's
MIT template attribution. The standard-navigation candidate describes its actual
MIT declaration and author metadata without inventing a copyright holder or
year. It remains unresolved pending attribution review; it is not a recovered
publisher notice. The publisher request has been prepared but not sent.

Some ReactNativeDependencies records carry an explicit component-version
limitation. They remain unresolved until the selected build's component versions
match. Neither text coverage nor an empty unresolved list establishes licence
compatibility, binary composition, export classification or legal clearance.

See [the release record](../../docs/compliance/archive-review-2026-11-15.md).
