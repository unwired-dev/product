# Domain documentation

This repository has one product domain. Its vocabulary is split by reading topic
under `docs/domain/`; those files do not imply separate services or architectural
boundaries. `CONTEXT.md` is the stable entry point and topic index.

## Read for the task

Start at [CONTEXT.md](../../CONTEXT.md), open the relevant topic glossary, and
follow its behavior and ADR links. Read related topics only when the task crosses
their concepts. Use the established terms in issues, code, tests and documentation.

Check [the documentation index](../README.md) for current scope. ADR 0059 through
0064 supersede earlier prototype behavior where stated. A glossary entry, old
"v1" rule or historical discussion does not establish replacement launch scope,
implementation status or passing qualification. Surface conflicts explicitly.

## Put each kind of information in its place

| Information                                       | Location                                                          |
| ------------------------------------------------- | ----------------------------------------------------------------- |
| Topic routing and reading guidance                | Root `CONTEXT.md`                                                 |
| Canonical terms and discouraged synonyms          | The owning file in `docs/domain/`                                 |
| Observable behavior, limits and feature contracts | Relevant feature documentation, including `docs/product/`         |
| Architectural choices and their rationale         | `docs/adr/` when a decision warrants an ADR                       |
| Open questions and implementation work            | The relevant GitHub issue or design discussion                    |
| Superseded dialogue and historical resolutions    | `docs/archive/`, with a scope note and links to current decisions |

The behavior notes in `docs/product/` preserve rules moved from the former
monolithic glossary. Some still describe the Swift prototype. When changing an
area, clarify its current scope and link its authoritative decision; do not turn
an old rule into a new requirement merely by moving or repeating it.

## Add or change a term

1. Search the topic glossaries before introducing a name. Reuse the canonical term
   when its meaning fits; raise an ambiguity when it does not.
2. Give the term one owning topic and one definition. Use the existing
   `**Term**:` format followed by a concise definition and `_Avoid_:` synonyms.
   For new or revised entries, aim for one or two sentences describing what the
   concept is. Put operational detail in the linked feature documentation.
3. State whether prototype-specific or deferred vocabulary has limited scope.
   Keep implementation details, rollout plans, numeric tuning and interview
   transcripts out of new glossary entries.
4. Link to the owning definition or topic from other documents instead of copying
   it. Update callers and documentation when renaming a term; preserve a familiar
   former name in `_Avoid_:` when it helps readers find the replacement.
5. Update `CONTEXT.md` when adding, renaming or moving a topic. Keep the root file
   as an index, without duplicating definitions or accumulating feature rules.

## Verify a documentation change

Run formatting and check local links, including section fragments. After moving
content, account for every original definition and rule exactly once; a rename,
substantive rewrite or deletion needs an explicit reason. Preserve existing
scope and privacy constraints rather than silently resolving a product decision
through editorial changes. Keep old links working or update their callers.

For a structural split, preserve the wording first and review semantic cleanup
separately. The 2026-09-28 split preserves some longer legacy definitions for this
reason; their length is not the template for new entries.
