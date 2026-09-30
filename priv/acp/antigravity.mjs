// The pinned wrapper turns a server panic into a successful end_turn. Change
// that response to an ACP error while preserving its process recovery state.
// This preload is inherited by child Node processes, so only patch the named
// package. The exact version and regression tests bound this compatibility fix.
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

async function preserveCrashErrors() {
  if (!process.argv[1]) return;
  let directory = dirname(realpathSync(process.argv[1]));

  while (true) {
    const metadata = join(directory, "package.json");
    if (existsSync(metadata)) {
      const pkg = JSON.parse(readFileSync(metadata, "utf8"));
      if (pkg.name !== "@simonepri/refined-antigravity-acp") return;
      if (pkg.version !== "1.2.11") {
        throw new Error("Harness requires refined-antigravity-acp 1.2.11 for its crash guard");
      }

      const module = pathToFileURL(join(directory, "dist/src/core/supervisor.js"));
      const { ProcessSupervisor } = await import(module.href);
      const original = ProcessSupervisor?.prototype?.declareHang;
      if (typeof original !== "function") {
        throw new Error("Unsupported Antigravity ACP supervisor contract");
      }

      ProcessSupervisor.prototype.declareHang = function (sessionId, promptId, reason) {
        const forward = this.forwardInbound;
        this.forwardInbound = (message) => {
          if (message.id === promptId && message.result?.stopReason === "end_turn") {
            return forward.call(this, {
              jsonrpc: "2.0",
              id: promptId,
              error: {
                code: -32603,
                message: "Antigravity ACP server crashed during the turn",
                data: { sessionId, reason },
              },
            });
          }
          return forward.call(this, message);
        };
        try {
          return original.call(this, sessionId, promptId, reason);
        } finally {
          this.forwardInbound = forward;
        }
      };
      return;
    }

    const parent = dirname(directory);
    if (parent === directory) return;
    directory = parent;
  }
}

try {
  await preserveCrashErrors();
} catch (error) {
  // A data-URL stack can fill the bounded stderr tail and hide the error.
  console.error(`[jido_harness][antigravity] ${error.message}`);
  process.exit(1);
}
