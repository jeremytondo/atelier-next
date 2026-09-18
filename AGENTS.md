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

Atelier is one native Mac app and a command-line tool; it has no helper
programs. Each layer knows only the one below it: `App`, then `UI`, then
`AtelierKit`, then `MacOS`. `AtelierKit` is everything Atelier knows and does,
with nothing visible, and never learns that `UI` exists. It is organised by
subject, and each subject offers commands, queries, and events under grouped
names such as `desktops.new`. `UI` and the `atelier` command are two users of
the same `AtelierKit`; shortcuts, the leader menu, Spotlight, and the CLI all
run the same commands. If someone using only the CLI would want it, it belongs
in `AtelierKit`; if it is about what appears on screen, it belongs in `UI`.

Only `MacOS` touches Accessibility or private macOS calls, and workarounds for
macOS stay inside it. Requests to other apps run in the background with a short
time limit, so a frozen app holds up nothing else. The key-listening used by
the leader runs only while the leader is open and does almost no work itself;
the only listening that is always on is a modifier monitor for the window-list
hold.
Each piece of `UI` stands alone: pieces share only `Design` and get their
information from `AtelierKit`'s queries and events, never from a timer. The
core defaults are built in; `~/.config/atelier/config-next.toml` overrides them
and is read only at startup and on an explicit reload. A setting with a
problem is left out and reported, a file that cannot be parsed is refused
whole, and either way the bindings in effect are replaced together, never
mixed. Preserve user-owned configuration across updates.

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

- Use Swift Testing and small, hand-written fakes behind the interfaces the
  code already defines. Avoid adding third-party assertion or mocking
  frameworks.
- Use table tests where they clarify a set of cases, not as ritual.
- Test observable behavior and failure cases. Add concurrency deliberately
  when tests have isolated state and it provides a meaningful benefit.
- Run the smallest relevant mise checks while iterating. Before publishing
  a PR, run `mise run check`, the same gate CI uses.

## Reference Source

Research findings and experiment evidence live in Linear tickets and pull
requests, not in the repository. Do not add prototype trees, dated evidence
files, or research writeups to the checkout.

Two tags hold the Hammerspoon 2 version: `hammerspoon-final`, and
`hammerspoon-companion` for the `Atelier.app` project and the Spotlight
action. Their `api/`, `defaults/`, and `tests/` describe the behaviour the
native app must match, and the README there lists the manual trial. Read
behaviour and take individual files from them; never restore either tree
wholesale, and rework what you take, since its shape served Hammerspoon.

## Safety

- Use private, explicitly scoped state directories for tests. Do not change
  the developer's real configuration or run competing app instances.
- Test window and Space mutations only on disposable Desktops and saved
  test windows. Unit tests do not establish that macOS changed focus or Spaces.
- Before deleting or moving a Desktop, confirm exactly which Desktop is about
  to be acted on, immediately beforehand, and stop when that cannot be
  established. Never infer the target from its position.
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

Use mise tasks as the entry points for development and checks.
Use shell and native tools for repository automation; do not introduce Python.

Use the XcodeBuildMCP CLI skill for native Apple-platform build, test, run,
and debugging work.

Releases are manual. Pushes run checks only; do not add automatic
publication. `docs/releases.md` covers installing and releasing. Starting a
release publishes to the tap that installed copies update from, so it is the
user's decision each time; the `--dry-run` of `scripts/publish.sh` is how to
look first.

When delegating work, select a cost-appropriate model and review its output.
