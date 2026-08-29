# Security Policy

Thanks for helping keep Control Center Pro and the people who use it safe.

Control Center Pro is a fork of
[vorssaint-utils](https://github.com/vorssaintapp/vorssaint-utils) and vendors
upstream's engine code. Where a vulnerability lives decides who should hear
about it — please read the routing note below before you report.

## Reporting a vulnerability

Report security vulnerabilities in private. Do not open a public issue, pull
request or discussion for them.

- **[Report a vulnerability privately](https://github.com/bubblesunyum/control-center-pro/security/advisories/new)**

That opens a private security advisory only you and the maintainers can see.

### Which project to report to

- **CCP's own code** — anything under `Sources/CCPKit`, `Sources/CCPUI`,
  `Sources/ControlCenterPro`, or the build and harness scripts. Report it here.
- **Vendored upstream code** — anything under `Sources/Vorssaint`,
  `Sources/VMStatisticsCompat`, or `Sources/FanControlHelper`. That code is
  upstream's and a fix belongs upstream, so report it to
  [vorssaint-utils](https://github.com/vorssaintapp/vorssaint-utils/security/advisories/new).
  Tell us here too if you can — we vendor that code and need to pick the fix up.
- **Not sure which?** Report it here and we will route it.

When you write it up, please include as much as you can.

- A description of the issue and the impact it could have.
- Steps to reproduce, or a proof of concept.
- Your macOS version and the commit you built from.

## What to expect

- This is a small project looked after on a best effort basis, so please allow
  reasonable time for a reply and a fix.
- Please give us a chance to ship a fix before discussing the issue in public.
  That is what coordinated disclosure means.
- Credit goes gladly to reporters who want it.

## Supported versions

Control Center Pro is in development and has no releases yet. Security fixes
land on `main`; please reproduce against the current `main` before reporting.

## Scope

CCP runs locally as a macOS menu bar app. The reports that matter most are the
ones that could affect the integrity of the app or let the macOS permissions it
holds be misused. Issues in outside services the app merely talks to are best
taken to those providers.
