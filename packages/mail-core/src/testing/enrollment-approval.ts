/* oxlint-disable typescript/prefer-readonly-parameter-types -- Key and message bytes are only read. */
import { chacha20poly1305 } from '@noble/ciphers/chacha.js';
import { x25519 } from '@noble/curves/ed25519.js';
import { expand, extract, hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { concatBytes, utf8ToBytes } from '@noble/hashes/utils.js';

// Native code's length-prefixed context, so no two different contexts encode to the same bytes.
const binding = (purpose: string, parts: readonly string[]) =>
  concatBytes(
    ...['dev.unwired.product-sync.v1', purpose, ...parts].flatMap((part) => {
      const bytes = utf8ToBytes(part);
      const length = new Uint8Array(4);
      new DataView(length.buffer).setUint32(0, bytes.length);
      return [length, bytes];
    }),
  );

// RFC 9180 HPKE with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and ChaCha20-Poly1305, as CryptoKit's
// `Curve25519_SHA256_ChachaPoly` suite seals in PSK mode.
const version = utf8ToBytes('HPKE-v1');
const kem = concatBytes(utf8ToBytes('KEM'), Uint8Array.of(0x00, 0x20));
const suite = concatBytes(
  utf8ToBytes('HPKE'),
  Uint8Array.of(0x00, 0x20, 0x00, 0x01, 0x00, 0x03),
);
const none = new Uint8Array();
// oxlint-disable-next-line max-params -- RFC 9180's LabeledExtract signature.
const labeledExtract = (
  id: Uint8Array,
  salt: Uint8Array,
  label: string,
  ikm: Uint8Array,
) => extract(sha256, concatBytes(version, id, utf8ToBytes(label), ikm), salt);
// oxlint-disable-next-line max-params -- RFC 9180's LabeledExpand signature.
const labeledExpand = (
  id: Uint8Array,
  prk: Uint8Array,
  label: string,
  info: Uint8Array,
  length: number,
) =>
  expand(
    sha256,
    prk,
    concatBytes(
      Uint8Array.of(0, length),
      version,
      id,
      utf8ToBytes(label),
      info,
    ),
    length,
  );

// The Enrollment Code's digits as native code parses them: any case, without separators, with
// Crockford's look-alikes.
const digits = (code: string) =>
  code
    .toUpperCase()
    .replaceAll(/[\s-]/gu, '')
    .replaceAll('O', '0')
    .replaceAll(/[IL]/gu, '1');

// The synthetic trusted device's approval: the key ring sealed to the Pending Device's one-time
// key with the code it shows, bound as `KeyRingEnvelope.enrollment` binds it. `ephemeral` is the
// sender's one-time X25519 private key.
export function sealEnrollment(approval: {
  readonly ring: string;
  readonly keyVersion: number;
  readonly recipient: Uint8Array;
  readonly code: string;
  readonly account: string;
  readonly device: string;
  readonly deviceKey: string;
  readonly ephemeral: Uint8Array;
}) {
  const context = binding('enrollment', [
    approval.account,
    approval.device,
    approval.deviceKey,
    String(approval.keyVersion),
  ]);
  const psk = hkdf(
    sha256,
    utf8ToBytes(digits(approval.code)),
    undefined,
    binding('enrollment-code', []),
    32,
  );
  const encapsulatedKey = x25519.getPublicKey(approval.ephemeral);
  const shared = labeledExpand(
    kem,
    labeledExtract(
      kem,
      none,
      'eae_prk',
      x25519.getSharedSecret(approval.ephemeral, approval.recipient),
    ),
    'shared_secret',
    concatBytes(encapsulatedKey, approval.recipient),
    32,
  );
  const schedule = concatBytes(
    Uint8Array.of(0x01),
    labeledExtract(
      suite,
      none,
      'psk_id_hash',
      utf8ToBytes('dev.unwired.enrollment-code.v1'),
    ),
    labeledExtract(suite, none, 'info_hash', context),
  );
  const secret = labeledExtract(suite, shared, 'secret', psk);
  return {
    encapsulatedKey,
    ciphertext: chacha20poly1305(
      labeledExpand(suite, secret, 'key', schedule, 32),
      labeledExpand(suite, secret, 'base_nonce', schedule, 12),
      context,
    ).encrypt(utf8ToBytes(approval.ring)),
  };
}
