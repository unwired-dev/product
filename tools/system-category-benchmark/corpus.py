"""Fetch pinned public sources, select annotation candidates and build the versioned corpus.

uv run python corpus.py fetch      # download and verify the pinned public sources into work/
uv run python corpus.py select     # deterministic annotation candidates -> work/candidates.jsonl
uv run python corpus.py build      # candidates + committed labels + synthetic -> work/corpus.jsonl
"""

import email
import email.policy
import hashlib
import json
import random
import re
import sys
import tarfile
import urllib.request
from collections import Counter
from pathlib import Path

import pyarrow.parquet as pq

import synthetic

ROOT = Path(__file__).parent
WORK = ROOT / "work"
# v1 was withdrawn after review found duplicate bodies, a thread and synthetic senders
# crossing splits; v2 reuses its labels with corrected grouping.
CORPUS_VERSION = "v2"
LABELS = ROOT / "corpus" / "labels-real-v1.jsonl"
MANIFEST = ROOT / "corpus" / f"manifest-{CORPUS_VERSION}.json"
CATEGORIES = ["Orders", "Newsletters & Promotions", "Invites", "Flights", "People"]
SEED = 828

ENRON_REVISION = "cfc06c758093d90993abce1a43668fb7357258a6"
SOURCES = {
    **{
        f"enron-{i}.parquet": (
            (
                "https://huggingface.co/datasets/corbt/enron-emails/resolve/"
                f"{ENRON_REVISION}/data/train-0000{i}-of-00003.parquet"
            ),
            digest,
        )
        for i, digest in enumerate(
            [
                "97165e587875e3e57715c14f63547fedbf664f748de1124122d4d2952c56a9fc",
                "c14be60e6c1be0c7a80d20dc8a6769d587988ba5260368868f7944d83a364e7a",
                "79d1b6b9d73461289a84aecdbfbbf1a242fedb21c57a28b57ea07a2d171e1cf7",
            ]
        )
    },
    **{
        f"20030228_{name}.tar.bz2": (
            f"https://spamassassin.apache.org/old/publiccorpus/20030228_{name}.tar.bz2",
            digest,
        )
        for name, digest in [
            ("easy_ham", "2b7b65904bcfcc31d2b5f51946f2d261370b257402cbbd62930b46ab83367438"),
            ("easy_ham_2", "b4bd3dc5ae5b40f38e99a0e41ad7d16b428b56e818e3a6ffa07330d62004dd38"),
            ("hard_ham", "ce2ce67880643dbde65ea7f85bffbfe4417349c4bd80b6b0de56262ae6b0a9c9"),
        ]
    },
}

