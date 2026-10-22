"""Refuse incomplete or failed corpus-v2 qualification while retaining its evidence."""
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
# The fields a reviewer reads in each row; a ready answer also keeps its text.
fields = {
    'device': {'hardware': str, 'system': str, 'locale': str, 'languages': list,
               'availability': str},
    'summary': {'state': str, 'ms': int, 'facts': list},
    'rewrite': {'state': str, 'ms': int, 'facts': list},
    'reply': {'state': str, 'ms': int, 'facts': list},
    'translation': {'state': str, 'ms': int},
    'native-cancel': {'code': str, 'ms': int},
    'summary-cancel': {'shown': str, 'after': str},
    'stale-result': {'stale': str, 'current': str, 'nativeStarts': int},
    'translation-cancel': {'shown': str, 'after': str},
}


def nonblank(value):
    return isinstance(value, str) and bool(value.strip())


# A limited answer names the capability it lacked; behavior rows carry their states instead.
def described(row):
    required = fields.get(row.get('kind'), {})
    return (all(isinstance(row.get(key), kind) for key, kind in required.items())
            and (row.get('state') != 'ready' or nonblank(row.get('text')))
            and (row.get('result') != 'limited' or 'state' not in required
                 or nonblank(row.get('reason'))))


identities = {(kind, identifier) for kind, identifiers in expected.items()
              for identifier in identifiers}
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
cases = rows[1:-1]
counts = {result: sum(row.get('result') == result for row in cases)
          for result in ('pass', 'limited', 'fail')}
if (not rows or rows[0].get('kind') != 'device'
        or any(row.get('corpusVersion') != 2 for row in rows)
        or len(cases) != len(identities)
        or {(row.get('kind'), row.get('id')) for row in cases} != identities
        or sum(counts.values()) != len(cases)
        or rows[-1] != {'corpusVersion': 2, 'kind': 'complete', **counts}
        or not all(described(row) for row in rows[:-1])):
    raise SystemExit('Incomplete or malformed assistance qualification evidence')
if counts['fail']:
    raise SystemExit(f"Assistance qualification has {counts['fail']} failed checks")
