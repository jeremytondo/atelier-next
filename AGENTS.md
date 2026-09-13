# Atelier Agent Instructions

## Core Principles

Maintain these principles as the project evolves:

- Performance
- Reliability
- Simplicity
- User experience

If a tradeoff is required, choose correctness and robustness over short-term
convenience.

## Recorded Decisions

Recorded decisions and rules capture the best understanding at the time,
not permanent truth. When the work surfaces evidence that a prior decision
is wrong or improvable, challenge it openly and propose amending the record;
do not follow it blindly or deviate from it silently.

## Maintainability

Hammerspoon 2 is Atelier's application and automation foundation. Implement
customizable defaults through its JavaScript APIs first. Add native mechanisms
only for demonstrated gaps, keep upstream integration patches small, and preserve
user-owned configuration across updates.

Long-term maintainability is a core priority. Prefer shared, plainly named
logic over duplication, and change an existing design when that produces a
simpler system. Code should be easy to understand, work with, and test.

## Documentation

Documentation defaults to the code. A module header should record its
responsibility and non-obvious invariants; comments should explain surprising
constraints, not narrate control flow.

Keep this file limited to facts and priorities that cannot be learned by
reading the implementation. READMEs cover how to run a thing, where its data
lives, and which task to use. They should point to references and `--help`
rather than enumerate details that can drift.

## Testing

- Use the existing testing tools and small, hand-written fakes behind the
  interfaces the code already defines. Avoid adding third-party assertion
  or mocking frameworks.
- Use table tests where they clarify a set of cases, not as ritual.
- Test observable behavior and failure cases. Add concurrency deliberately
  when tests have isolated state and it provides a meaningful benefit.
- Run the smallest relevant mise checks while iterating. Before publishing
  a PR, run `mise run check`, the same gate CI uses.

## Experiments and Reference Source

Everything under `Prototypes/` is historical research material, not
production source:

- Read findings before code.
- Treat findings as evidence, not decisions.
- Do not import, extend, or make production depend on prototype code.
- Do not rewrite old findings. Capture new evidence separately.

Reference checkouts under `repos/` are read-only research material. Use
`mise run refs` to fetch missing checkouts and `mise run refs:update` to
refresh them from upstream. Never edit their source, import from them, or
copy them wholesale into the product. They must remain gitignored and
independent of app builds and releases.

## Safety

- Use private, explicitly scoped state directories for tests. Do not change
  the developer's real configuration or run competing app instances.
- Test window and Space mutations only on disposable Desktops and saved
  test windows. Unit tests do not establish that macOS changed focus or Spaces.
- Never kill processes by name or pattern. Kill only a PID captured when
  starting a process for the current task.
- Preserve unrelated working-copy changes.

## Source Control

This is a Jujutsu repository. Do not use `git add`, `git commit`,
`git stash`, or `git checkout` in this repository.

Use `jj describe -m "<message>"` followed by `jj new` to checkpoint a logical
change after its checks pass. Keep unrelated changes separate. If a code
change breaks the build, revert only that attempted change; use `jj undo`
only when it preserves unrelated work. Use a jj bookmark when pushing work
to the Git remote.

Run `gh` commands as standalone shell commands; do not combine them with
other commands.

## Project Tools

Use mise tasks as the entry points for development, checks, and releases.
Use shell and native tools for repository automation; do not introduce Python.

Use the XcodeBuildMCP CLI skill for native Apple-platform build, test, run,
and debugging work.

Both dev and stable releases are manual. Use `mise run release:dev`,
`release:patch`, `release:minor`, or `release:major` when publication is
requested. Pushes to `main` run checks only; do not add automatic publication.

When delegating work, select a cost-appropriate model and review its output.
