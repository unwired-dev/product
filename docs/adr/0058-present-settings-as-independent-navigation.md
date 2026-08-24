---
status: accepted
---

# Present Settings as independent navigation

Settings is navigation-owned state independent from mailbox synchronization and composer presentation. Mac and Catalyst open a dedicated native Settings window through either the Settings command or `Command-,`, leaving each mail window usable. iPad navigates to an in-app two-column Settings workspace, while iPhone pushes its one-column Settings list into the existing navigation stack. None of these presentations uses the composer's sheet, full-screen, expansion, or Draft state.

Opening Settings or a deep-linked Settings destination resolves from locally available account and Profile configuration and never waits for Thread, message-body, inline-image, remote-image, prefetch, or historical synchronization work. This decision replaces only the presentation aspect of ADR-0055; its Profile-scoping and storage boundaries remain in force.

The Settings shell always opens from local state. When one destination cannot load or save, that detail pane retains its existing values and presents a concise inline error with Retry; the sidebar and every unrelated destination remain usable. A destination failure never replaces or dismisses the whole Settings workspace.
