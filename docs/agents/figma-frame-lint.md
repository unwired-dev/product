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

- `rawPaints`: solid fills and strokes with no colour variable, grouped by hex,
  with up to five sample node ids each.
- `looseText`: text with neither a text style nor a font-size variable.
- `detachedCopies`: frames named like a component on the Components page but
  not an instance of it.

Inside an instance only overridden fields count; lint a component's own layers
by passing its id.

A frame is clean when all three lists are empty. A finding that is deliberate
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
const detachedCopies = [];
const missing = [];

const addRaw = (node, kind, paint) => {
  const key = `${kind} ${hex(paint.color)}${paint.opacity < 1 ? ` @${Math.round(paint.opacity * 100)}%` : ''}`;
  const entry = rawPaints.get(key) ?? { count: 0, samples: [] };
  entry.count += 1;
  if (entry.samples.length < MAX_SAMPLES) entry.samples.push(node.id);
  rawPaints.set(key, entry);
};

// Inside an instance, only overrides belong to the frame; the rest is the component's.
const overrides = new Map();
const owns = (node, field) =>
  !node.id.startsWith('I') || overrides.get(node.id)?.has(field);

const visit = (node) => {
  if (node.visible === false) return;
  if (node.type === 'INSTANCE') {
    for (const o of node.overrides)
      overrides.set(o.id, new Set(o.overriddenFields));
  }
  for (const kind of ['fills', 'strokes']) {
    const paints = node[kind];
    if (!Array.isArray(paints) || !owns(node, kind)) continue;
    for (const paint of paints) {
      if (
        paint.type === 'SOLID' &&
        paint.visible !== false &&
        !paint.boundVariables?.color
      ) {
        addRaw(node, kind, paint);
      }
    }
  }
  const textOwned = ['textStyleId', 'fontSize', 'fontName'].some((f) =>
    owns(node, f),
  );
  if (
    node.type === 'TEXT' &&
    textOwned &&
    !node.textStyleId &&
    !node.boundVariables?.fontSize
  ) {
    looseText.push({ id: node.id, text: node.characters.slice(0, 40) });
  }
  if (node.type === 'FRAME' && componentNames.has(node.name)) {
    detachedCopies.push({ id: node.id, name: node.name });
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
  detachedCopies: detachedCopies.slice(0, 50),
  detachedCopyCount: detachedCopies.length,
};
```
