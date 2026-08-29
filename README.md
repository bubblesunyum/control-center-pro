<h1 align="center">Control Center Pro</h1>

<p align="center">
  System utilities in a single, blurred, macOS-Control-Center-style panel.<br>
  A fork of vorssaint-utils with its own independent UI.
</p>

<p align="center">
  <a href="#what-it-is">About</a> ·
  <a href="#build-it-yourself">Build</a> ·
  <a href="#fork-and-attribution">Fork &amp; attribution</a> ·
  <a href="ARCHITECTURE.md">Architecture</a>
</p>

<p align="center">
  <a href="#what-you-need"><img src="https://img.shields.io/badge/macOS-14.4%2B%20Apple%20Silicon-black" alt="macOS 14.4 and newer, Apple Silicon"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="License GPL 3.0 or later"></a>
</p>

Control Center Pro is a macOS menu bar app in development. When complete it
will present system utilities in a single blurred, glassy panel — opening from
the menu bar at the top-right and expanding across the width of the screen as
needed. Content is organized into **vertical lanes**; each lane stacks one or
more widgets, which you rearrange in an iOS-style **edit mode**. The layout and
targets are in place and the engine layer is vendored; the panel, lanes, and
widget set are being built out.

## What it is

A macOS menu bar app built on the feature engines of
[**vorssaint-utils**](https://github.com/vorssaintapp/vorssaint-utils), a
GPL-3.0-or-later project. CCP is developed as a **fork** of vorssaint-utils that
adds its own app target on top of upstream's engine code — kept vendored and in
sync (with only minimal local deviations, tracked in [PATCHES.md](./PATCHES.md))
so new upstream features can be merged in cheaply.

CCP does **not** embed or copy Vorssaint's UI. All of CCP's UI — the glass
shell, lanes, widgets, and edit mode — is written from scratch in `Sources/CCPUI`
against `Sources/CCPKit` adapters that wrap upstream's services.

## License

[GPL 3.0 or later](LICENSE), copyright 2026 Control Center Pro contributors.

Control Center Pro is a fork of
[vorssaint-utils](https://github.com/vorssaintapp/vorssaint-utils), © Vorssaint
contributors, also GPL-3.0-or-later. Upstream's source headers are preserved
intact under `Sources/Vorssaint/`.

## Fork and attribution

- **Vendored source.** Everything under `Sources/Vorssaint/`,
  `Sources/VMStatisticsCompat`, and `Sources/FanControlHelper` is vendored from
  vorssaint-utils. It is © Vorssaint contributors, GPL-3.0-or-later, and kept in
  sync with upstream; the only local deviations are the minimal patches tracked
  in [PATCHES.md](./PATCHES.md). CCP builds only the engine layer — upstream's
  own app and UI sources under `Sources/Vorssaint/` are excluded from the compile.
- **Independent UI.** The Control Center Pro interface, lanes, and widget system
  are CCP's own work and share no code with Vorssaint's interface.
- **No Vorssaint branding.** The Vorssaint name, logo, icon, bundle identity,
  and trade dress are the property of the project maintainer. CCP uses none of
  them in its own sources, and presents no modified build as Vorssaint or as an
  official Vorssaint release. See [TRADEMARKS.md](./TRADEMARKS.md).

## What you need

- A Mac with Apple Silicon
- macOS 14.4 or newer

### Build it yourself

```sh
git clone https://github.com/bubblesunyum/control-center-pro.git
cd control-center-pro
swift build           # compile the package
```

Xcode Command Line Tools are the only requirement.

There is no CCP app bundle to install yet. `build.sh` is upstream's packaging
script, inherited by the fork: it still builds a bundle named and identified as
Vorssaint (`com.vorssaint.utils`), which is exactly what
[TRADEMARKS.md](./TRADEMARKS.md) says a fork must not ship. Giving CCP its own
bundle identity is tracked as `ccp-v64`; until that lands, don't use `build.sh`
to produce something you intend to run or distribute as Control Center Pro.

[ARCHITECTURE.md](./ARCHITECTURE.md) documents the fork boundary and design
philosophy.

## Documentation

- [Architecture](ARCHITECTURE.md), the fork boundary and design philosophy
- [Brief](BRIEF.md), the implementation plan and feature inventory
- [Patches](PATCHES.md), local deviations from upstream
- [Support](SUPPORT.md), where to get help
- [Security](SECURITY.md), how to report a vulnerability
- [Trademarks](TRADEMARKS.md), the Vorssaint mark and fork identity

Vendored from upstream and describing upstream's shipping app, not CCP:
[CONTRIBUTING.md](CONTRIBUTING.md), [CHANGELOG.md](CHANGELOG.md), and
everything under [docs/](docs/).

## Acknowledgements

- The feature engines this project builds on come from
  [vorssaint-utils](https://github.com/vorssaintapp/vorssaint-utils), © Vorssaint
  contributors, GPL-3.0-or-later.
