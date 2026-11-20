// @vitest-environment node
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { LuaFactory } from "wasmoon";
import { describe, expect, it } from "vitest";
import { runEngine } from "./engine";
import { defaultSettings, sampleSource } from "./settings";

const folder = fileURLToPath(new URL("./lua/", import.meta.url));
const modules = Object.fromEntries(readdirSync(folder).filter(name => name.endsWith(".lua")).map(name => [
  `src.${name.replace(/\.lua$/, "")}`, readFileSync(`${folder}/${name}`, "utf8"),
]));
describe("Original zz7 engine", () => {
  for (const profile of ["fast", "balanced", "max"] as const) {
    it(`compiles real Luau with the ${profile} profile`, async () => {
      const result = await runEngine(new LuaFactory(), modules, sampleSource, { ...defaultSettings(profile), seed: "12345" });
      expect(result.output).toContain("protected using zz7 obfuscator v1");
      expect(result.stats.seed).toBe(12345);
      expect(result.stats.profile).toBe(profile);
      expect(result.stats.mainPacked).toBe(profile !== "fast");
      expect(result.stats.outputBytes).toBe(Buffer.byteLength(result.output));
      expect(result.stats.sourceBytes).toBe(Buffer.byteLength(sampleSource));
    }, 30000);
  }
  it("reports parser errors without executing input", async () => {
    await expect(runEngine(new LuaFactory(), modules, "local = broken", defaultSettings())).rejects.toThrow();
  });
  it("produces statistics and a source map in debug mode", async () => {
    const result = await runEngine(new LuaFactory(), modules, "return 42", { ...defaultSettings("fast"), debug: true });
    expect(result.stats.debugMap).toBeDefined();
    expect(result.stats.settings["debug"]).toBe(true);
  });
});