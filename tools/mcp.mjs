// mcp.mjs -- drive the Roblox Studio MCP stdio server directly.
//
// Usage: node tools/mcp.mjs list
//        node tools/mcp.mjs call <toolName> <jsonArgs>
//        node tools/mcp.mjs callfile <toolName> <argsFile.json>
//
// Spawns the Studio MCP launcher, performs the initialize handshake, sends one
// request, prints the JSON result to stdout and exits.
//
// Environment:
//   STUDIO_MCP_BAT   override the launcher path
//                    (default: %LOCALAPPDATA%\Roblox\mcp.bat)
//   MCP_RESULT_FILE  also write the raw JSON result to this path

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LAUNCHER =
	process.env.STUDIO_MCP_BAT ?? join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local"), "Roblox", "mcp.bat");
const DEFAULT_TIMEOUT_MS = 120_000;
const CALLFILE_TIMEOUT_MS = 180_000;
const USAGE = "usage: node tools/mcp.mjs list | call <tool> <json> | callfile <tool> <file>";

const [, , mode, toolName, rawArgs] = process.argv;
if (!["list", "call", "callfile"].includes(mode ?? "")) {
	console.error(USAGE);
	process.exit(2);
}

const proc = spawn("cmd.exe", ["/c", LAUNCHER], { stdio: ["pipe", "pipe", "pipe"] });
proc.on("error", (err) => {
	console.error(`failed to start ${LAUNCHER}: ${err.message}`);
	process.exit(1);
});

const pending = new Map();
let nextId = 1;
let buffer = "";

proc.stdout.on("data", (chunk) => {
	buffer += chunk.toString("utf8");
	let newline;
	while ((newline = buffer.indexOf("\n")) >= 0) {
		const line = buffer.slice(0, newline).trim();
		buffer = buffer.slice(newline + 1);
		if (!line) continue;
		let message;
		try {
			message = JSON.parse(line);
		} catch {
			continue;
		}
		const resolve = message.id !== undefined ? pending.get(message.id) : undefined;
		if (resolve) {
			pending.delete(message.id);
			resolve(message);
		} else {
			console.error("<<", JSON.stringify(message).slice(0, 300));
		}
	}
});
proc.stderr.on("data", (chunk) => console.error("[srv-err]", chunk.toString().trim().slice(0, 200)));

function request(method, params, timeoutMs = DEFAULT_TIMEOUT_MS) {
	const id = nextId++;
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			pending.delete(id);
			reject(new Error(`timeout: ${method}`));
		}, timeoutMs);
		pending.set(id, (message) => {
			clearTimeout(timer);
			resolve(message);
		});
		proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
	});
}

function notify(method, params) {
	proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

function finish(code) {
	proc.stdin.end();
	setTimeout(() => {
		proc.kill();
		process.exit(code);
	}, 300);
}

try {
	await request("initialize", {
		protocolVersion: "2024-11-05",
		capabilities: {},
		clientInfo: { name: "rvpc-tools", version: "1.0" },
	});
	notify("notifications/initialized", {});

	if (mode === "list") {
		const response = await request("tools/list", {});
		for (const tool of response.result?.tools ?? []) {
			console.log(`${tool.name} -- ${(tool.description ?? "").split("\n")[0].slice(0, 110)}`);
		}
	} else {
		if (!toolName) throw new Error(USAGE);
		const args = mode === "callfile" ? JSON.parse(readFileSync(rawArgs, "utf8")) : rawArgs ? JSON.parse(rawArgs) : {};
		const timeout = mode === "callfile" ? CALLFILE_TIMEOUT_MS : DEFAULT_TIMEOUT_MS;
		const response = await request("tools/call", { name: toolName, arguments: args }, timeout);
		const json = JSON.stringify(response);
		if (process.env.MCP_RESULT_FILE) writeFileSync(process.env.MCP_RESULT_FILE, json);
		console.log(json);
	}
	finish(0);
} catch (err) {
	console.error(err instanceof Error ? err.message : String(err));
	finish(1);
}
