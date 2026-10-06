# Project additions to the harness contract

Read this alongside `AGENTS.md` and `CLAUDE.md`. Add guidance specific to this
project here, such as which verification lane to run before a release.
The harness installs this file once and never compares or overwrites it.

## User-facing prose

Load the `output-style` skill before writing any communication, and apply it
without being asked: outcome before mechanism, short comprehensive bullets,
no file:line refs / hashes / gate internals by default, bad news first in
one line. The user explicitly asked for this style in all communication
(2026-10-06) after a wrap-up that buried the lead in internals.
