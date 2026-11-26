import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { Registration } from './registration.ts';

import { runLogged } from './diagnostics.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';
import {
  preferencePasses,
  PushedSchema,
  reportPreference,
} from './draft-sync.ts';
import { ownerOf } from './drafts.ts';

// A dot-atom local part (RFC 5322, with RFC 6531's non-ASCII letters) and a domain of letter, digit
// and hyphen labels ending in an alphabetic or IDNA top-level label: no empty, leading or trailing
// dot, no hyphen at a label's edge, and nothing a display name, list or control character adds.
const atom = String.raw`[\p{L}\p{N}!#$%&'*+/=?^_\x60{|}~-]+`;
const label = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?';
const domainPattern = `(?:${label}\\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]{0,58}[a-z0-9])`;
const plainAddress = new RegExp(
  `^${atom}(?:\\.${atom})*@${domainPattern}$`,
  'u',
);
const plainDomain = new RegExp(`^${domainPattern}$`, 'u');

// The address a Blocked Sender matches: one plain address, compared as a whole without case, as
// recipient deduplication compares them. A display name, bare domain or list is none.
export const blockedAddress = (address: string) => {
  const normalized = address.trim().toLowerCase();
  return normalized.length <= 254 && plainAddress.test(normalized)
    ? normalized
    : undefined;
};

// Printable ASCII alone, checked before case folding, which turns some other characters, such as
// the Kelvin sign, into ASCII letters.
const ascii = /^[!-~]+$/u;
// Whether `address` carries its domain in ASCII as it arrived.
const asciiDomain = (address: string) =>
  ascii.test(address.trim().slice(address.trim().lastIndexOf('@') + 1));

// The domain a Blocked Domain matches: one plain domain without case, an optional leading `@`
// dropped, written as sender addresses carry it. An internationalized name matches only in its
// ASCII (`xn--`) form, so a lookalike never matches the domain it imitates. A display name,
// address, list or single label is none.
export const blockedDomain = (domain: string) => {
  const normalized = domain.trim().toLowerCase().replace(/^@/u, '');
  return ascii.test(domain.trim()) &&
    normalized.length <= 253 &&
    plainDomain.test(normalized)
    ? normalized
    : undefined;
};

// The domain Block Domain… offers for sender `address`: the exact domain of one plain address, as
// it arrived. Nothing is inferred: a display name, list, parent domain or a domain a Blocked Domain
// cannot match offers none.
export const offeredDomain = (address: string) => {
  const normalized = blockedAddress(address);
  return normalized === undefined || !asciiDomain(address)
    ? undefined
    : blockedDomain(normalized.slice(normalized.lastIndexOf('@') + 1));
};

// The domain `domain` belongs to, which blocking `domain` leaves alone, when it is one a Blocked
// Domain can match.
export const parentDomain = (domain: string) =>
  blockedDomain(domain.slice(domain.indexOf('.') + 1));

// Whether a block of `block.domain` takes mail from normalized `address`: one at the domain, or at
// a subdomain of it when it blocks them, that it does not exempt.
const takes = (
  block: Readonly<{
    domain: string;
    subdomains: boolean;
    exempt: readonly string[];
  }>,
  address: string,
) => {
  const domain = address.slice(address.lastIndexOf('@') + 1);
  return (
    (domain === block.domain ||
      (block.subdomains && domain.endsWith(`.${block.domain}`))) &&
    !block.exempt.includes(address)
  );
};

// The exact addresses among `addresses`, such as the person's contacts, that a block of `domain`
// would take, normalized, deduplicated and sorted as `blockDomain` stores its exemptions.
export const addressesAtDomain = (
  domain: string,
  subdomains: boolean,
  addresses: readonly string[],
) =>
  Arr.sort(
    new Set(
      addresses.flatMap((address) => {
        const normalized = asciiDomain(address)
          ? blockedAddress(address)
          : undefined;
        return normalized !== undefined &&
          takes({ domain, subdomains, exempt: [] }, normalized)
          ? [normalized]
          : [];
      }),
    ),
    Order.String,
  );

