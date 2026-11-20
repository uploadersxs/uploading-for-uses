import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { ArrowLeft, ArrowRight, Braces, Check, ChevronRight, CircleHelp, Code2, Download, FileChartColumn, FileCode2, HardDrive, History, LockKeyhole, Play, ShieldCheck, Upload, X, Zap } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ZZ7Settings } from "@/components/verity-settings";
import { ZZ7Editor } from "@/components/verity-editor";
import { defaultSettings, formatBytes, sampleSource, type BuildResult, type WorkerResponse } from "@/lib/verity/settings";

export const Route = createFileRoute("/")({
  head: () => ({ meta: [
    { title: "zz7 Obfuscator — Your Code, Protected" },
    { name: "description", content: "Protect Lua and Luau with the original zz7 engine. A private browser workspace with VM protection, custom profiles, and downloadable builds." },
    { property: "og:title", content: "zz7 Obfuscator — Your Code, Protected" },
    { property: "og:description", content: "A private Lua and Luau obfuscation workspace. Original zz7 engine, three protection profiles, and full build control." },
    { property: "og:type", content: "website" },
    { name: "twitter:card", content: "summary_large_image" },
  ] }),
  component: Index,
});

function BrandMark() {
  return <svg className="brand-mark" viewBox="0 0 30 34" fill="none" aria-hidden="true"><path d="M2 6L15 13.5L28 6M2 6L15 27.5L28 6M2 6L15 0L28 6M15 13.5V27.5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" /><path d="M8 12L15 33L22 12" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" /></svg>;
}
interface Activity { time: string; text: string; type: "ready" | "success" | "error" }
function Index() {
  const [source, setSource] = useState(sampleSource);
  const [filename, setFilename] = useState("hello.luau");
  const [settings, setSettings] = useState(defaultSettings);
  const [result, setResult] = useState<BuildResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [view, setView] = useState<"workspace" | "report">("workspace");
  const [help, setHelp] = useState(false);
  const [buildCount, setBuildCount] = useState(0);
  const [activity, setActivity] = useState<Activity[]>([{ time: "—", text: "zz7 v1 initialized. Workspace ready.", type: "ready" }]);
  const uploadRef = useRef<HTMLInputElement>(null);
  const workerRef = useRef<Worker | null>(null);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { workerRef.current?.terminate(); if (timeoutRef.current) clearTimeout(timeoutRef.current); }, []);
  useEffect(() => { if (!notice) return; const timer = setTimeout(() => setNotice(""), 3000); return () => clearTimeout(timer); }, [notice]);
  function log(text: string, type: Activity["type"] = "ready") {
    const time = new Date().toLocaleTimeString("en-GB", { hour12: false });
    setActivity(previous => [...previous.slice(-5), { time, text, type }]);
  }
  function stopWorker() { workerRef.current?.terminate(); workerRef.current = null; if (timeoutRef.current) clearTimeout(timeoutRef.current); timeoutRef.current = null; setBusy(false); }
  function build() {
    if (!source.trim()) { setError("Add some Lua or Luau code before obfuscating."); return; }
    setBusy(true); setError(""); setResult(null);
    log(`Building ${filename} · ${settings.profile} profile…`);
    const started = performance.now();
    const worker = new Worker(new URL("../lib/verity/obfuscator.worker.ts", import.meta.url), { type: "module" });
    workerRef.current = worker;
    worker.onmessage = (event: MessageEvent<WorkerResponse>) => {
      const response = event.data;
      if (response.ok) {
        const elapsed = performance.now() - started;
        setResult({ ...response, elapsed, filename }); setBuildCount(count => count + 1);
        log(`Build complete · ${formatBytes(response.stats.outputBytes)} · ${(elapsed / 1000).toFixed(2)}s`, "success");
      } else { setError(response.error); log("Build failed. Check the source or configuration.", "error"); }
      stopWorker();
    };
    worker.onerror = () => { setError("The Lua engine could not start. Please try again."); log("Engine could not start.", "error"); stopWorker(); };
    timeoutRef.current = setTimeout(() => { setError("This build took too long. Try the Fast profile or a smaller script."); log("Build stopped after 90 seconds.", "error"); stopWorker(); }, 90000);
    worker.postMessage({ source, settings });
  }
  function save(text: string, name: string, type = "text/plain") {
    const url = URL.createObjectURL(new Blob([text], { type })); const anchor = document.createElement("a"); anchor.href = url; anchor.download = name; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  function downloadOutput() { if (!result) return; save(result.output, result.filename.replace(/\.(lua|luau)$/i, "") + ".obf.luau"); setNotice("Protected file downloaded"); }
  async function copyOutput() { if (!result) return; try { await navigator.clipboard.writeText(result.output); setNotice("Output copied to clipboard"); } catch { setError("Clipboard access was blocked. Download the output instead."); } }
  async function upload(file?: File) {
    if (!file) return;
    if (!/\.(lua|luau)$/i.test(file.name)) { setError("Choose a .lua or .luau source file."); return; }
    try { setSource(await file.text()); setFilename(file.name); setResult(null); setError(""); log(`Loaded ${file.name} · ${formatBytes(file.size)}`); } catch { setError("This file could not be read. Please try again."); }
  }
  const currentProfile = settings.profile === "max" ? "Maximum" : settings.profile === "fast" ? "Fast" : "Balanced";
  return <div className="app-shell">
    <aside className="sidebar"><div><div className="brand"><BrandMark /><span>zz7<span className="text-primary">.</span></span></div><p className="brand-label">Code protection</p></div>
      <nav aria-label="Main navigation"><p className="nav-caption">Workspace</p><Button variant="ghost" className="nav-button" data-active={view === "workspace"} title="Obfuscator" aria-label="Obfuscator" onClick={() => setView("workspace")}><Code2 size={17} /><span className="nav-text">Obfuscator</span></Button><Button variant="ghost" className="nav-button" data-active={view === "report"} title="Build report" aria-label="Build report" onClick={() => setView("report")}><FileChartColumn size={17} /><span className="nav-text">Build report</span><span className="nav-counter">{buildCount}</span></Button></nav>
      <div className="sidebar-bottom"><Button variant="ghost" className="nav-button px-0" onClick={() => setHelp(!help)}><CircleHelp size={15} />About the engine</Button><div className="config-divider" /><div className="engine-indicator"><span className="status-dot" />zz7 engine v1</div><p className="text-code-comment text-[10px] mb-0">Lua host · Luau output</p></div>
    </aside>
    <div className="min-w-0"><header className="app-topbar"><div className="breadcrumbs"><Braces size={16} /><span>Workspace</span><ChevronRight size={12} /><strong>{view === "workspace" ? "Obfuscator" : "Build report"}</strong></div><div className="flex items-center gap-4"><span className="text-muted-foreground text-[11px] topbar-private">Personal workspace</span><span className="version-pill">v1.0</span></div></header>
      <main className="workspace"><div className="page-heading"><div><h1>{view === "workspace" ? "zz7 Obfuscator" : "Build report"}</h1><p>{view === "workspace" ? "Your code. Your craft. Keep it yours." : result ? result.filename + " · Latest build" : "No builds in this session yet."}</p></div><div className="privacy-badge" title="Your source stays on this device"><LockKeyhole size={12} /><span>Private by default</span></div></div>
        {help && <section className="mb-6 border-y border-border py-5"><div className="flex items-center justify-between mb-3"><h2 className="text-sm font-medium">zz7 engine v1</h2><Button variant="ghost" size="icon" onClick={() => setHelp(false)} aria-label="Close engine information"><X /></Button></div><p className="text-muted-foreground text-xs leading-6 max-w-2xl">Original Lua compiler from your uploaded project. Builds run locally and produce Luau output requiring a compatible environment with buffer and bit32 APIs. Obfuscation makes inspection harder; it is not a substitute for keeping secrets out of client code. The browser workspace processes one file at a time; recursive batch processing remains available in the original CLI.</p></section>}
        {view === "workspace" ? <div className="workspace-layout"><div className="editor-column"><div className="section-topline"><h2><FileCode2 size={15} className="text-muted-foreground" />Code workspace</h2><div className="flex gap-1"><Button variant="ghost" size="sm" className="text-muted-foreground text-[11px]" disabled={busy} onClick={() => { setSource(sampleSource); setFilename("hello.luau"); setResult(null); setError(""); }} title="Load example">Example</Button><Button variant="outline" size="sm" className="text-[11px] h-8 px-3" disabled={busy} onClick={() => uploadRef.current?.click()}><Upload size={12} />Upload file</Button></div></div>
            <input ref={uploadRef} type="file" accept=".lua,.luau" className="hidden" aria-label="Upload Lua or Luau file" onChange={event => { void upload(event.target.files?.[0]); event.target.value = ""; }} />
            <div onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); if (!busy) void upload(event.dataTransfer.files[0]); }}>
              <ZZ7Editor source={source} onChange={value => { setSource(value); setResult(null); setError(""); }} filename={filename} output={result?.output ?? ""} busy={busy} onCopy={() => void copyOutput()} onDownload={downloadOutput} onClear={() => { setSource(""); setResult(null); setError(""); }} />
            </div>
            {error && <div className="error-message" role="alert">{error}</div>}
            <div className="run-bar"><span className="run-note">{notice ? <><Check size={12} className="text-success" />{notice}</> : <><ShieldCheck size={12} />{currentProfile} protection<span className="mx-1">·</span>{settings.main ? "2 VM layers" : "1 VM layer"}</>}</span>{busy ? <Button variant="outline" className="run-button" onClick={() => { stopWorker(); log("Build cancelled."); }}><X size={15} />Cancel build</Button> : <Button className="run-button" onClick={build} disabled={!source.trim()}><Zap size={14} fill="currentColor" />Obfuscate code<ArrowRight size={14} className="ml-3" /></Button>}</div>
            <section className="activity" aria-label="Build activity"><div className="activity-heading"><h2><History size={13} className="text-muted-foreground" />Build activity</h2><span>THIS SESSION</span></div><div aria-live="polite">{activity.map((item, index) => <div key={index} className="activity-line"><time>{item.time}</time>{item.type === "success" ? <Check size={11} className="text-success" /> : item.type === "error" ? <X size={11} className="text-destructive" /> : <ChevronRight size={11} className="text-code-comment" />}<span className={item.type === "success" ? "text-success" : undefined}>{item.text}</span></div>)}</div></section>
          </div><ZZ7Settings settings={settings} onChange={setSettings} disabled={busy} /></div> : <section className="report">{result ? <><div className="flex justify-between items-center"><span className="flex items-center gap-2 text-success text-xs"><Check size={14} />Build successful</span><Button variant="outline" size="sm" onClick={downloadOutput}><Download />Download output</Button></div><div className="report-stats">{[{ label: "Source size", value: formatBytes(result.stats.sourceBytes) }, { label: "Output size", value: formatBytes(result.stats.outputBytes) }, { label: "Build time", value: `${(result.elapsed / 1000).toFixed(2)}s` }, { label: "VM layers", value: result.stats.mainPacked ? "2" : "1" }].map(stat => <div key={stat.label} className="report-stat"><p>{stat.label}</p><strong>{stat.value}</strong></div>)}</div><table className="report-table"><tbody>{[["Profile", result.stats.profile], ["Build seed", result.stats.seed], ["Payload size", formatBytes(result.stats.payloadBytes)], ["Compressed payload", formatBytes(result.stats.compressedBytes)], ["Constants", result.stats.constants], ["Engine CPU time", `${result.stats.timings.total.toFixed(3)}s`], ["Output target", "Luau"]].map(([label, value]) => <tr key={label}><td>{label}</td><td>{value}</td></tr>)}</tbody></table><div className="flex flex-wrap gap-3 mt-6"><Button variant="outline" size="sm" onClick={() => save(JSON.stringify(result.stats, null, 2), "zz7-stats.json", "application/json")}><Download />Statistics</Button>{result.stats.debugMap && <Button variant="outline" size="sm" onClick={() => save(JSON.stringify(result.stats.debugMap, null, 2), "zz7-source-map.json", "application/json")}><Download />Source map</Button>}<Button variant="ghost" size="sm" onClick={() => setView("workspace")}><ArrowLeft />Back to workspace</Button></div></> : <div className="report-empty"><FileChartColumn size={35} strokeWidth={1} /><p>No builds yet</p><Button variant="outline" onClick={() => setView("workspace")}><Play />Go to workspace</Button></div>}</section>}
        <footer className="workspace-footer"><span><HardDrive size={11} />Processed on your device. Never on a server.</span><span>Built for Lua & Luau<span className="text-primary">✦</span></span></footer>
      </main>
    </div>
  </div>;
}
