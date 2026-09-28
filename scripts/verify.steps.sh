# Recovered from scripts/verify.sh by the harness: this project's own gate steps,
# moved here so the base file could converge. Edit freely — the harness
# installs this file once and never compares or overwrites it.

# SwiftPM. Until the package is scaffolded there is nothing to build, and the
# gate says so rather than reporting a green build it never ran.

if [ ! -f Package.swift ]; then
  echo "  skip  build   (no Package.swift yet — scaffold the package first)"
  echo "  skip  tests   (no Package.swift yet)"
else
  # Same stale-plan guard as scripts/app.sh (psy-rfun): a commit that adds a
  # psymail source file must re-plan, not fail the gate on a cached file list.
  # Through `step`, so a guard that fails says so — swallowed, it surfaces one
  # line later as a bare "cannot find X in scope", which is the exact confusion
  # it exists to prevent.
  step "plan" scripts/ensure-fresh-plan.sh
  step "build" swift build

  if [ "$mode" != "--quick" ]; then
    step "tests" swift test

    # "ok" alone can't tell a green suite from one that ran nothing, so surface
    # the count. swift-testing and XCTest word it differently; catch both.
    if [ -f "$LOGS/tests.log" ]; then
      grep -oE "[0-9]+ tests? passed|Executed [0-9]+ tests?" "$LOGS/tests.log" \
        | tail -1 | sed -e 's/^/        /'
    fi
  fi

  if [ "$mode" = "--full" ]; then
    # The app is a menu-bar panel: it needs a GUI session, so it only runs here.
    # Launching and quitting proves the status item and panel came up at all,
    # which no unit test in this project can.
    if [ -f scripts/smoke.sh ]; then
      step "smoke" scripts/smoke.sh
    fi
  fi
fi