// RFC 3492's Punycode parameters, for reading an `xn--` label.
const base = 36;
const tMin = 1;
const tMax = 26;
const maxCodePoint = 1_114_111;
const adapt = (delta: number, points: number, first: boolean) => {
  let scaled = first ? Math.floor(delta / 700) : Math.floor(delta / 2);
  scaled += Math.floor(scaled / points);
  let k = 0;
  while (scaled > ((base - tMin) * tMax) / 2) {
    scaled = Math.floor(scaled / (base - tMin));
    k += base;
  }
  return k + Math.floor(((base - tMin + 1) * scaled) / (scaled + 38));
};
// A Punycode digit's value: a to z are 0 to 25, 0 to 9 are 26 to 35.
const digit = (character: string) => {
  const code = character.codePointAt(0) ?? 0;
  if (code >= 97 && code <= 122) {
    return code - 97;
  }
  return code >= 48 && code <= 57 ? code - 22 : base;
};
// The Unicode form of the Punycode after a label's `xn--`, or undefined when it does not decode.
const decodeLabel = (input: string) => {
  const delimiter = Math.max(0, input.lastIndexOf('-'));
  const output = [...input]
    .slice(0, delimiter)
    .map((character) => character.codePointAt(0) ?? 0);
  let code = 128;
  let index = 0;
  let bias = 72;
  for (let at = delimiter > 0 ? delimiter + 1 : 0; at < input.length;) {
    const old = index;
    for (let k = base, weight = 1; ; k += base) {
      const value = digit(input[at] ?? '');
      at += 1;
      if (value >= base || index >= 2 ** 31) {
        return undefined;
      }
      index += value * weight;
      const threshold = Math.min(tMax, Math.max(tMin, k - bias));
      if (value < threshold) {
        break;
      }
      weight *= base - threshold;
    }
    bias = adapt(index - old, output.length + 1, old === 0);
    code += Math.floor(index / (output.length + 1));
    index %= output.length + 1;
    if (code > maxCodePoint) {
      return undefined;
    }
    output.splice(index, 0, code);
    index += 1;
  }
  return String.fromCodePoint(...output);
};

// The scripts lookalike names borrow Latin-looking letters from, by their blocks' first and last
// characters.
const lookalikeScripts = [
  { script: 'cyrillic', from: '\u0400', to: '\u052F' },
  { script: 'greek', from: '\u0370', to: '\u03FF' },
  { script: 'armenian', from: '\u0530', to: '\u058F' },
] as const;

// How Blocked Domain `domain` shows when it has an `xn--` label: its Unicode name and the first
// character outside ASCII, with that character's script when lookalikes borrow from it. None for a
// plain ASCII name or a label that does not decode.
export const shownDomain = (domain: string) => {
  if (!/(?:^|\.)xn--/u.test(domain)) {
    return undefined;
  }
  const labels = domain
    .split('.')
    .map((each) =>
      each.startsWith('xn--') ? decodeLabel(each.slice(4)) : each,
    );
  if (labels.includes(undefined)) {
    return undefined;
  }
  const shown = labels.join('.');
  const character = [...shown].find((each) => each > '\u007F');
  if (character === undefined) {
    return undefined;
  }
  return {
    shown,
    character,
    script: lookalikeScripts.find(
      ({ from, to }) => character >= from && character <= to,
    )?.script,
  };
};

// A Blocked Sender: an exact normalized address, the Mail Profile that blocks it and when, in
// milliseconds since the epoch, and how many arrivals this device moved to Trash for it since then;
// a block stored before #2141 has no count.
const AddressSchema = Schema.String.check(
  Schema.makeFilter((address) => blockedAddress(address) === address),
);
const BlockedSenderSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  address: AddressSchema,
  blockedAt: Schema.Finite,
  moved: Schema.optionalKey(Schema.Int),
});
export type BlockedSender = typeof BlockedSenderSchema.Type;

// An address a Mail Profile stopped blocking and when, kept so a device that synchronizes later
// takes the unblock rather than bringing the block back.
const UnblockedSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  address: AddressSchema,
  unblockedAt: Schema.Finite,
});
type Unblocked = typeof UnblockedSchema.Type;