# Enrichment pools for categories a random sample rarely contains. These terms overlap the
# keyword rules, so the enriched stratum favours the rules and is reported separately.
ENRICHMENT = re.compile(
    r"itinerar|flight|airline|e-?ticket|boarding|invit|rsvp|party|luncheon|order|receipt|"
    r"invoice|purchase|shipp|newsletter|unsubscribe|subscri|special offer|sale\b",
    re.IGNORECASE,
)
SAMPLE_SIZES = {"enron-random": 600, "enron-enriched": 300, "spamassassin-random": 250}
# Subject-targeted Enron pools, added after the first annotation pass found too few rare labels.
TARGETED = {
    "flights": (r"itinerar|e-?ticket|flight|airline|boarding", 150),
    "orders": (
        (
            r"receipt|invoice|order (confirm|status|#)|your order|shipped|shipping confirm|"
            r"purchase confirm|payment (confirm|received)"
        ),
        150,
    ),
    "invites": (r"invitation|invite|rsvp|meeting request", 100),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def corpus_sha256(records: list[dict]) -> str:
    """Freeze every input and split membership, not only held-out IDs and labels."""
    value = json.dumps(sorted(records, key=lambda r: r["id"]), sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(value.encode()).hexdigest()


def fetch() -> None:
    WORK.mkdir(exist_ok=True)
    for name, (url, digest) in SOURCES.items():
        path = WORK / name
        if not path.exists():
            print(f"downloading {url}")
            urllib.request.urlretrieve(url, path)
        if sha256(path) != digest:
            sys.exit(f"{name}: sha256 mismatch; delete it and fetch again")
    print("sources verified")


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def thread_subject(subject: str) -> str:
    return re.sub(
        r"^\s*((re|fw|fwd|aw|odp|tr)\s*:\s*)+", "", subject or "", flags=re.IGNORECASE
    ).lower()


def enron_messages():
    seen = set()
    for i in range(3):
        table = pq.read_table(WORK / f"enron-{i}.parquet")
        for row in table.to_pylist():
            body = row["body"] or ""
            # The corpus repeats each message in every participant's folders.
            key = hashlib.sha1(normalize(row["subject"] + body).encode()).hexdigest()
            if key in seen or len(normalize(body)) < 20:
                continue
            seen.add(key)
            recipients = [r for r in (row["to"] or []) + (row["cc"] or []) if r]
            yield {
                "id": f"enron:{row['message_id']}",
                "source": "enron",
                "from": row["from"] or "",
                "reply_to": "",
                "recipients": len(recipients),
                "list": False,
                "subject": row["subject"] or "",
                "body": body,
                "date": row["date"].isoformat() if row["date"] else "",
            }


def message_text(message) -> str:
    part = message.get_body(preferencelist=("plain", "html"))
    if part is None:
        return ""
    text = part.get_content()
    if part.get_content_type() == "text/html":
        text = re.sub(r"<(style|script)[^>]*>.*?</\1>", " ", text, flags=re.DOTALL | re.IGNORECASE)
        text = re.sub(r"<[^>]+>", " ", text)
    return text


def spamassassin_messages():
    for archive in ["easy_ham", "easy_ham_2", "hard_ham"]:
        with tarfile.open(WORK / f"20030228_{archive}.tar.bz2") as tar:
            for member in sorted(tar.getmembers(), key=lambda m: m.name):
                if not member.isfile() or member.name.endswith("cmds"):
                    continue
                raw = tar.extractfile(member).read()
                message = email.message_from_bytes(raw, policy=email.policy.default)
                try:
                    body = message_text(message)
                except (LookupError, ValueError):
                    continue
                recipients = sum(
                    len(str(message.get(h, "")).split(",")) for h in ("To", "Cc") if message.get(h)
                )
                yield {
                    "id": f"spamassassin:{archive}/{member.name.rsplit('/', 1)[-1]}",
                    "source": f"spamassassin-{archive}",
                    "from": str(message.get("From", "")),
                    "reply_to": str(message.get("Reply-To", "")),
                    "recipients": recipients,
                    "list": any(message.get(h) for h in ("List-Id", "List-Unsubscribe")),
                    "subject": str(message.get("Subject", "")),
                    "body": body,
                    "date": str(message.get("Date", "")),
                }


def select() -> None:
    rng = random.Random(SEED)
    enron = list(enron_messages())
    enriched = [m for m in enron if ENRICHMENT.search(m["subject"])]
    random_ids = set()
    chosen = []
    for message in rng.sample(enron, SAMPLE_SIZES["enron-random"]):
        random_ids.add(message["id"])
        chosen.append({**message, "stratum": "real-random"})
    pool = [m for m in enriched if m["id"] not in random_ids]
    chosen += [
        {**m, "stratum": "real-enriched"} for m in rng.sample(pool, SAMPLE_SIZES["enron-enriched"])
    ]
    spam = list(spamassassin_messages())
    hard = [m for m in spam if m["source"] == "spamassassin-hard_ham"]
    easy = [m for m in spam if m["source"] != "spamassassin-hard_ham"]
    chosen += [
        {**m, "stratum": "real-random"}
        for m in rng.sample(easy, SAMPLE_SIZES["spamassassin-random"])
    ]
    # hard_ham is the whole small archive of commercial-looking ham, not a random sample.
    chosen += [{**m, "stratum": "real-enriched"} for m in hard]
    for name, (pattern, size) in TARGETED.items():
        taken = {m["id"] for m in chosen}
        pool = [
            m
            for m in enron
            if m["id"] not in taken and re.search(pattern, m["subject"], re.IGNORECASE)
        ]
        chosen += [{**m, "stratum": "real-enriched", "pool": name} for m in rng.sample(pool, size)]
    with (WORK / "candidates.jsonl").open("w") as file:
        for message in chosen:
            file.write(json.dumps({**message, "language": "en"}) + "\n")
    print(f"enron={len(enron)} enriched-pool={len(enriched)} spamassassin={len(spam)}")
    print(Counter(m["stratum"] for m in chosen))


def sender_address(sender: str) -> str:
    match = re.search(r"[\w.+'-]+@[\w.-]+", sender or "")
    return match.group(0).lower() if match else (sender or "").lower()


def body_key(record: dict) -> str:
    return hashlib.sha1(normalize(record["body"]).encode()).hexdigest()


def thread_key(record: dict) -> str:
    # One family per source, so a thread split across SpamAssassin archives stays together.
    subject = thread_subject(record["subject"])
    return f"{record['source'].split('-')[0]}:{subject}" if subject else ""


def assign_splits(records: list[dict]) -> None:
    """Union real sender/body/thread groups; assign synthetic templates to their fixed splits."""
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for record in records:
        if record["stratum"] == "synthetic":
            record["split"] = synthetic.template_split(record["template"])
            continue
        keys = [
            f"id:{record['id']}",
            f"sender:{sender_address(record['from'])}",
            f"body:{body_key(record)}",
        ]
        if thread_key(record):
            keys.append(f"thread:{thread_key(record)}")
        for key in keys[1:]:
            parent[find(key)] = find(keys[0])
    for record in records:
        if record["stratum"] == "synthetic":
            continue
        group = find(f"id:{record['id']}")
        bucket = int(hashlib.sha256(f"{SEED}:{group}".encode()).hexdigest(), 16) % 10
        record["split"] = "train" if bucket < 6 else "validation" if bucket < 8 else "test"


def build() -> None:
    labels = {}
    for line in LABELS.read_text().splitlines():
        entry = json.loads(line)
        labels[entry["id"]] = entry
    records = []
    for line in (WORK / "candidates.jsonl").read_text().splitlines():
        message = json.loads(line)
        entry = labels.get(message["id"])
        if entry is None or entry.get("exclude"):
            continue
        records.append({**message, "labels": entry["labels"], "annotator": entry["annotator"]})
    records += synthetic.generate()
    assign_splits(records)
    for name, key in [
        ("sender", lambda r: sender_address(r["from"])),
        ("body", body_key),
        ("thread", lambda r: r["stratum"] != "synthetic" and thread_key(r)),
    ]:
        splits = {}
        for record in records:
            if value := key(record):
                splits.setdefault(value, set()).add(record["split"])
        leaked = sum(len(found) > 1 for found in splits.values())
        assert not leaked, f"{leaked} {name} values span more than one split"
    counts = Counter()
    for record in records:
        slice_ = f"{record['language']}/{record['stratum']}/{record['split']}"
        counts[f"{slice_}/messages"] += 1
        counts[f"{slice_}/uncategorized"] += not record["labels"]
        counts[f"{slice_}/multi-label"] += len(record["labels"]) > 1
        for category in record["labels"]:
            counts[f"{slice_}/{category}"] += 1
    test = sorted((r["id"], tuple(r["labels"])) for r in records if r["split"] == "test")
    manifest = {
        "version": CORPUS_VERSION,
        "seed": SEED,
        "sources": {
            name: {"url": url, "sha256": digest} for name, (url, digest) in SOURCES.items()
        },
        "sample_sizes": SAMPLE_SIZES,
        "enrichment_pattern": ENRICHMENT.pattern,
        "targeted_pools": {name: {"pattern": p, "size": n} for name, (p, n) in TARGETED.items()},
        "labels_sha256": sha256(LABELS),
        "synthetic_generator_sha256": sha256(ROOT / "synthetic.py"),
        "frozen_test_sha256": hashlib.sha256(json.dumps(test).encode()).hexdigest(),
        "corpus_sha256": corpus_sha256(records),
        "counts": dict(sorted(counts.items())),
    }
    if MANIFEST.exists():
        if manifest != json.loads(MANIFEST.read_text()):
            raise ValueError("corpus differs from the frozen manifest; create a new corpus version")
    else:
        MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    with (WORK / "corpus.jsonl").open("w") as file:
        for record in records:
            file.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"{len(records)} records; manifest verified at {MANIFEST.relative_to(ROOT)}")


if __name__ == "__main__":
    {"fetch": fetch, "select": select, "build": build}[sys.argv[1]]()
