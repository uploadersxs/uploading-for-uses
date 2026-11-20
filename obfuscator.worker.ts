import { LuaFactory } from "wasmoon";
import wasmUrl from "wasmoon/dist/glue.wasm?url";
import { runEngine } from "./engine";
import type { Settings, WorkerResponse } from "./settings";

const files = import.meta.glob<string>("./lua/*.lua", { query: "?raw", import: "default", eager: true });
const modules = Object.fromEntries(Object.entries(files).map(([path, text]) => [
  `src.${path.split("/").at(-1)?.replace(/\.lua$/, "")}`, text,
]));
self.onmessage = async (event: MessageEvent<{ source: string; settings: Settings }>) => {
  try {
    const factory = new LuaFactory(new URL(wasmUrl, self.location.origin).href);
    const result = await runEngine(factory, modules, event.data.source, event.data.settings);
    self.postMessage({ ok: true, ...result } satisfies WorkerResponse);
  } catch (error) {
    self.postMessage({ ok: false, error: error instanceof Error ? error.message : String(error) } satisfies WorkerResponse);
  }
};