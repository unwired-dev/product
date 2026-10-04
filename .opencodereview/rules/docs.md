Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context, and apply its R11 in full. The rules below add the defects specific to Markdown, changesets and the review-rule files under `.opencodereview/`.

Documentation here is product truth that agents execute: an implementer follows the operational guides literally, and the reviewer treats ADRs and architecture companions as authority. A wrong sentence becomes wrong code.

#### Accuracy against the repository

- A command, script name, path, flag, version or environment variable that does not exist as written. Check it against `package.json`, the workflow files and the tree.
- Behavior described as shipped that the code does not implement, or planned replacement behavior stated in the present tense. Unavailable or deferred checks are described as deferred.
- A relative link or heading fragment that does not resolve, or a link left pointing at a moved section.
- A statement that restates what a config file or command already says, where the copy can go stale. Point to the source.

#### Vocabulary

- A term from `GLOSSARY.md` or a topic glossary replaced by a synonym, a new domain term used without a definition, or a glossary entry changed outside `docs/agents/domain.md`'s policy.
- Product Sign-In, Trusted Device, Mailbox Connection and Product Sync used interchangeably; they are distinct and their difference carries privacy meaning.

#### Authority and placement

- Architecture, design rationale or internal implementation detail written into an implementer-facing file (`AGENTS.md`, `README.md`, `docs/*.md`, `docs/agents/`, `docs/product/`, `docs/domain/`). It belongs in `docs/architecture/` or an ADR; the implementer-facing file keeps setup, commands, validation and observable behavior.
- A requirement that exists only in a reviewer-only file after the change. The implementer must still be able to read every requirement it has to satisfy.
- An accepted ADR edited to reverse its decision without a supersession note, or a new decision recorded outside an ADR. Use the full ADR filename where numbers collide.
- A prototype, historical or archived statement presented as a first-release requirement or as qualification evidence.
- An agent guide (`AGENTS.md`, `docs/agents/`) that contradicts the root guide's workflow, validation or triage instructions, or that adds an always-loaded line which only restates a linked document.

#### Changesets

- A changeset naming a package outside the workspace, a bump level that understates the change (a breaking exported type or wire change marked `patch`), or a summary that does not say what a user or consumer observes.
- A runtime behavior or exported API or type change in the task with no changeset. Documentation, tests and internal refactors may omit one.

#### Review rules (`.opencodereview/`)

- A `rule.json` entry placed after a broader pattern that already matches its files; the first match wins and entries never combine.
- A `rule` path that does not exist or is unreadable. OCR warns on stderr and silently applies no project rule to those files.
- A path rule whose first instruction no longer requires `rules/common.md`, or a change to `common.md` that drops a responsibility listed in `docs/architecture/open-code-review.md`.
- `merge_system_rule` changed for an entry without checking the resolved text with `ocr rules check <path>`; the embedded TypeScript rule contradicts the Effect conventions and is deliberately not merged for Effect-governed code.
- A rule bullet that a linter or type checker already decides, that names no file, helper or invariant, or that gives no consequence. Such bullets produce noise and dilute the rest.
- An `include` or `exclude` change that hides task-owned source from review or admits dependencies, build output, generated files or secrets.

#### Leave to tooling

Markdown formatting and line wrapping belong to oxfmt.
