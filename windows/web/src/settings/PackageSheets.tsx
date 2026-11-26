import { useEffect, useState } from "react";
import { AlertTriangle, Check } from "lucide-react";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { openSheet, Sheet } from "../ui/sheet";

// 打包导出 and 导入 Folio 包, as on the Mac (PackageSheets.swift).

export function exportPackage() { openSheet((close) => <ExportSheet close={close} />); }
export function openPackage(path: string) { openSheet((close) => <ImportSheet path={path} close={close} />); }
export async function importPackage() {
  const path = await call<string | null>("package.pick");
  if (path) openPackage(path);
}

const size = (bytes: number) => bytes >= 1e9 ? `${(bytes / 1e9).toFixed(2)} GB` : bytes >= 1e6 ? `${(bytes / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1e3))} KB`;

function Part({ title, detail, on, onChange, disabled }: { title: string; detail: string; on: boolean; onChange: (on: boolean) => void; disabled?: boolean }) {
  return (
    <label className="package-part" style={disabled ? { opacity: .5 } : undefined}>
      <input type="checkbox" checked={on} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span><span>{title}</span><span className="secondary">{detail}</span></span>
    </label>
  );
}

function Problem({ text }: { text: string }) {
  return <div style={{ display: "flex", gap: 8, color: "var(--red)", marginTop: 10 }}><AlertTriangle size={14} style={{ flex: "none", marginTop: 2 }} /><span>{text}</span></div>;
}

function Working({ text, progress }: { text: string; progress: { done: number; all: number } }) {
  return (
    <>
      <div className="progress-bar"><div style={{ width: `${(progress.done / Math.max(progress.all, 1)) * 100}%` }} /></div>
      <div className="secondary" style={{ fontSize: 12, marginTop: 6 }}>{t(text, progress.done, progress.all)}</div>
    </>
  );
}

const Password = (p: { value: string; placeholder: string; onChange: (value: string) => void }) => (
  <input className="field" type="password" autoComplete="new-password" spellCheck={false} value={p.value} placeholder={p.placeholder} onChange={(e) => p.onChange(e.target.value)} onKeyDown={(e) => { if (e.key !== "Escape") e.stopPropagation(); }} />
);

function ExportSheet({ close }: { close: () => void }) {
  const [counts, setCounts] = useState({ items: 0, files: 0, bytes: 0 });
  const [library, setLibrary] = useState(true);
  const [settings, setSettings] = useState(true);
  const [keys, setKeys] = useState(false);
  const [password, setPassword] = useState("");
  const [again, setAgain] = useState("");
  const [progress, setProgress] = useState<{ done: number; all: number } | null>(null);
  const [done, setDone] = useState<any>(null);
  const [problem, setProblem] = useState<string | null>(null);
  useEffect(() => { call("package.counts").then((c) => c && setCounts(c)); return on("package.progress", (p) => setProgress((now) => now && p)); }, []);

  const ready = (library || settings) && !(settings && keys && (!password || password !== again));
  const start = async () => {
    setProblem(null);
    setProgress({ done: 0, all: library ? counts.files : 1 });
    try {
      const r = await call("package.export", { library, settings, password: settings && keys ? password : null });
      if (r && !r.cancelled) setDone(r);
    } catch (e: any) { setProblem(t("导出失败：%@", e.message)); }
    setProgress(null);
  };
  return (
    <Sheet title={t("打包导出")} width={480} onEscape={progress ? undefined : close} actions={done
      ? <>
        <button className="btn" onClick={() => { call("shell.reveal", { path: done.path }); close(); }}>{t("在文件资源管理器中显示")}</button>
        <button className="btn primary" onClick={close}>{t("完成")}</button>
      </>
      : <>
        <button className="btn" onClick={() => (progress ? call("package.cancel") : close())}>{t("取消")}</button>
        <button className="btn primary" disabled={!ready || !!progress} onClick={start}>{t("导出…")}</button>
      </>}>
      {done ? (
        <>
          <div style={{ display: "flex", gap: 6, color: "var(--green)", alignItems: "center", marginBottom: 6 }}><Check size={14} />{t("导出完成")}</div>
          <div className="selectable">{done.fileName}</div>
          <div className="secondary">{t("在另一台设备的 Folio 中选择“导入 Folio 包…”即可导入")}</div>
          {done.missing > 0 && <div className="secondary">{t("%lld 个文件已不在文献库文件夹中，没有打包", done.missing)}</div>}
        </>
      ) : progress ? <Working text="正在打包 %lld / %lld…" progress={progress} /> : (
        <div className="package-parts">
          <Part title={t("文献库")} detail={t("%lld 个条目、%lld 个文件（%@），包括分组、标签、笔记、批注、译文和阅读进度，不包括回收站", counts.items, counts.files, size(counts.bytes))} on={library} onChange={setLibrary} />
          <Part title={t("设置与配置")} detail={t("偏好设置、翻译服务、术语表、工具栏和列表的列")} on={settings} onChange={setSettings} />
          <div className="package-inner">
            <Part title={t("包括 API Key")} detail={t("用密码加密，导入时输入同一密码")} on={keys} disabled={!settings} onChange={setKeys} />
            {keys && settings && (
              <div className="package-inner package-password">
                <Password value={password} placeholder={t("密码")} onChange={setPassword} />
                <Password value={again} placeholder={t("确认密码")} onChange={setAgain} />
                {again && again !== password && <div style={{ color: "var(--red)", fontSize: 12 }}>{t("两次输入的密码不同")}</div>}
              </div>
            )}
          </div>
        </div>
      )}
      {problem && <Problem text={problem} />}
    </Sheet>
  );
}

