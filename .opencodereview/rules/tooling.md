Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to repository tooling: `scripts/`, each host's `scripts/`, the Expo config plugins and the custom lint rules.

These scripts are the gates and runners other evidence depends on: the bundle checks, the native and mock-session runners, the changeset gate, the Effect lint rules and the TestFlight release. A script that fails open turns every result it reports into noise. Report only defects that are near-certain and consequential; style in a shell or Ruby script is not a finding.

#### Gates fail closed

- A check that exits zero despite missing inputs required to prove its stated outcome: no bundle source maps, no selected native tests, or a required tool that was missing. The bundle check's "export the bundle first" assertion guards this. A documented no-op, such as no changeset files to validate, is permitted.
- An error swallowed so the script continues: `|| true`, a `catch` that only logs, a pipeline without `pipefail`, an unchecked child-process exit status or signal.
- A bundle or contract assertion removed, loosened to a substring that always matches, or updated to the new value with no explanation of why the old expectation no longer holds.
- A custom lint rule changed without its test in `scripts/*.test.mjs` covering both a rejected and an accepted case; `pnpm test:tooling` runs them for every configuration.

#### Runners own what they touch

- A Simulator, application, DerivedData directory, result bundle, Keychain item, temporary directory or port used without being created by this run, or selected by a shared name rather than a recorded identifier.
- Cleanup that does not run on failure, cancellation and timeout, or that deletes anything the run did not create.
- A retry that hides an assertion failure. Only infrastructure failure (missing `testmanagerd` socket, CoreSimulator disconnect, unexpected zero tests) justifies one retry on a fresh owned device.
- A mock runner that accepts a scenario outside the fixed list, a production-signed build, or a bundle identifier outside the mock-only prefix.

#### Secrets and release

- A secret echoed, written to a log, an artifact or a temporary file that outlives the step, or passed on a command line visible in the process list.
- A release script that publishes, uploads or tags without the checks its documentation promises, or that derives release notes from unvalidated input.
- A script that assumes a signing identity, profile or logged-in session and reports success when it is absent.

#### Portability and input

- A path, file name or environment value interpolated unquoted into a shell command, or built into a command string rather than passed as an argument.
- Parsed JSON, YAML or tool output used before validation. TypeScript scripts decode with `Schema`; `.mjs` scripts check the shape they depend on.
- A dependency on a tool or version outside `.mise.toml` and the workspace, or on bash-only behavior in a `zsh` script.
- A temporary probe left outside `scratchpad/`.

#### Leave to tooling

Formatting and lint findings. Scripts that are imported by ignored configuration files are listed as Fallow entries on purpose.
