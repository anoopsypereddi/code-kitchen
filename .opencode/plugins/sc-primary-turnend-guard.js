import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

// OpenCode Stop-equivalent for the souschef PRIMARY turn-end guard. OpenCode's
// session.idle event is passive - it cannot block - so this plugin runs the
// shared bin/sc-turnend-guard.sh predicate and, when it says the turn would end
// blind, forces one same-session follow-up via client.session.promptAsync.
// skipNextIdle is the loop guard: the forced follow-up's own idle event is
// swallowed so the guard never nags twice in one turn.
//
// NOTE: souschef does not ship the event-driven auto-arm plugin (firstmate's
// fm-primary-watch-arm.js), which is a separate capability beyond findings #2/#9.
// This guard therefore fires standalone off the shared predicate rather than
// deferring to an in-process arm coordinator. The shared guard is inert outside
// the real primary checkout, so a crewmate/scout worktree is never affected.

let skipNextIdle = false;

function runProcess(command, args, input = "") {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/sc-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

export const ScPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [
              {
                type: "text",
                text:
                  "TURN WOULD END BLIND - supervision is off. " +
                  "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
                  result.stderr,
              },
            ],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};
