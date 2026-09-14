# Atelier Next

Atelier is a customizable macOS workspace built on Hammerspoon 2.

## Application

[Atelier for macOS](App/README.md) packages HS2 with JavaScript defaults for native Spaces, Groups, and Quick Apps, plus a native helper for missing capabilities. Build and install with `mise run dev`; see the app README for configuration and permissions, and [releasing](docs/releases.md) for rolling dev builds and stable semantic releases.

## Reference source

`mise run refs` creates a shallow checkout of [Hammerspoon 2](https://github.com/cmsj/Hammerspoon2) under `repos/hammerspoon2`. This directory is gitignored and used only for research. `mise run refs:update` fast-forwards it to upstream `main`, refusing local edits or commits; `mise run refs:status` shows the current revision and checkout state. Existing checkouts are left unchanged by `mise run refs`.
