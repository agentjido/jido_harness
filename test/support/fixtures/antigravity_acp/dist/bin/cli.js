#!/usr/bin/env node
import readline from "node:readline";
import { ProcessSupervisor } from "../src/core/supervisor.js";

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const supervisor = new ProcessSupervisor(send);
const sessionId = "antigravity-fixture-session";
const result = (id, value) => send({ jsonrpc: "2.0", id, result: value });
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  switch (message.method) {
    case "initialize":
      result(message.id, {
        protocolVersion: 1,
        agentCapabilities: { loadSession: true },
        authMethods: [],
      });
      break;
    case "session/new":
    case "session/load":
      result(message.id, { sessionId });
      break;
    case "session/prompt": {
      const text = message.params.prompt.map((block) => block.text ?? "").join(" ");
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: text.includes("panic") ? "partial-output" : "fixture-ok" },
          },
        },
      });
      if (text.includes("panic")) supervisor.declareHang(sessionId, message.id, "hang");
      else result(message.id, { stopReason: "end_turn" });
      break;
    }
    case "session/close":
    case "session/set_config_option":
      result(message.id, {});
      break;
    default:
      send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } });
  }
}