// A Blocked Domain: a normalized domain a Mail Profile blocks, with every subdomain or alone, the
// exact addresses at it that the block lets through, when it was blocked and how many arrivals this
// device moved to Trash for it since then.
const DomainSchema = Schema.String.check(
  Schema.makeFilter((domain) => blockedDomain(domain) === domain),
);
const BlockedDomainSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  domain: DomainSchema,
  subdomains: Schema.Boolean,
  exempt: Schema.Array(AddressSchema),
  blockedAt: Schema.Finite,
  moved: Schema.Int,
});
export type BlockedDomain = typeof BlockedDomainSchema.Type;
const UnblockedDomainSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  domain: DomainSchema,
  unblockedAt: Schema.Finite,
});
type UnblockedDomain = typeof UnblockedDomainSchema.Type;

// One domain's latest block, with its choices, or unblock in a Profile, as Private Sync holds it.
const DomainChangeSchema = Schema.Struct({
  domain: DomainSchema,
  blocked: Schema.Boolean,
  at: Schema.Finite,
  subdomains: Schema.optionalKey(Schema.Boolean),
  exempt: Schema.optionalKey(Schema.Array(AddressSchema)),
});
type DomainChange = typeof DomainChangeSchema.Type;

// One address's latest block or unblock in a Profile and when it was made, as Private Sync holds
// it.
const ChangeSchema = Schema.Struct({
  address: AddressSchema,
  blocked: Schema.Boolean,
  at: Schema.Finite,
});
type Change = typeof ChangeSchema.Type;
// What a Profile's record seals: each of its addresses' and domains' latest change. A record
// without domains has no `domains`, as one written before #2477; a device that predates them reads
// the addresses alone.
const RecordJsonSchema = Schema.fromJsonString(
  Schema.Struct({
    profile: Schema.NonEmptyString,
    changes: Schema.Array(ChangeSchema),
    domains: Schema.optionalKey(Schema.Array(DomainChangeSchema)),
  }),
);
const decodeRecord = Schema.decodeUnknownOption(RecordJsonSchema);
const PulledSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  records: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
      updatedAt: Schema.Finite,
      // Decoded one by one, so a record this device cannot read changes nothing.
      senders: Schema.NullOr(Schema.String),
    }),
  ),
  unreadable: Schema.Array(Schema.NonEmptyString),
});
// Native code accepts a Private Sync record identifier of at most 200 characters.
const publishable = (profile: string) => profile.length <= 200;

// A device-local receipt: this device took one blocked arrival of a connection to Trash, where the
// connection has one, so an arrival reported again, as when the person restores it to the Inbox,
// is not moved again while its receipt is kept. Its sender and receipt time name it, since a move renames an IMAP or
// Microsoft message.
const ReceiptSchema = Schema.Struct({
  connection: Schema.NonEmptyString,
  address: Schema.NonEmptyString,
  receivedAt: Schema.NonEmptyString,
});
type Receipt = typeof ReceiptSchema.Type;

// The newest receipts kept; an arrival whose receipt fell out of them can move again.
const receiptLimit = 1000;

type Stored = Readonly<{
  senders: readonly BlockedSender[];
  receipts: readonly Receipt[];
  unblocked: readonly Unblocked[];
  domains: readonly BlockedDomain[];
  unblockedDomains: readonly UnblockedDomain[];
}>;
const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({
    senders: Schema.Array(BlockedSenderSchema),
    receipts: Schema.optionalKey(Schema.Array(ReceiptSchema)),
    unblocked: Schema.optionalKey(Schema.Array(UnblockedSchema)),
    domains: Schema.optionalKey(Schema.Array(BlockedDomainSchema)),
    unblockedDomains: Schema.optionalKey(Schema.Array(UnblockedDomainSchema)),
  }),
);
const OpenedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(DocumentSchema),
});
const CommittedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
});

