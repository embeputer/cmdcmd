#!/usr/bin/env node
// mock-agent.mjs — a tiny ACP server for exercising cmdcmd end-to-end.
// Speaks NDJSON JSON-RPC over stdio. Streams thoughts + messages, asks the
// client to read a file, runs a terminal, and requests a permission —
// everything the popup UI has to handle.
//
// Usage as an agent command in cmdcmd config:
//   node /path/to/scripts/mock-agent.mjs

import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin });
const pending = new Map(); // our requests to the client
let nextId = 1000;

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}
function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}
function replyErr(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}
function askClient(method, params) {
  const id = nextId++;
  send({ jsonrpc: "2.0", id, method, params });
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}
function update(sessionId, update) {
  send({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update } });
}
const textChunk = (text) => ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const thinkChunk = (text) => ({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

rl.on("line", async (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }

  // responses to our own client-side requests
  if (msg.id != null && msg.method == null) {
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
    }
    return;
  }
  if (msg.method == null || msg.id == null) return; // notifications ignored

  const { id, method, params = {} } = msg;

  switch (method) {
    case "initialize":
      reply(id, {
        protocolVersion: 1,
        agentCapabilities: {
          loadSession: false,
          promptCapabilities: { image: true, embeddedContext: true },
        },
        agentInfo: { name: "mock-agent", title: "Mock Agent", version: "0.1.0" },
        authMethods: [],
      });
      break;

    case "authenticate":
      reply(id, {});
      break;

    case "session/new": {
      reply(id, {
        sessionId: "mock-session-1",
        modes: {
          currentModeId: "ask",
          availableModes: [
            { id: "ask", name: "Ask", description: "answer questions only" },
            { id: "code", name: "Code", description: "read + write + run" },
          ],
        },
      });
      update(params.sessionId || "mock-session-1", {
        sessionUpdate: "available_commands_update",
        availableCommands: [
          { name: "status", description: "show agent status" },
          { name: "compact", description: "compact the conversation" },
          { name: "context", description: "show context usage" },
        ],
      });
      break;
    }

    case "session/load":
      reply(id, {});
      break;

    case "session/set_mode":
      reply(id, {});
      update(params.sessionId, {
        sessionUpdate: "current_mode_update",
        currentModeId: params.modeId,
      });
      break;

    case "session/prompt":
      replyLater(id, params).catch(() => {});
      break;

    default:
      replyErr(id, -32601, `mock-agent: unknown method ${method}`);
  }
});

async function replyLater(id, params) {
  const sid = params.sessionId;
  const prompt = params.prompt || [];
  const kinds = prompt.map((b) => b.type).join("+");
  const userText = (prompt.find((b) => b.type === "text") || {}).text || "";
  const hasImage = prompt.some((b) => b.type === "image" || b.type === "resource_link");

  update(sid, thinkChunk("looking at what you sent…"));
  await sleep(250);
  update(sid, thinkChunk(`prompt has ${prompt.length} block(s): ${kinds}`));
  await sleep(250);

  update(sid, textChunk(`Got it — "${userText.slice(0, 80)}". `));
  if (hasImage) update(sid, textChunk("I can see your screenshot. "));
  update(sid, textChunk("Let me check a few things on your Mac.\n"));

  // fs/read_text_file — client must answer
  try {
    const res = await askClient("fs/read_text_file", {
      sessionId: sid, path: "/etc/hostname", line: 1, limit: 1,
    });
    update(sid, textChunk(`\nYour hostname is \`${String(res.content || "").trim()}\`.\n`));
  } catch {
    update(sid, textChunk("\n(couldn't read /etc/hostname)\n"));
  }

  // terminal lifecycle — client must answer
  try {
    const { terminalId } = await askClient("terminal/create", {
      sessionId: sid, command: "uname -sm && date +%H:%M",
    });
    update(sid, {
      sessionUpdate: "tool_call",
      toolCallId: "tc-uname", title: "uname -sm && date +%H:%M",
      kind: "execute", status: "in_progress",
      locations: [], content: [], rawInput: { command: "uname -sm && date +%H:%M" },
    });
    const out = await askClient("terminal/output", { sessionId: sid, terminalId });
    await askClient("terminal/wait_for_exit", { sessionId: sid, terminalId });
    await askClient("terminal/release", { sessionId: sid, terminalId });
    update(sid, {
      sessionUpdate: "tool_call_update",
      toolCallId: "tc-uname", status: "completed",
    });
    update(sid, textChunk(`\nRan it: \`${out.output.trim().split("\n")[0]}\`\n`));
  } catch (e) {
    update(sid, textChunk(`\n(terminal failed: ${e.message})\n`));
  }

  // plan update
  update(sid, {
    sessionUpdate: "plan",
    entries: [
      { content: "Read the screenshot", status: "completed", priority: "high" },
      { content: "Ask permission for the risky bit", status: "in_progress", priority: "high" },
      { content: "Wrap up", status: "pending", priority: "low" },
    ],
  });

  // permission request — popup should show buttons; we wait for the answer
  try {
    const res = await askClient("session/request_permission", {
      sessionId: sid,
      toolCall: {
        toolCallId: "tc-perm", title: "Install a fake package (demo)",
        kind: "execute", status: "pending", locations: [], content: [],
      },
      options: [
        { optionId: "allow_once", name: "Allow once", kind: "allow_once" },
        { optionId: "allow_always", name: "Always allow", kind: "allow_always" },
        { optionId: "reject_once", name: "Reject", kind: "reject_once" },
      ],
    });
    const sel = res?.outcome?.optionId || "cancelled";
    update(sid, textChunk(`\nPermission answer: **${sel}**.\n`));
  } catch {
    update(sid, textChunk("\n(permission request failed)\n"));
  }

  update(sid, {
    sessionUpdate: "tool_call_update",
    toolCallId: "tc-perm", status: "completed",
  });
  update(sid, textChunk("\nAll mock steps done — cmdcmd's ACP path works."));
  reply(id, { stopReason: "end_turn" });
}
