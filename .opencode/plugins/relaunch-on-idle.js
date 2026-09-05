// Auto-relaunch Control Center Pro when an opencode session goes idle with
// unlaunched code changes.
//
// Asking agents to "remember to relaunch" kept failing silently, so this
// enforces it instead: opencode fires session.idle whenever the agent
// finishes responding, and the guards below make acting on that safe.
//
// Each guard is load-bearing:
// - binary-mtime: only act when a watched source is newer than the built
//   binary (or the binary is missing). Docs-only sessions and repeat idles
//   are silent no-ops, and a red build retries on the next idle.
// - pre-check build: scripts/app.sh --launch quits the running app BEFORE
//   compiling, so a broken tree would leave the user app-less. Build first;
//   when red, skip quietly — the agent's own verify already reported it.
// - lockfile: two idles firing together must not yield two `open -n`
//   instances. A lock older than 15 minutes is a dead run's; reap it.
// - failure sentinel: a launch that dies after the quit must retry. The
//   mtime guard is consumed by a replaced-but-never-launched binary, so a
//   dead launch leaves a marker that forces the next idle to try again,
//   and a passing liveness check is what clears it.
//
// Escape hatches: CCP_NO_RELAUNCH=1 disables this entirely;
// CCP_RELAUNCH_DRY_RUN=1 logs what it would do without building, so a
// future session can prove the trigger without killing the running app.
export const RelaunchOnIdle = async ({ $, directory }) => {
  const LOG = "/tmp/ccp-relaunch.log";
  const LOCK = "/tmp/ccp-relaunch.lock";
  const SENTINEL = "/tmp/ccp-relaunch-failed";
  const PRODUCT = "ControlCenterPro";
  const BIN = `build/Control Center Pro.app/Contents/MacOS/${PRODUCT}`;
  const WATCH = "Sources AppBundle Package.swift Package.resolved scripts/app.sh";

  // A shell probe answers only whether it succeeded. Probes branch; they
  // are not errors, so they never throw.
  const probe = async (script) => {
    try {
      await $`bash -c ${script} >/dev/null 2>&1`;
      return true;
    } catch {
      return false;
    }
  };
  const log = (line) =>
    probe(`echo "[$(date -u +%FT%TZ)] ${line}" >> ${LOG}`);
  // The launched app takes a moment to appear; without the pause a fast
  // check reports a healthy launch dead.
  const launched = () =>
    probe(`sleep 2 && pgrep -f "/Contents/MacOS/${PRODUCT}" >/dev/null`);

  return {
    event: async ({ event }) => {
      if (event?.type !== "session.idle") return;
      if (process.env.CCP_NO_RELAUNCH === "1") return;

      // -H: on macOS /tmp is a symlink to private/tmp, which BSD find
      // will not descend into from the symlinked starting point.
      await probe(`find -H /tmp -maxdepth 1 -name ccp-relaunch.lock -mmin +15 -exec rm -rf {} +`);
      if (!(await probe(`mkdir ${LOCK}`))) return;
      try {
        const sourcesChanged = await probe(
          `test -e ${SENTINEL} || { cd "${directory}" && { test ! -x "${BIN}" || test -n "$(find ${WATCH} -newer "${BIN}" -print -quit)"; }; }`
        );
        if (!sourcesChanged) return;

        const isDryRun = process.env.CCP_RELAUNCH_DRY_RUN === "1";
        await log("sources newer than bundle binary - rebuilding");
        const buildPassed =
          isDryRun || (await probe(`cd "${directory}" && swift build --product ${PRODUCT} >> ${LOG} 2>&1`));
        if (!buildPassed) {
          const appDown = await probe(`test -e ${SENTINEL}`);
          await log(
            appDown
              ? "build red and a previous launch failed - app may be down; fix the build, the relaunch retries on its own"
              : "build red - leaving running app alone"
          );
          return;
        }
        if (isDryRun) {
          await log("dry run - would run scripts/app.sh --launch");
          return;
        }
        const relaunchOk = await probe(`cd "${directory}" && scripts/app.sh --launch >> ${LOG} 2>&1`);
        if (relaunchOk && (await launched())) {
          await probe(`rm -f ${SENTINEL}`);
          await log("relaunched");
        } else {
          await probe(`touch ${SENTINEL}`);
          await log("launch failed or app not running after launch - will retry; run scripts/app.sh --launch by hand if the app is down");
        }
      } finally {
        await probe(`rmdir ${LOCK}`);
      }
    },
  };
};
