import type { LuaFactory } from "wasmoon";
import type { BuildStats, Settings } from "./settings";

// Source is parsed by the uploaded compiler, never executed as user Lua.
export async function runEngine(factory: LuaFactory, modules: Record<string, string>, source: string, settings: Settings) {
  if (!source.trim()) throw new Error("Add some Lua or Luau code before obfuscating.");
  const { seed: rawSeed, ...options } = settings;
  const seed = rawSeed.trim() === "" ? Math.floor(Math.random() * 2147483646) + 1 : Number(rawSeed);
  if (!Number.isInteger(seed) || seed < 1 || seed > 2147483646) {
    throw new Error("Seed must be an integer between 1 and 2147483646.");
  }
  if (settings.antiBeautify && (!settings.minify || settings.debug)) {
    throw new Error("Anti-beautify requires minified output with debug mode off.");
  }
  const lua = await factory.createEngine();
  try {
    for (const [name, text] of Object.entries(modules)) {
      lua.global.set("__module_text", text);
      lua.global.set("__module_name", name);
      await lua.doString("package.preload[__module_name] = assert(load(__module_text, __module_name))");
    }
    lua.global.set("__source", source);
    // Every option is a typed scalar, passed as a global rather than interpolated code.
    await lua.doString("__options = {}");
    for (const [key, value] of Object.entries({ ...options, seed })) {
      lua.global.set("__key", key);
      lua.global.set("__value", value);
      await lua.doString("__options[__key] = __value");
    }
    await lua.doString(`
      __output, __stats = require('src.obfuscator').obfuscate(__source, __options)
      __stats_json = require('src.util').json(__stats)
    `);
    const output: unknown = lua.global.get("__output");
    const statsJson: unknown = lua.global.get("__stats_json");
    if (typeof output !== "string" || typeof statsJson !== "string") throw new Error("The engine returned an invalid result.");
    return { output, stats: JSON.parse(statsJson) as BuildStats };
  } finally {
    lua.global.close();
  }
}