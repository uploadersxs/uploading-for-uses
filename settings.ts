export type Profile = "fast" | "balanced" | "max";
export type CacheMode = "prototype" | "execution" | "none";
export type HookMode = "off" | "identity" | "strict";
export interface Settings {
  profile: Profile;
  seed: string;
  junk: number;
  main: boolean;
  cff: boolean;
  opaque: boolean;
  antiTamper: boolean;
  antiHooks: HookMode;
  antiBeautify: boolean;
  compression: boolean;
  minify: boolean;
  optimize: boolean;
  compact: boolean;
  lazyConstants: boolean;
  prune: boolean;
  nativeHelpers: boolean;
  cooperative: boolean;
  yieldBudgetMs: number;
  lazyInstructions: boolean;
  perPrototypeOpcodes: boolean;
  instructionBlockSize: number;
  constantCache: CacheMode;
  instructionCache: CacheMode;
  debug: boolean;
}
export const profiles = [
  { id: "fast", name: "Fast", detail: "Lighter output", layers: 1 },
  { id: "balanced", name: "Balanced", detail: "The best of both", layers: 2 },
  { id: "max", name: "Maximum", detail: "Full protection", layers: 2 },
] as const;
export function defaultSettings(profile: Profile = "balanced"): Settings {
  const packed = profile !== "fast";
  return {
    profile, seed: "", junk: profile === "max" ? 0.65 : packed ? 0.3 : 0.05,
    main: packed, cff: true, opaque: packed, antiTamper: packed,
    antiHooks: packed ? "identity" : "off", antiBeautify: false,
    compression: true, minify: true, optimize: true, compact: true,
    lazyConstants: true, prune: true, nativeHelpers: true, cooperative: packed,
    yieldBudgetMs: 8, lazyInstructions: packed, perPrototypeOpcodes: packed,
    instructionBlockSize: profile === "max" ? 16 : 32,
    constantCache: "prototype", instructionCache: "prototype", debug: false,
  };
}
export interface BuildStats {
  sourceBytes: number;
  outputBytes: number;
  seed: number;
  profile: Profile;
  mainPacked: boolean;
  payloadBytes: number;
  compressedBytes: number;
  instructions: number;
  constants: number;
  debugMap?: unknown;
  timings: { total: number };
  settings: Record<string, unknown>;
}
export interface BuildResult { output: string; stats: BuildStats; elapsed: number; filename: string }
export type WorkerResponse = { ok: true; output: string; stats: BuildStats } | { ok: false; error: string };
export const sampleSource = `-- A little code. A lot worth protecting.
local function greet(name: string): string
    return "Hello, " .. name .. "!"
end

local players = {"Alex", "Jordan", "Sam"}

for _, player in ipairs(players) do
    print(greet(player))
end

return {
    version = "1.0.0",
    greet = greet,
}`;
export function formatBytes(bytes: number): string {
  return bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} KB`;
}