// Shareable one-keystroke manual relaunch: `/launch` in any opencode client
// (desktop app included) rebuilds and relaunches the project app.
//
// The run command differs per project, so it comes from plugin options rather
// than living in this file. A consuming project configures it in its own
// opencode.json:
//
//   { "plugin": [["opencode-launch-button", { "command": "scripts/app.sh --launch" }]] }
//
// (or a relative path to this file until it is published to npm).
// Auto-discovered here via `.opencode/plugins/`, options are absent and the
// defaults below — this repo's launch script plus its relaunch protocol —
// apply. Every guard mirrors `.opencode/plugins/relaunch-on-idle.js`, whose
// header explains why each is load-bearing; the manual path is a second actor
// on the same lock/sentinel protocol, so it must speak it, not bypass it.
import type { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin"
import { appendFile, mkdir, rm, rmdir, stat, writeFile } from "node:fs/promises"

const DEFAULT_COMMAND = "scripts/app.sh --launch"
// Build first: the launch script quits the running app BEFORE compiling, so a
// red tree would leave the user app-less. A failing precheck reports and
// leaves the running app alone.
const DEFAULT_PRECHECK = "swift build --product ControlCenterPro"
const DEFAULT_LOCK = "/tmp/ccp-relaunch.lock"
const DEFAULT_SENTINEL = "/tmp/ccp-relaunch-failed"
const DEFAULT_LOG = "/tmp/ccp-relaunch.log"
const DEFAULT_EXPECT_PATTERN = "/Contents/MacOS/ControlCenterPro"
const STALE_LOCK_MINUTES = 15
const TAIL_LINES = 30

type LaunchOptions = {
  command?: string
  /** Command that must exit 0 before the launch runs. `false` disables. */
  precheck?: string | false
  /** mkdir-lock taken before running. `false` disables. */
  lockFile?: string | false
  /** Touched on launch failure, cleared on success, so an idle watcher can retry. `false` disables. */
  sentinel?: string | false
  /** Progress log. `false` disables. */
  logFile?: string | false
  /** pgrep -f pattern that must match after launching. `false` disables. */
  expectPattern?: string | false
}

type ResolvedOptions = {
  command: string
  precheck: string | null
  lockFile: string | null
  sentinel: string | null
  logFile: string | null
  expectPattern: string | null
}

const textOpt = (options: Record<string, unknown> | undefined, key: string, fallback: string): string => {
  const raw = options?.[key]
  return typeof raw === "string" && raw.trim() !== "" ? raw : fallback
}

const nullableOpt = (options: Record<string, unknown> | undefined, key: string, fallback: string): string | null => {
  if (options?.[key] === false) return null
  return textOpt(options, key, fallback)
}

const resolveOptions = (options?: Record<string, unknown>): ResolvedOptions => ({
  command: textOpt(options, "command", DEFAULT_COMMAND),
  precheck: nullableOpt(options, "precheck", DEFAULT_PRECHECK),
  lockFile: nullableOpt(options, "lockFile", DEFAULT_LOCK),
  sentinel: nullableOpt(options, "sentinel", DEFAULT_SENTINEL),
  logFile: nullableOpt(options, "logFile", DEFAULT_LOG),
  expectPattern: nullableOpt(options, "expectPattern", DEFAULT_EXPECT_PATTERN),
})

const tail = (output: string): string => {
  const trimmed = output.trim().split("\n").slice(-TAIL_LINES).join("\n")
  return trimmed === "" ? "(no output)" : trimmed
}

export const LaunchButton: Plugin = async ({ $, directory }, options) => {
  const opts = resolveOptions(options as Record<string, unknown> | undefined)

  const log = async (line: string): Promise<void> => {
    if (!opts.logFile) return
    try {
      await appendFile(opts.logFile, `[${new Date().toISOString()}] ${line}\n`)
    } catch {
      // Logging must never fail the launch.
    }
  }

  // `2>&1`: the output object only carries stdout in `.text()`.
  const run = async (cmd: string, cwd: string): Promise<{ exit: number; output: string }> => {
    const result = await $`bash -lc ${cmd} 2>&1`.cwd(cwd).nothrow().quiet()
    return { exit: result.exitCode, output: result.text() }
  }

  const takeLock = async (): Promise<boolean> => {
    if (!opts.lockFile) return true
    try {
      const info = await stat(opts.lockFile)
      // `rmdir`: the lock is always an empty dir this protocol created; refuse
      // rather than delete anything else under a misconfigured path.
      if (Date.now() - info.mtimeMs > STALE_LOCK_MINUTES * 60_000) await rmdir(opts.lockFile)
    } catch {
      // Missing lock (or an undeletable one) — mkdir below decides.
    }
    try {
      await mkdir(opts.lockFile)
      return true
    } catch {
      return false
    }
  }

  const releaseLock = async (): Promise<void> => {
    if (!opts.lockFile) return
    try {
      // No `recursive`: the lock is always an empty dir this protocol created;
      // refuse rather than delete anything else under a misconfigured path.
      await rmdir(opts.lockFile)
    } catch {
      // Best effort; a stale lock is reaped on the next run.
    }
  }

  return {
    // Injects the `/launch` slash command so consuming projects need no
    // `.opencode/command/launch.md` of their own. `??=` keeps a local file
    // (this repo has one) authoritative when both exist.
    config: async (cfg) => {
      const commands = ((cfg as { command?: Record<string, Record<string, unknown>> }).command ??= {})
      commands["launch"] ??= {
        description: "Rebuild and relaunch the app",
        template:
          "Use the launch_app tool to rebuild and relaunch the app now. Do not run the launch script via bash — call launch_app.",
      }
    },
    tool: {
      launch_app: tool({
        description: `Rebuild and relaunch the project app (runs \`${opts.command}\`). Use when the user types /launch or asks to relaunch the app.`,
        args: {},
        execute: async (_args, ctx) => {
          ctx.metadata({ title: "Relaunching app" })
          const cwd = ctx.directory ?? directory
          if (ctx.abort.aborted) return "cancelled before starting — nothing was run"
          if (!(await takeLock())) return "another relaunch is already running — try again when it finishes"
          try {
            await log(`manual /launch: ${opts.command}`)
            if (opts.precheck) {
              const pre = await run(opts.precheck, cwd)
              if (pre.exit !== 0) {
                await log("precheck failed - leaving running app alone")
                return `build is red — leaving the running app alone:\n${tail(pre.output)}`
              }
            }
            // The shell exposes no kill wiring, so a cancel mid-flight cannot
            // stop the spawned script; checking here at least covers a cancel
            // during the (minutes-long) precheck: the quit-and-relaunch below
            // never starts.
            if (ctx.abort.aborted) return "cancelled after the build — launch script NOT run, app left alone"
            let launched: { exit: number; output: string }
            try {
              launched = await run(opts.command, cwd)
            } catch (error) {
              return `launch failed before the script ran: ${error instanceof Error ? error.message : String(error)}`
            }
            // `sleep 2`: the relaunched app takes a moment to appear; without
            // the pause a fast check reports a healthy launch dead.
            const alive =
              !opts.expectPattern ||
              (await run(`sleep 2 && pgrep -f "${opts.expectPattern}" >/dev/null`, cwd)).exit === 0
            if (launched.exit === 0 && alive) {
              if (opts.sentinel) await rm(opts.sentinel, { force: true }).catch(() => {})
              await log("relaunched")
              return `relaunched:\n${tail(launched.output)}`
            }
            if (opts.sentinel) await writeFile(opts.sentinel, "").catch(() => {})
            await log("launch failed or app not running after launch - will retry; run the script by hand if the app is down")
            return (
              `launch may have failed (exit ${launched.exit}, app ${alive ? "running" : "NOT running"}) — ` +
              `marked for retry on the next idle; if the app is down, run the script by hand:\n${tail(launched.output)}`
            )
          } finally {
            await releaseLock()
          }
        },
      }),
    },
  }
}

export default LaunchButton