function ImportSheet({ path, close }: { path: string; close: () => void }) {
  const [info, setInfo] = useState<any>(null);
  const [library, setLibrary] = useState(true);
  const [settings, setSettings] = useState(true);
  const [password, setPassword] = useState("");
  const [wrong, setWrong] = useState(false);
  const [progress, setProgress] = useState<{ done: number; all: number } | null>(null);
  const [done, setDone] = useState<any>(null);
  const [problem, setProblem] = useState<string | null>(null);
  useEffect(() => {
    call("package.read", { path }).then(setInfo, (e) => setProblem(t("无法读取「%@」：%@", path.split(/[\\/]/).pop(), e.message)));
    return on("package.progress", (p) => setProgress((now) => now && p));
  }, []);

  const whole = library && info?.hasLibrary, applies = settings && info?.hasSettings;
  const start = async () => {
    setProblem(null);
    setProgress({ done: 0, all: whole ? info.items : 1 });
    try {
      const r = await call("package.import", { path, library: whole, settings: applies, password: applies && password ? password : null });
      if (r?.wrongPassword) setWrong(true);
      else if (r && !r.cancelled) setDone(r);
    } catch (e: any) { setProblem(t("导入失败：%@", e.message)); }
    setProgress(null);
  };
  const s = done?.library;
  return (
    <Sheet title={t("导入 Folio 包")} width={480} onEscape={progress || done?.settings ? undefined : close} actions={done
      ? done.settings
        ? <button className="btn primary" onClick={() => call("app.restart")}>{t("重新启动 Folio")}</button>
        : <button className="btn primary" onClick={close}>{t("完成")}</button>
      : <>
        <button className="btn" onClick={() => (progress ? call("package.cancel") : close())}>{t("取消")}</button>
        <button className="btn primary" disabled={!(whole || applies) || !!progress} onClick={start}>{t("导入")}</button>
      </>}>
      {!info && !problem && <div style={{ display: "flex", gap: 8, alignItems: "center" }}><span className="spinner" />{t("正在读取…")}</div>}
      {done ? (
        <>
          <div style={{ display: "flex", gap: 6, color: "var(--green)", alignItems: "center", marginBottom: 6 }}><Check size={14} />{t("导入完成")}</div>
          {s && <div>{t("新增 %lld 个条目、%lld 个文件、%lld 个分组、%lld 个标签", s.itemsAdded, s.filesAdded, s.groupsCreated, s.tagsCreated)}</div>}
          {s?.itemsUpdated > 0 && <div>{t("更新 %lld 个已有条目（%lld 个文件换成较新的）", s.itemsUpdated, s.filesUpdated)}</div>}
          {s?.itemsUnchanged > 0 && <div className="secondary">{t("%lld 个条目已是最新", s.itemsUnchanged)}</div>}
          {s?.missingFiles > 0 && <div className="secondary">{t("%lld 个文件不在包中或已损坏", s.missingFiles)}</div>}
          {done.settings && <div>{t("设置在重新启动 Folio 后生效")}</div>}
        </>
      ) : progress ? <Working text="正在导入 %lld / %lld…" progress={progress} /> : info && (
        <div className="package-parts">
          <div className="secondary" style={{ fontSize: 12 }}>{t("%@，由 Folio %@ 于 %@ 导出", info.fileName, info.app, new Date(info.exported).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }))}</div>
          {info.hasLibrary && <Part title={t("文献库")} detail={t("%lld 个条目、%lld 个文件、%lld 个分组、%lld 个标签。合并到当前文献库：已有的文献不会重复，信息、笔记和批注以较新的为准，被换下的文件移到回收站", info.items, info.files, info.groups, info.tags)} on={library} onChange={setLibrary} />}
          {info.hasSettings && <Part title={t("设置与配置")} detail={t("替换这台设备的设置，完成后重新启动 Folio。只导入你信任的文件")} on={settings} onChange={setSettings} />}
          {info.hasKeys && settings && (
            <div className="package-inner package-password">
              <Password value={password} placeholder={t("API Key 的密码（留空则不导入 API Key）")} onChange={(v) => { setPassword(v); setWrong(false); }} />
              {wrong && <div style={{ color: "var(--red)", fontSize: 12 }}>{t("密码不正确")}</div>}
            </div>
          )}
        </div>
      )}
      {problem && <Problem text={problem} />}
    </Sheet>
  );
}
