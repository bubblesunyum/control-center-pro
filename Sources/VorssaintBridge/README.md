Visibility shims, not a second adapter layer.

Every upstream type is `internal`, and `VorssaintEngines` is a module, so
nothing under `Sources/Vorssaint` is visible to CCPKit. These files are
compiled into that same module (see `sources:` in Package.swift), which makes
them module-mates of upstream and lets them re-export what CCP needs as
`public`.

The rule that keeps this directory from growing into a place where decisions
live: **a shim may restate a type, but it may not decide anything about one.**
No stored state, no policy, no branch that could have gone the other way. A
`switch` that maps an upstream enum onto a public one is a restatement and is
fine — it has exactly one correct form. Anything with a judgement call in it is
an adapter, and adapters live in `Sources/CCPKit/Adapters`.

The tells that this rule is slipping: a shim with a stored property, a shim
CCPKit uses as though it were already adapted, or a shim long enough that you
have to read it twice.
