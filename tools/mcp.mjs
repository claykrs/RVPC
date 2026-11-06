// mcp.mjs -- drive the Roblox Studio MCP stdio server directly.
// Usage: node mcp.mjs list
//        node mcp.mjs call <toolName> <jsonArgs>
// Spawns mcp.bat, performs initialize handshake, sends the request, prints
// the JSON result to stdout.

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

const bat = join(homedir(), "AppData", "Local", "Roblox", "mcp.bat");

const [,, mode, toolName, rawArgs] = process.argv;
import { readFileSync } from "node:fs";

const proc = spawn("cmd.exe", ["/c", bat], { stdio: ["pipe", "pipe", "pipe"] });

let buf = "";
const pending = new Map();
let nextId = 1;

proc.stdout.on("data", (chunk) => {
	buf += chunk.toString("utf8");
	let idx;
	while ((idx = buf.indexOf("\n")) >= 0) {
		const line = buf.slice(0, idx).trim();
		buf = buf.slice(idx + 1);
		if (!line) continue;
		try {
			const msg = JSON.parse(line);
			if (msg.id !== undefined && pending.has(msg.id)) {
				pending.get(msg.id)(msg);
				pending.delete(msg.id);
			} else {
				// notification/log: print compactly to stderr
				console.error("<<", JSON.stringify(msg).slice(0, 300));
			}
		} catch {}
	}
});
proc.stderr.on("data", (c) => console.error("[srv-err]", c.toString().trim().slice(0, 200)));

function request(method, params, timeoutMs = 120000) {
	const id = nextId++;
	return new Promise((resolve, reject) => {
		pending.set(id, resolve);
		const timer = setTimeout(() => { pending.delete(id); reject(new Error("timeout: " + method)); }, timeoutMs);
		const wrapped = (msg) => { clearTimeout(timer); resolve(msg); };
		pending.set(id, wrapped);
		proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
	});
}
function notify(method, params) {
	proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

const init = await request("initialize", {
	protocolVersion: "2024-11-05",
	capabilities: {},
	clientInfo: { name: "zcode-direct", version: "1.0" },
});
notify("notifications/initialized", {});

if (mode === "list") {
	const res = await request("tools/list", {});
	for (const t of res.result?.tools ?? []) {
		console.log(t.name + " -- " + (t.description ?? "").split("\n")[0].slice(0, 110));
	}
} else if (mode === "call") {
	const args = rawArgs ? JSON.parse(rawArgs) : {};
	const res = await request("tools/call", { name: toolName, arguments: args });
	console.log(JSON.stringify(res, null, 1).slice(0, 12000));
} else if (mode === "callfile") {
	const args = JSON.parse(readFileSync(rawArgs, "utf8"));
	const res = await request("tools/call", { name: toolName, arguments: args }, 180000);
	console.log(JSON.stringify(res));
} else {
	console.error("usage: node mcp.mjs list | call <tool> <json>");
}

proc.stdin.end();
await new Promise((r) => setTimeout(r, 300));
proc.kill();
process.exit(0);