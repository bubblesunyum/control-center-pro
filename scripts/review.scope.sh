# Recovered from scripts/review.sh by the harness: this project's own review scope,
# moved here so the base file could converge. Edit freely — the harness
# installs this file once and never compares or overwrites it.

# What a review is allowed to see: the app's source, and the harness that builds
# it. Include the harness — it grows enough code of its own to have bugs, and a
# scope that omits it means those never get reviewed. Exclude generated churn: a
# lockfile or project file whose ids got reshuffled, and the ledger export, are
# noise that dilutes the read.
# The docs are here from the start: a CLAUDE.md or a skill that quietly stopped
# being true is a defect the reviewers should see, and a suffix-only scope is
# also how a file with no extension stays unreviewable — list those by path.
#
# The big exclusion is upstream. Sources/Vorssaint and friends are a vendored
# fork, not our code, and an upstream merge would otherwise drop six figures of
# lines into the packet and drown the change actually under review. The one
# thing worth reviewing at that boundary — our adapters — lives in CCPKit and
# is still in scope.
# Config files are in scope: opencode.json is three lines that decide what every
# session in the project loads, and dashboard/index.html is the board itself —
# both went through a full review pass invisible while the scope had no *.json
# or *.html. JS and CSS went the same way with the Tiptap spike (ccp-5hpw), whose
# whole editor was JS the packet never showed — while its lockfile and the
# generated bundle it builds filled two thirds of it.
SCOPE=('*.swift' '*.py' '*.sh' '*.md' '*.html' '*.json' '*.js' '*.mjs' '*.css' '*.toml' '*.yaml'
       'Package.swift' 'scripts/hooks/*' '.agents/skills/*'
       ':(exclude)*package-lock.json' ':(exclude)Sources/CCPUI/Resources/NoteEditor/*'
       ':(exclude).beads/*' ':(exclude)dashboard/vendor/*'
       ':(exclude)dashboard/state.json' ':(exclude).claude/context.lock'
       ':(exclude)Sources/Vorssaint/*' ':(exclude)Sources/FanControlHelper/*'
       ':(exclude)Sources/VMStatisticsCompat/*' ':(exclude)Tools/*'
       ':(exclude)Tests/*' ':(exclude)docs/*' ':(exclude)CHANGELOG.md')

# Screenshots the design reviewer looks at. Whatever drives your app should
# write its captures to /tmp with this prefix — the ledger's, from _harness_prefix in scripts/review.sh, which sources this file.
CAPTURES="$(_harness_prefix)-*.png"
