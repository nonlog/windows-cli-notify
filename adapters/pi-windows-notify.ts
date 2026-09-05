import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const NOTIFY_TIMEOUT_MS = 3000;

function assistantText(message: any): string {
  if (!message || message.role !== "assistant" || !Array.isArray(message.content)) return "";
  return message.content
    .filter((block: any) => block?.type === "text" && typeof block.text === "string")
    .map((block: any) => block.text)
    .join("\n")
    .trim();
}

function notifierScript(): string | undefined {
  if (process.env.AI_CLI_NOTIFY_SCRIPT) return process.env.AI_CLI_NOTIFY_SCRIPT;
  const packageScript = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "shared", "notify.ps1");
  if (existsSync(packageScript)) return packageScript;
  const home = process.env.USERPROFILE || process.env.HOME;
  if (!home) return undefined;
  return path.join(home, ".agent-hooks", "windows-notify", "shared", "notify.ps1");
}

async function notify(payload: Record<string, unknown>): Promise<void> {
  if (process.platform !== "win32") return;
  const script = notifierScript();
  if (!script) return;

  const systemRoot = process.env.SystemRoot || process.env.WINDIR;
  const powershell = systemRoot
    ? path.join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    : "powershell.exe";

  await new Promise<void>((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(
        powershell,
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script],
        { windowsHide: true, stdio: ["pipe", "ignore", "ignore"] },
      );
    } catch {
      resolve();
      return;
    }

    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timeout);
      resolve();
    };
    const timeout = setTimeout(() => {
      try { child.kill(); } catch {}
      finish();
    }, NOTIFY_TIMEOUT_MS);

    child.once("error", finish);
    child.once("close", finish);
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}

export default function (pi: ExtensionAPI) {
  let lastAssistantMessage = "";
  let lastCwd = "";

  pi.on("agent_start", () => {
    lastAssistantMessage = "";
  });

  pi.on("turn_end", (event, ctx) => {
    const text = assistantText(event.message);
    if (!text) return;
    lastAssistantMessage = text;
    lastCwd = ctx.cwd;
  });

  pi.on("agent_settled", async (_event, ctx) => {
    const message = lastAssistantMessage.trim();
    if (!message) return;
    const cwd = lastCwd || ctx.cwd;
    lastAssistantMessage = "";
    await notify({
      source: "Pi",
      event: "complete",
      title: "Pi completed",
      message,
      cwd,
    });
  });
}
