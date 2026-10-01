import { existsSync, readFileSync } from "node:fs";
import extension from "../adapters/pi-windows-notify.ts";

const lifecycle = new Map<string, Function[]>();
const eventHandlers = new Map<string, ((data: unknown) => void)[]>();

const pi = {
  on(name: string, handler: Function) {
    const handlers = lifecycle.get(name) ?? [];
    handlers.push(handler);
    lifecycle.set(name, handlers);
  },
  events: {
    on(channel: string, handler: (data: unknown) => void) {
      const handlers = eventHandlers.get(channel) ?? [];
      handlers.push(handler);
      eventHandlers.set(channel, handlers);
      return () => {
        eventHandlers.set(channel, (eventHandlers.get(channel) ?? []).filter((h) => h !== handler));
      };
    },
  },
};

extension(pi as any);

const cwd = "C:\\工作\\pi";
for (const handler of lifecycle.get("agent_start") ?? []) {
  handler({}, { cwd });
}

for (const handler of eventHandlers.get("rpiv:ask-user:prompt") ?? []) {
  handler({
    questions: [
      { question: "Pi 需要你选择哪个方案？", header: "方案", multiSelect: false, options: [] },
      { question: "是否继续？", header: "继续", multiSelect: false, options: [] },
    ],
  });
}

const target = process.env.AI_CLI_NOTIFY_TEST_OUTPUT;
if (!target) throw new Error("AI_CLI_NOTIFY_TEST_OUTPUT is required");

const deadline = Date.now() + 5000;
while (!existsSync(target) && Date.now() < deadline) {
  await new Promise((resolve) => setTimeout(resolve, 50));
}
if (!existsSync(target)) throw new Error("Pi question notification snapshot was not written");

const raw = readFileSync(target, "utf8").replace(/^\uFEFF/, "");
const result = JSON.parse(raw);
if (result.source !== "Pi" || result.event !== "needs_input" || result.title !== "Pi needs input") {
  throw new Error("Pi question notification metadata is incorrect");
}
if (!String(result.message).includes("Pi 需要你选择哪个方案？") || !String(result.message).includes("+1 more question")) {
  throw new Error("Pi question notification summary is incorrect");
}

console.log("Pi ask-user-question event notification passed.");
