# Design judge

The design judge decides whether the running app matches its approved Figma
frames. It is the last step of the [design review](implementation-review.md#design-review)
and answers any request to align a screen with Figma. The implementer prepares
**pairs** (a frame export and an app capture of the same state); the latest GPT
Sol model judges them by measurement. The implementer never grades their own
match: frame links, captions and code reading are not a verdict.

## 1. Plan the pairs

List one pair per changed state, per touched platform (iPhone, iPad, Mac) and
per appearance (Light, Dark). The list comes from the acceptance criteria's
states and their frames. Include the open and pressed states of menus, popovers
and sheets: their anchoring is where native controls drift from the frames.

## 2. Export the frames

Sol cannot open Figma, so give it files and numbers:

- **Image:** `get_screenshot` of the frame node, or an in-plugin
  `screenshot({ scale })` through `use_figma` for 2× and 3×. Take both images
  of a pixel comparison from the same source; they differ in rounded corners.
- **Geometry:** `get_metadata` (or a read-only `use_figma` script) for the
  position and size of every element the change touches, with resolved colour
  variables and text styles.
- **Provenance:** file key, node id, frame name and the export date.

The Figma seat allows about 200 calls a day, shared by every agent: put several
reads and up to five in-plugin screenshots into each `use_figma` call.

## 3. Capture the app

Capture each state with Mock Mail Sessions under
[native validation](native-validation.md), at the frame's device size and
appearance, on iPhone and iPad Simulators and the Mac host. Convert Display P3
captures to sRGB before colour comparison. A capture you cannot take leaves its
pair **not compared**, never matching.

Store everything under `artifacts/design-judge/<issue>/`, named
`<state>-<platform>-<appearance>-frame.png` and `…-app.png`, with an
`index.md` listing each pair's node id, export scale, capture device, and the
[Known frame differences](../../DESIGN.md#known-frame-differences) and approved
native differences that apply.

## 4. Run the judge

Call `orchestrator_capabilities` and pick the newest GPT Sol model
(`gpt-6.2-sol` on 2026-11-25); read the id each time rather than copying it.
Start it with `delegate_task`: `role: "review"`, `mode: "async"`, reasoning
effort `high`, a new `clientRequestId` each round. Brief:

```
Design judge. Review only: do not edit, commit, push, or start subagents.
Return any temporary paths you create; leave them for the parent to clean up.
Repo: <abs path> Pairs: <abs path>/index.md Change: <issue and intent>
For every pair, measure the app against the frame: position, size, spacing
and alignment of each element (tolerance 2pt at 1x), anchoring of menus,
popovers and sheets, colours in sRGB, type size, weight and line height,
SF Symbols, Liquid Glass and shadows, copy and truncation, and state
(empty, loading, error, disabled). Crop and overlay; read pixel values.
The differences listed as intended in index.md are not defects. Report every
other difference, including ones outside the change, marked pre-existing.
Reply:
VERDICT: PASS or FAIL
D1 <platform> <appearance> <state> <element>: frame <value>, app <value>. Fix: <suggestion>
```

## 5. Fix and judge again

Fix each confirmed difference in the change, recapture the affected pairs and
start a new round with the ledger (`fixed`, `disputed` with evidence, `open`).
Continue while each round lowers the open count; the Mac sweep in #1838 took six
rounds to reach zero. A difference the app cannot close (a native limit, or a
frame that is wrong) goes to the owner as a choice: update the frame through
[design approval](implementation-review.md#design-approval), or record it in
Known frame differences. File pre-existing differences as issues.

The judge passes when every pair is compared and the verdict is PASS, or every
remaining difference has the owner's decision. The PR body carries the verdict,
the rounds and the model; [PR media](pull-request-babysitting.md#implementer-pr-delivery)
shows the pairs.
