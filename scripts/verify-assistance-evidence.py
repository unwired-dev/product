"""Refuse incomplete or failed corpus-v1 qualification while retaining its evidence."""
import json
from pathlib import Path
import sys

expected = {
    'summary': ['lease-deadline', 'instruction-in-body', 'long-newsletter',
                'committee-meeting', 'delivery-address'],
    'rewrite': ['rough-note', 'long-draft', 'czech-note'],
    'reply': ['confirm-meeting', 'long-quoted-message', 'answer-in-german'],
    'translation': ['german-to-english', 'czech-to-english', 'english-to-german',
                    'same-language', 'unidentified-language'],
    'native-cancel': [None],
    'summary-cancel': [None],
    'stale-result': [None],
    'translation-cancel': [None],
}
identities = {(kind, identifier) for kind, identifiers in expected.items()
              for identifier in identifiers}
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
cases = rows[1:-1]
counts = {result: sum(row.get('result') == result for row in cases)
          for result in ('pass', 'limited', 'fail')}
if (not rows or rows[0].get('kind') != 'device'
        or any(row.get('corpusVersion') != 1 for row in rows)
        or len(cases) != len(identities)
        or {(row.get('kind'), row.get('id')) for row in cases} != identities
        or sum(counts.values()) != len(cases)
        or rows[-1] != {'corpusVersion': 1, 'kind': 'complete', **counts}):
    raise SystemExit('Incomplete or malformed assistance qualification evidence')
if counts['fail']:
    raise SystemExit(f"Assistance qualification has {counts['fail']} failed checks")
