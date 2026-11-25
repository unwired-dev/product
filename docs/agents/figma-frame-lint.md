# Figma frame lint

A frame drawn with raw colours, loose text or detached component copies
disagrees with the file's own tokens, so the app cannot match it and stay on
DESIGN.md. Run this lint on every frame you add or change before you ask for
[design approval](implementation-review.md#design-approval), and fix what it
reports.

Put the ids of the changed frames or sections in `ROOT_IDS` and run the script
read-only through `use_figma` (file `d1mHEaUNmnF7YUw6QwIs0T`); load the
`figma-use` skill first. Ids on different pages go in separate parallel calls.
The script returns:

- `missing`: requested ids that did not resolve. Fix the ids and run again.
- `rawPaints`: solid fills and strokes with no colour variable, text ranges
  included, grouped by hex with up to five sample node ids each.
- `looseText`: text, or a range of it, without a text style.
- `possibleDetachedCopies`: frames named like a component on the Components
  page but not an instance of it. Confirm each one by eye.

Inside an instance only overridden fields count; lint a component's own layers
by passing its id.

A frame is clean when all four lists are empty. A finding that is deliberate
(a colour no variable carries yet, such as the popover background) goes in
the approval request with its reason.

```js
const ROOT_IDS = ['1312:96205'];
const MAX_SAMPLES = 5;

const componentsPage = figma.root.children.find((p) => p.name === 'Components');
await componentsPage.loadAsync();
const componentNames = new Set(
  componentsPage
    .findAllWithCriteria({ types: ['COMPONENT', 'COMPONENT_SET'] })
    .map((c) => c.name),
);

const hex = (c) =>
  '#' +
  [c.r, c.g, c.b]
    .map((v) =>
      Math.round(v * 255)
        .toString(16)
        .padStart(2, '0'),
    )
    .join('');
const rawPaints = new Map();
const looseText = [];
const possibleDetachedCopies = [];
const missing = [];

const checkPaints = (node, kind, paints) => {
  for (const paint of paints) {
    if (paint.type !== 'SOLID' || paint.visible === false) continue;
    if (paint.boundVariables?.color) continue;
    const alpha =
      paint.opacity < 1 ? ` @${Math.round(paint.opacity * 100)}%` : '';
    const key = `${kind} ${hex(paint.color)}${alpha}`;
    const entry = rawPaints.get(key) ?? { count: 0, samples: [] };
    entry.count += 1;
    if (entry.samples.length < MAX_SAMPLES) entry.samples.push(node.id);
    rawPaints.set(key, entry);
  }
};

// Inside an instance, only overrides belong to the frame; the rest is the component's.
const overrides = new Map();
const owns = (node, ...fields) =>
  !node.id.startsWith('I') ||
  fields.some((f) => overrides.get(node.id)?.has(f));

const visit = (node) => {
  if (node.visible === false) return;
  if (node.type === 'INSTANCE') {
    for (const o of node.overrides) {
      const fields = overrides.get(o.id) ?? new Set();
      for (const f of o.overriddenFields) fields.add(f);
      overrides.set(o.id, fields);
    }
  }
  if (node.type === 'TEXT') {
    const segments = node.getStyledTextSegments(['textStyleId', 'fills']);
    if (owns(node, 'fills')) {
      for (const s of segments) checkPaints(node, 'text', s.fills);
    }
    if (owns(node, 'textStyleId', 'fontSize', 'fontName')) {
      for (const s of segments.filter((s) => !s.textStyleId)) {
        looseText.push({ id: node.id, text: s.characters.slice(0, 40) });
      }
    }
  }
  // A text node's fills were read per range above.
  for (const kind of node.type === 'TEXT'
    ? ['strokes']
    : ['fills', 'strokes']) {
    if (Array.isArray(node[kind]) && owns(node, kind))
      checkPaints(node, kind, node[kind]);
  }
  if (node.type === 'FRAME' && componentNames.has(node.name)) {
    possibleDetachedCopies.push({ id: node.id, name: node.name });
  }
  if ('children' in node) node.children.forEach(visit);
};

for (const id of ROOT_IDS) {
  const root = await figma.getNodeByIdAsync(id);
  if (root) visit(root);
  else missing.push(id);
}

return {
  missing,
  rawPaints: Object.fromEntries(
    [...rawPaints].sort((a, b) => b[1].count - a[1].count),
  ),
  looseText: looseText.slice(0, 50),
  looseTextCount: looseText.length,
  possibleDetachedCopies: possibleDetachedCopies.slice(0, 50),
  possibleDetachedCopyCount: possibleDetachedCopies.length,
};
```
