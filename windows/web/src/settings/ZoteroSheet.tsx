import { useEffect, useState } from "react";
import { AlertTriangle, Check } from "lucide-react";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { Sheet } from "../ui/sheet";

/** "从 Zotero 导入…": probe → options → import with progress → summary. */
export function ZoteroSheet({ close }: { close: () => void }) {
  const [directory, setDirectory] = useState<string | null>(null);
  const [report, setReport] = useState<any>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(true);
  const [automatic, setAutomatic] = useState(false);
  const [progress, setProgress] = useState<{ done: number; all: number } | null>(null);
  const [summary, setSummary] = useState<any>(null);

  const probe = async (dir: string | null) => {
    setDirectory(dir);
    setReport(null); setProblem(null);
    if (!dir) { setBusy(false); setProblem(t("未找到 Zotero 数据目录，请点击「选择…」手动指定")); return; }
    setBusy(true);
    try { setReport(await call("zotero.probe", { directory: dir })); }
    catch (e: any) { setProblem(t("无法读取 Zotero 数据库：%@", e.message)); }
    setBusy(false);
  };
  useEffect(() => { call("zotero.locate").then(probe); return on("zotero.progress", setProgress); }, []);

  const start = async () => {
    setProgress({ done: 0, all: (report?.regularItems ?? 0) + (report?.standaloneFiles ?? 0) });
    try { setSummary(await call("zotero.import", { directory, automaticTags: automatic })); }
    catch (e: any) { setProblem(t("导入失败：%@", e.message)); }
    setProgress(null);
  };

  const importing = !!progress;
  return (
    <Sheet title={t("从 Zotero 导入")} width={500} onEscape={importing ? undefined : close} actions={summary
      ? <button className="btn primary" onClick={close}>{t("完成")}</button>
      : <>
        <button className="btn" disabled={importing} onClick={close}>{t("取消")}</button>
        <button className="btn primary" disabled={!report || importing} onClick={start}>{t("导入")}</button>
      </>}>
      <div style={{ display: "flex", alignItems: "center", gap: 8, margin: "6px 0 14px" }}>
        <span className="secondary" style={{ flex: "none" }}>{t("数据目录")}</span>
        <span className="mono ellipsis" style={{ flex: 1, fontSize: 12 }} title={directory ?? ""}>{directory ?? t("未找到 Zotero 数据目录")}</span>
        <button className="btn" disabled={importing} onClick={async () => { const dir = await call<string | null>("pick.folder"); if (dir) probe(dir); }}>{t("选择…")}</button>
      </div>
      {busy && <div style={{ display: "flex", gap: 8, alignItems: "center" }}><span className="spinner" />{t("正在读取 Zotero 数据库…")}</div>}
      {problem && <div style={{ display: "flex", gap: 8, color: "var(--red)" }}><AlertTriangle size={14} style={{ flex: "none", marginTop: 2 }} /><span>{problem}</span></div>}
      {importing && progress && (
        <>
          <div className="progress-bar"><div style={{ width: `${(progress.done / Math.max(progress.all, 1)) * 100}%` }} /></div>
          <div className="secondary" style={{ fontSize: 12, marginTop: 6 }}>{t("正在导入 %lld / %lld…", progress.done, progress.all)}</div>
        </>
      )}
      {summary && (
        <>
          <div style={{ display: "flex", gap: 6, color: "var(--green)", alignItems: "center", marginBottom: 6 }}><Check size={14} />{t("导入完成")}</div>
          <div>{t("导入 %lld 个条目、%lld 个文件，新建 %lld 个分组、%lld 个标签。", summary.itemsImported, summary.filesImported, summary.groupsCreated, summary.tagsCreated)}</div>
          {summary.translationsRecognized > 0 && <div>{t("识别出之前导入的 %lld 个翻译文件，已按翻译服务重新命名。", summary.translationsRecognized)}</div>}
          {(summary.duplicatesSkipped > 0 || summary.missingFiles > 0) && <div className="secondary">{t("跳过 %lld 个重复条目；%lld 个附件在 Zotero 中已找不到文件。", summary.duplicatesSkipped, summary.missingFiles)}</div>}
        </>
      )}
      {report && !importing && !summary && (
        <>
          <div>{t("将导入 %lld 个条目、%lld 个独立文件、%lld 个分组、%lld 个标签。", report.regularItems, report.standaloneFiles, report.collections, report.tags)}</div>
          <div className="secondary" style={{ fontSize: 12, margin: "4px 0 10px" }}>{t("跳过：%lld 条笔记、%lld 条 Zotero 批注、%lld 个网页快照、%lld 个回收站条目。超过两级的分组会并入第二级。", report.skippedNotes, report.skippedAnnotations, report.skippedSnapshots, report.skippedTrashed)}</div>
          <label className="checkbox"><input type="checkbox" disabled={report.automaticTags === 0} checked={automatic} onChange={(e) => setAutomatic(e.target.checked)} />{t("同时导入自动标签（%lld 个，来自出版商关键词和 arXiv 分类）", report.automaticTags)}</label>
          <div className="secondary" style={{ fontSize: 11, marginTop: 8 }}>{t("只读取 Zotero 数据库的副本，不会修改 Zotero；PDF 会复制进 Folio 文献库，与已有文献重复的会跳过。")}</div>
        </>
      )}
    </Sheet>
  );
}
