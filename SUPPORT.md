# Support

Control Center Pro is a free and open source project, looked after on a best
effort basis. There is no support contract and no promised response time.

CCP is **in development** — there are no releases yet, and the panel, lanes and
widget set are still being built. If you are here to use the app rather than
work on it, upstream's
[vorssaint-utils](https://github.com/vorssaintapp/vorssaint-utils) is the
shipping project.

## Report a bug

Open an issue on
[bubblesunyum/control-center-pro](https://github.com/bubblesunyum/control-center-pro/issues/new).
Please bring your macOS version, the commit you built from, and clear steps to
reproduce.

If the bug reproduces in upstream's app too, it is upstream's engine code and
belongs on [their tracker](https://github.com/vorssaintapp/vorssaint-utils/issues)
— we vendor that code and cannot fix it here without a patch that makes merges
more expensive.

## Request a feature

Open an issue on the same tracker. Describe the problem you want solved rather
than only a specific solution, since that makes the need much clearer.

## Report a security issue

Please keep security vulnerabilities out of public issues. The
[security policy](SECURITY.md) explains how to share them privately, and which
project to send them to.

## Documentation

- [README](README.md), what CCP is and how to build it
- [Architecture](ARCHITECTURE.md), the fork boundary and design philosophy
- [Brief](BRIEF.md), the implementation plan and feature inventory
- [Patches](PATCHES.md), local deviations from upstream
- [Trademarks](TRADEMARKS.md), the Vorssaint mark and fork identity

The following are upstream's documentation, kept as vendored from
vorssaint-utils. They describe upstream's shipping app, not CCP.

- [Privacy](docs/PRIVACY.md), what does and does not leave your Mac
- [Permissions](docs/PERMISSIONS.md), every macOS permission explained
- [Troubleshooting](docs/TROUBLESHOOTING.md), the common fixes
- [Contributing](CONTRIBUTING.md), upstream's build and contribution guide