// The signed-in Product Account's Blocked Senders on this device: one document native code keeps
// encrypted for the account that wrote it, like its Mail Templates. Every call rejects with
// 'locked' while the device is locked.
export interface NativeBlockedSenders {
  // Resolves `{ owner, revision, document }`; `document` is null when the account has none.
  readonly openBlockedSenders: () => Promise<unknown>;
  // Replaces the document only from `expectedRevision` and resolves `{ owner, revision }`.
  readonly commitBlockedSenders: (
    owner: string,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
}

// Each Mail Profile's Blocked Senders in Private Sync, one record per Profile. Native code seals
// each record to the account and an opaque identifier derived from the Profile's, so Convex holds
// only ciphertext. Every call rejects with 'unavailable' while this device holds no keys or
// Product Sign-In session.
export interface NativeBlockedSenderSync {
  // Resolves `{ owner, records: [{ id, version, updatedAt, senders }], unreadable }`, `senders`
  // being the JSON the record seals. `unreadable` names the Profiles of `known` whose record exists
  // but does not open here.
  readonly pullBlockedSenders: (
    owner: string,
    known: readonly string[],
  ) => Promise<unknown>;
  // Writes Profile `id`'s record, sealing `senders`, only while it is still at `expectedUpdatedAt`
  // (absent: while there is none). Resolves `{ owner, committed, updatedAt? }`.
  readonly pushBlockedSenders: (
    owner: string,
    record: Readonly<{
      id: string;
      version: number;
      senders: string;
      expectedUpdatedAt?: number;
    }>,
  ) => Promise<unknown>;
}

const report = reportPreference('Blocked Sender');

const isProfileAddress =
  (profile: string, address: string) =>
  (sender: Readonly<{ profile: string; address: string }>) =>
    sender.profile === profile && sender.address === address;

// `profile`'s changes this device holds: a block for each Blocked Sender and an unblock for each
// address it stopped blocking.
const changesOf = (stored: Stored, profile: string): Change[] => [
  ...stored.senders
    .filter((sender) => sender.profile === profile)
    .map(({ address, blockedAt }) => ({
      address,
      blocked: true,
      at: blockedAt,
    })),
  ...stored.unblocked
    .filter((unblocked) => unblocked.profile === profile)
    .map(({ address, unblockedAt }) => ({
      address,
      blocked: false,
      at: unblockedAt,
    })),
];

// Each key's later change. At the same instant an unblock wins, since it moves nothing, and of two
// blocks the greater `tie`; so devices converge whatever order they merge in.
const latestBy =
  <C extends Readonly<{ blocked: boolean; at: number }>>(
    key: (change: C) => string,
    tie: (change: C) => string = () => '',
  ) =>
  (changes: readonly C[]) => {
    const latest = new Map<string, C>();
    for (const change of changes) {
      const kept = latest.get(key(change));
      latest.set(
        key(change),
        kept === undefined ||
          change.at > kept.at ||
          (change.at === kept.at &&
            (!change.blocked || (kept.blocked && tie(change) > tie(kept))))
          ? change
          : kept,
      );
    }
    return Arr.sort(latest.values(), Order.mapInput(Order.String, key));
  };
const merged = latestBy((change: Change) => change.address);
// A domain block's choices, which tell apart two blocks made at the same instant.
const choicesOf = ({
  subdomains,
  exempt,
}: Readonly<{ subdomains?: boolean; exempt?: readonly string[] }>) =>
  `${subdomains === true} ${(exempt ?? []).join(' ')}`;
const mergedDomains = latestBy(
  (change: DomainChange) => change.domain,
  choicesOf,
);
const sameChanges = Schema.toEquivalence(Schema.Array(ChangeSchema));
const sameDomainChanges = Schema.toEquivalence(
  Schema.Array(DomainChangeSchema),
);

const isProfileDomain =
  (profile: string, domain: string) =>
  (block: Readonly<{ profile: string; domain: string }>) =>
    block.profile === profile && block.domain === domain;

// `profile`'s domain changes this device holds: a block with its choices for each Blocked Domain
// and an unblock for each domain it stopped blocking.
const domainChangesOf = (stored: Stored, profile: string): DomainChange[] => [
  ...stored.domains
    .filter((block) => block.profile === profile)
    .map(({ domain, subdomains, exempt, blockedAt }) => ({
      domain,
      blocked: true,
      at: blockedAt,
      subdomains,
      exempt,
    })),
  ...stored.unblockedDomains
    .filter((unblocked) => unblocked.profile === profile)
    .map(({ domain, unblockedAt }) => ({
      domain,
      blocked: false,
      at: unblockedAt,
    })),
];

// `stored` with `remote`, another device's changes of `profile`, merged in. A Blocked Sender or
// Blocked Domain that stays blocked keeps this device's move count; one blocked again or elsewhere
// starts at none.
const adopt = (
  stored: Stored,
  profile: string,
  remote: Readonly<{
    changes: readonly Change[];
    domains: readonly DomainChange[];
  }>,
) => {
  const local = merged(changesOf(stored, profile));
  const next = merged([...local, ...remote.changes]);
  const localDomains = mergedDomains(domainChangesOf(stored, profile));
  const nextDomains = mergedDomains([...localDomains, ...remote.domains]);
  if (
    sameChanges(local, next) &&
    sameDomainChanges(localDomains, nextDomains)
  ) {
    return stored;
  }
  const latest = new Map(next.map((change) => [change.address, change]));
  return {
    ...stored,
    senders: [
      ...stored.senders.flatMap((sender) => {
        if (sender.profile !== profile) {
          return [sender];
        }
        const change = latest.get(sender.address);
        if (change?.blocked !== true) {
          return [];
        }
        return change.at === sender.blockedAt
          ? [sender]
          : [{ ...sender, blockedAt: change.at, moved: 0 }];
      }),
      ...next
        .filter(
          ({ address, blocked }) =>
            blocked && !stored.senders.some(isProfileAddress(profile, address)),
        )
        .map(({ address, at }) => ({
          profile,
          address,
          blockedAt: at,
          moved: 0,
        })),
    ],
    unblocked: [
      ...stored.unblocked.filter((unblocked) => unblocked.profile !== profile),
      ...next
        .filter(({ blocked }) => !blocked)
        .map(({ address, at }) => ({ profile, address, unblockedAt: at })),
    ],
    domains: [
      ...stored.domains.filter((block) => block.profile !== profile),
      ...nextDomains.flatMap(
        ({ domain, blocked, at, subdomains = false, exempt = [] }) =>
          blocked
            ? [
                stored.domains.find(
                  (block) =>
                    isProfileDomain(profile, domain)(block) &&
                    block.blockedAt === at &&
                    choicesOf(block) === choicesOf({ subdomains, exempt }),
                ) ?? {
                  profile,
                  domain,
                  subdomains,
                  exempt,
                  blockedAt: at,
                  moved: 0,
                },
              ]
            : [],
      ),
    ],
    unblockedDomains: [
      ...stored.unblockedDomains.filter(
        (unblocked) => unblocked.profile !== profile,
      ),
      ...nextDomains
        .filter(({ blocked }) => !blocked)
        .map(({ domain, at }) => ({ profile, domain, unblockedAt: at })),
    ],
  };
};

// The records this device can read; one that does not decode, or names another Profile, is
// unreadable and changes nothing.
const readable = (pulled: typeof PulledSchema.Type) => {
  const unreadable = new Set(pulled.unreadable);
  const records = pulled.records.flatMap(({ senders, ...record }) => {
    const sealed = Option.getOrUndefined(decodeRecord(senders ?? ''));
    if (sealed?.profile !== record.id) {
      unreadable.add(record.id);
      return [];
    }
    return [
      {
        ...record,
        changes: merged(sealed.changes),
        domains: mergedDomains(sealed.domains ?? []),
      },
    ];
  });
  return { records, unreadable };
};

type Pulled = Readonly<{
  version: number;
  updatedAt: number;
  changes: readonly Change[];
  domains: readonly DomainChange[];
}>;

// The Profiles that have changes on this device.
const profilesOf = (stored: Stored) => [
  ...new Set(
    [
      ...stored.senders,
      ...stored.unblocked,
      ...stored.domains,
      ...stored.unblockedDomains,
    ].map(({ profile }) => profile),
  ),
];

// A sender's move count. One stored before senders kept it counts its kept receipts that arrived
// since it was blocked.
const movedFor = (sender: BlockedSender, receipts: readonly Receipt[]) =>
  sender.moved ??
  receipts.filter(
    (receipt) =>
      receipt.address === sender.address &&
      Date.parse(receipt.receivedAt) >= sender.blockedAt,
  ).length;

// Each Mail Profile's Blocked Senders and Blocked Domains, stored on this device without network
// access, and the receipts of the arrivals they moved to Trash. With `sync`, they also synchronize
// through Private Sync: after each block or unblock and on `synchronize`. Receipts and move counts
// stay on this device.
export function createBlockedSenders(
  storage: NativeBlockedSenders,
  registration: Pick<Registration, 'getSnapshot'>,
  sync?: Readonly<{
    native: NativeBlockedSenderSync;
    // Called when native code purged the account because this device was removed.
    removed?: () => void;
    // Adopts a key epoch another device's removal moved the account to.
    adoptKeyRotation?: () => Promise<unknown>;
  }>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  // Told after each change this device stores, such as a block or a receipt.
  const listeners = new Set<() => void>();
  const changed = () => {
    for (const listener of listeners) {
      listener();
    }
  };
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // The Blocked Senders of `account`, the Product Account signed in when the action was called, so
  // an action that waited, or whose read finished, while another account signed in reads and
  // writes nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* native(
        storage.openBlockedSenders,
        OpenedSchema,
      );
      if (owner !== account || signedIn() !== account) {
        return yield* ownerMismatch();
      }
      return {
        owner,
        revision,
        senders: [],
        receipts: [],
        unblocked: [],
        domains: [],
        unblockedDomains: [],
        ...document,
      };
    });

  // Replaces the stored Blocked Senders, Blocked Domains, unblocks and receipts from the revision
  // `stored` read.
  const commit = (
    { owner, revision }: Readonly<{ owner: string; revision: number }>,
    { senders, receipts, unblocked, domains, unblockedDomains }: Stored,
  ) =>
    Effect.gen(function* () {
      const document = yield* Schema.encodeEffect(DocumentSchema)({
        senders,
        receipts,
        unblocked,
        domains,
        unblockedDomains,
      }).pipe(Effect.mapError(malformed));
      const committed = yield* native(
        () => storage.commitBlockedSenders(owner, revision, document),
        CommittedSchema,
      );
      if (committed.owner !== owner) {
        return yield* ownerMismatch();
      }
      changed();
    });

  // Writes `profile`'s changes by compare-and-set from `record`, the one this pass read, when they
  // differ from it. Resolves whether another device's write won.
  const publish = Effect.fnUntraced(function* (
    remote: NativeBlockedSenderSync,
    account: string,
    {
      profile,
      changes,
      domains,
      record,
    }: Readonly<{
      profile: string;
      changes: readonly Change[];
      domains: readonly DomainChange[];
      record: Pulled | undefined;
    }>,
  ) {
    if (
      record !== undefined &&
      sameChanges(record.changes, changes) &&
      sameDomainChanges(record.domains, domains)
    ) {
      return false;
    }
    const senders = yield* Schema.encodeEffect(RecordJsonSchema)({
      profile,
      changes,
      ...(domains.length === 0 ? {} : { domains }),
    }).pipe(Effect.mapError(malformed));
    const pushed = yield* native(
      () =>
        remote.pushBlockedSenders(account, {
          id: profile,
          version: (record?.version ?? 0) + 1,
          senders,
          ...(record === undefined
            ? {}
            : { expectedUpdatedAt: record.updatedAt }),
        }),
      PushedSchema,
    );
    if (pushed.owner !== account) {
      return yield* ownerMismatch();
    }
    return !pushed.committed;
  });

  // One pass: merges every Profile's record into this device's Blocked Senders, then writes by
  // compare-and-set each record the merge changed. A Profile whose record does not open here keeps
  // its record. Resolves whether another device's write won meanwhile.
  const pass = Effect.fnUntraced(function* (remote: NativeBlockedSenderSync) {
    const account = signedIn();
    if (account === undefined) {
      return false;
    }
    const before = yield* opened(account);
    const pulled = yield* native(
      () => remote.pullBlockedSenders(account, profilesOf(before)),
      PulledSchema,
    );
    if (pulled.owner !== account) {
      return yield* ownerMismatch();
    }
    const { records, unreadable } = readable(pulled);
    const stored = yield* Effect.gen(function* () {
      const read = yield* opened(account);
      const next = records.reduce<Stored>(
        (document, { id, ...record }) => adopt(document, id, record),
        read,
      );
      if (next !== read) {
        yield* commit(read, next);
      }
      return next;
    }).pipe(semaphore.withPermit);
    let conflicted = false;
    for (const profile of profilesOf(stored).filter(
      (id) => !unreadable.has(id) && publishable(id),
    )) {
      conflicted =
        (yield* publish(remote, account, {
          profile,
          changes: merged(changesOf(stored, profile)),
          domains: mergedDomains(domainChangesOf(stored, profile)),
          record: records.find(({ id }) => id === profile),
        })) || conflicted;
    }
    return conflicted;
  });

  const synchronize = preferencePasses('Blocked Sender', pass, sync);

  // Resolves whether storage holds what `change` makes of the stored Blocked Senders, and then
  // publishes it; returning them unchanged writes nothing. No Profile, or no `normalized` address
  // or domain, is refused.
  const changing = async (
    profile: string,
    normalized: string | undefined,
    change: (stored: Stored, normalized: string) => Stored,
  ) => {
    if (profile === '' || normalized === undefined) {
      return false;
    }
    const account = signedIn();
    const stored = await runLogged(
      Effect.gen(function* () {
        const read = yield* opened(account);
        const next = change(read, normalized);
        if (next !== read) {
          yield* commit(read, next);
        }
        return true;
      }).pipe(
        semaphore.withPermit,
        Effect.catchTag('DraftStorageFailure', (error) =>
          report(error).pipe(Effect.as(false)),
        ),
      ),
    );
    if (stored) {
      void synchronize();
    }
    return stored;
  };

  return {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // `profile`'s Blocked Senders, or undefined while storage cannot read them.
    blockedSenders: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ senders, receipts }) =>
            senders
              .filter((sender) => sender.profile === profile)
              .map((sender) => ({
                ...sender,
                moved: movedFor(sender, receipts),
              })),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Blocks `address` for `profile`; one it already blocks keeps its first date.
    block: (profile: string, address: string) =>
      changing(profile, blockedAddress(address), (stored, normalized) => {
        if (stored.senders.some(isProfileAddress(profile, normalized))) {
          return stored;
        }
        const unblocked = stored.unblocked.find(
          isProfileAddress(profile, normalized),
        );
        return {
          ...stored,
          senders: [
            ...stored.senders,
            {
              profile,
              address: normalized,
              // After the unblock it ends, even when the clock went back.
              blockedAt: Math.max(
                Date.now(),
                (unblocked?.unblockedAt ?? 0) + 1,
              ),
              moved: 0,
            },
          ],
          unblocked: stored.unblocked.filter((kept) => kept !== unblocked),
        };
      }),
    // Which of a connection's newly arriving `messages` its Mail Profile `profile` blocks: `blocked`
    // names each, which gets no notification, and `move` those this call recorded a receipt for,
    // which the caller moves to Trash. An arrival with a kept receipt is not moved again, and a receipt
    // storage refuses moves nothing. A connection that `moves` nothing to Trash now records no
    // receipt. Undefined while storage cannot read the Blocked Senders.
    screen: (
      profile: string,
      connection: Readonly<{ id: string; moves: boolean }>,
      messages: ReadonlyArray<
        Readonly<{ id: string; address: string; receivedAt: string }>
      >,
    ) => {
      const account = signedIn();
      return runLogged(
        Effect.gen(function* () {
          const stored = yield* opened(account);
          // An arrival counts for its exact Blocked Sender when one matches, otherwise for each
          // Blocked Domain that takes it.
          const arrivals = messages.flatMap(({ id, receivedAt, ...sender }) => {
            const address = blockedAddress(sender.address);
            if (address === undefined) {
              return [];
            }
            const exact = stored.senders.some(
              isProfileAddress(profile, address),
            );
            const domains =
              exact || !asciiDomain(sender.address)
                ? []
                : stored.domains.filter(
                    (block) =>
                      block.profile === profile && takes(block, address),
                  );
            return exact || domains.length > 0
              ? [
                  {
                    id,
                    domains,
                    receipt: { connection: connection.id, address, receivedAt },
                  },
                ]
              : [];
          });
          const blocked = new Set(arrivals.map(({ id }) => id));
          const moving = arrivals.filter(
            ({ receipt }) =>
              connection.moves &&
              !stored.receipts.some(
                (kept) =>
                  kept.connection === receipt.connection &&
                  kept.address === receipt.address &&
                  kept.receivedAt === receipt.receivedAt,
              ),
          );
          const move = moving.map(({ id }) => id);
          if (move.length === 0) {
            return { blocked, move };
          }
          const recorded = yield* commit(stored, {
            ...stored,
            // A count outlives the receipts, which only keep an arrival from moving twice, so every
            // sender's is stored before older receipts are dropped.
            senders: stored.senders.map((sender) => ({
              ...sender,
              moved:
                movedFor(sender, stored.receipts) +
                moving.filter(
                  ({ receipt, domains }) =>
                    sender.profile === profile &&
                    domains.length === 0 &&
                    receipt.address === sender.address,
                ).length,
            })),
            domains: stored.domains.map((block) => ({
              ...block,
              moved:
                block.moved +
                moving.filter(({ domains }) => domains.includes(block)).length,
            })),
            receipts: [
              ...stored.receipts,
              ...moving.map(({ receipt }) => receipt),
            ].slice(-receiptLimit),
          }).pipe(
            Effect.as(true),
            Effect.catchTag('DraftStorageFailure', (error) =>
              report(error).pipe(Effect.as(false)),
            ),
          );
          return { blocked, move: recorded ? move : [] };
        }).pipe(
          semaphore.withPermit,
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      );
    },
    // Unblocks `address` for `profile` alone, keeping the unblock for Private Sync.
    unblock: (profile: string, address: string) =>
      changing(profile, blockedAddress(address), (stored, normalized) => {
        const sender = stored.senders.find(
          isProfileAddress(profile, normalized),
        );
        return sender === undefined
          ? stored
          : {
              ...stored,
              senders: stored.senders.filter((kept) => kept !== sender),
              unblocked: [
                ...stored.unblocked.filter(
                  (kept) => !isProfileAddress(profile, normalized)(kept),
                ),
                {
                  profile,
                  address: normalized,
                  // After the block it ends, even when the clock went back.
                  unblockedAt: Math.max(Date.now(), sender.blockedAt + 1),
                },
              ],
            };
      }),
    // `profile`'s Blocked Domains, or undefined while storage cannot read them.
    blockedDomains: (profile: string) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ domains }) =>
            domains.filter((block) => block.profile === profile),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Blocks `domain` for `profile`, with every subdomain when `subdomains`, letting the exact
    // addresses `exempt` through. One it already blocks with the same choices keeps its first date;
    // other choices replace them from now, counting moves from none. An invalid exempt address
    // refuses the block.
    blockDomain: (
      profile: string,
      domain: string,
      choices: Readonly<{ subdomains: boolean; exempt: readonly string[] }>,
    ) => {
      const addresses = choices.exempt.map((address) =>
        asciiDomain(address) ? blockedAddress(address) : undefined,
      );
      const exempt = Arr.sort(
        new Set(addresses.filter((address) => address !== undefined)),
        Order.String,
      );
      return changing(
        profile,
        addresses.includes(undefined) ? undefined : blockedDomain(domain),
        (stored, normalized) => {
          const kept = stored.domains.find(
            isProfileDomain(profile, normalized),
          );
          if (
            kept !== undefined &&
            choicesOf(kept) === choicesOf({ ...choices, exempt })
          ) {
            return stored;
          }
          const unblocked = stored.unblockedDomains.find(
            isProfileDomain(profile, normalized),
          );
          return {
            ...stored,
            domains: [
              ...stored.domains.filter((block) => block !== kept),
              {
                profile,
                domain: normalized,
                subdomains: choices.subdomains,
                exempt,
                // After the block or unblock it replaces, even when the clock went back.
                blockedAt: Math.max(
                  Date.now(),
                  (kept?.blockedAt ?? unblocked?.unblockedAt ?? 0) + 1,
                ),
                moved: 0,
              },
            ],
            unblockedDomains: stored.unblockedDomains.filter(
              (block) => block !== unblocked,
            ),
          };
        },
      );
    },
    // Unblocks `domain` for `profile` alone, keeping the unblock for Private Sync. Mail it moved
    // stays in Trash.
    unblockDomain: (profile: string, domain: string) =>
      changing(profile, blockedDomain(domain), (stored, normalized) => {
        const kept = stored.domains.find(isProfileDomain(profile, normalized));
        return kept === undefined
          ? stored
          : {
              ...stored,
              domains: stored.domains.filter((block) => block !== kept),
              unblockedDomains: [
                ...stored.unblockedDomains.filter(
                  (block) => !isProfileDomain(profile, normalized)(block),
                ),
                {
                  profile,
                  domain: normalized,
                  // After the block it ends, even when the clock went back.
                  unblockedAt: Math.max(Date.now(), kept.blockedAt + 1),
                },
              ],
            };
      }),
    // Merges Private Sync into this device's Blocked Senders and publishes this device's changes;
    // resolves once no pass is running.
    synchronize,
  };
}
export type BlockedSenders = ReturnType<typeof createBlockedSenders>;
