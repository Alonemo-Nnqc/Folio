import { useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, BarChart3, ChevronDown, ChevronRight, ExternalLink, FilePen, FileText, Maximize2, Paperclip, Plus, RefreshCw, Search, Star } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { filesOf, getState, groupsForMenus, setState, tagsOf, useStore, type FileRec, type Item, type State } from "../store";
import { MarkdownEditor } from "../notes/markdown";
import { isMarkdownItem } from "./ItemList";
import { MultiSelectionPanel } from "./MultiSelection";
import { fileMenu, manualMatch, newTag, openReader, refreshJournalMetrics } from "../commands";
import { openMenu, openMenuAt, sep, type MenuEntry } from "../ui/menu";
import { Chip, PlainEdit, Segmented } from "../ui/controls";
import { formatDateTime } from "../ui/util";

const update = (id: string, patch: Record<string, unknown>) => call("item.update", { id, patch });

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return <div className="ins-row"><div className="label ellipsis" title={label}>{label}</div><div className="value">{children}</div></div>;
}

function FieldRow({ label, value, onCommit, link }: { label: string; value?: string | number; onCommit: (v: string) => void; link?: string }) {
  return (
    <div className="ins-row">
      <div className="label ellipsis" title={label}>{label}</div>
      <div className="value"><PlainEdit value={value === undefined || value === null ? "" : String(value)} placeholder="—" onCommit={onCommit} /></div>
      {link && <button className="link" title={t("在浏览器中打开")} onClick={() => call("shell.open", { target: link })}><ExternalLink size={12} /></button>}
    </div>
  );
}

/** The line of rank capsules under 来源 (META-30), or a quiet hint when there is nothing to show yet. */
function JournalMetricsRow({ item }: { item: Item }) {
  const state = useStore((x) => x.journalMetrics);
  const metrics = item.journalMetrics;
  const refresh = () => refreshJournalMetrics([item.id]);
  const settings = () => call("window.settings", { page: "retrieval" });
  const menu = (e: React.MouseEvent) => {
    e.preventDefault();
    openMenu([
      { label: t("刷新期刊指标"), action: refresh },
      ...(metrics?.badges.length ? [{ label: t("拷贝期刊指标"), action: () => call("shell.copy", { text: metrics.summary }) }] : []),
    ], e.clientX, e.clientY);
  };
  let body: React.ReactNode;
  if (metrics && metrics.badges.length) {
    body = (
      <div className="jm-badges" onContextMenu={menu} aria-label={t("期刊指标：%@", metrics.summary)}>
        {metrics.badges.map((b) => <span key={b.text} className={`jm-badge jm-${b.kind}${b.emphasized ? " strong" : ""}`} title={b.detail}>{b.text}</span>)}
        <button className="jm-refresh" title={t("刷新期刊指标")} onClick={refresh}><RefreshCw size={11} strokeWidth={2.2} /></button>
      </div>
    );
  } else if (metrics) {
    body = <span className="jm-hint" onContextMenu={menu} title={t("按期刊名「%@」没有查到分区信息，可核对期刊全称后刷新", item.source ?? "")}>{t("easyScholar 未收录该期刊")}</span>;
  } else if (!state?.hasKey) {
    body = <button className="jm-hint link" onClick={settings} title={t("填写 easyScholar 密钥后，这里会显示中科院分区、JCR 分区与影响因子")}><BarChart3 size={12} />{t("设置期刊指标…")}</button>;
  } else if (state.attention && state.status && /密钥|key/i.test(state.status)) {
    body = <button className="jm-hint link" onClick={settings}><AlertTriangle size={12} />{t("easyScholar 密钥无效")}</button>;
  } else if (state.pending > 0 && state.autoFetch) {
    body = <span className="jm-hint"><span className="spinner" />{t("正在获取期刊指标…")}</span>;
  } else {
    body = <button className="jm-hint link" onClick={refresh}><RefreshCw size={12} />{t("获取期刊指标")}</button>;
  }
  return <div className="jm-row">{body}</div>;
}

function LibrarySection({ item }: { item: Item }) {
  const s = getState();
  const dark = useStore((x) => x.dark);
  const itemGroups = useStore((x) => x.itemGroups[item.id]);
  useStore((x) => x.itemTags[item.id]);
  const regular = item.kind === "regular";
  const groups = (itemGroups ?? []).map((id) => s.groups.get(id)).filter(Boolean);
  const addGroupMenu = (): MenuEntry[] => groupsForMenus(getState()).map(({ group, depth }) => ({ label: group.name, indent: depth, checked: itemGroups?.includes(group.id), action: () => call("items.addToGroup", { ids: [item.id], group: group.id, includeSubgroups: false, quiet: true }) }));
  const addTagMenu = (): MenuEntry[] => {
    const st = getState();
    const have = st.itemTags[item.id] ?? [];
    return [...st.tags.filter((tag) => !have.includes(tag.id)).map((tag): MenuEntry => ({ label: tag.name, dot: tag.color, action: () => call("items.setTag", { tag: tag.id, ids: [item.id], on: true }) })), sep, { label: t("新建标签…"), icon: <Plus size={14} />, action: () => newTag([item.id]) }];
  };
  return (
    <>
      <div className="ins-section">{t("文库")}</div>
      {regular && (
        <>
          <Row label={t("评分")}>
            <span className="stars">
              {[1, 2, 3, 4, 5].map((v) => <button key={v} onClick={() => update(item.id, { rating: item.rating === v ? 0 : v })}><Star size={15} fill={v <= item.rating ? "currentColor" : "none"} strokeWidth={1.5} /></button>)}
              {item.rating > 0 && <span className="secondary" style={{ fontSize: 11, marginLeft: 4 }}>{t("%lld 星", item.rating)}</span>}
            </span>
          </Row>
          <Row label={t("状态")}>
            <Segmented accent value={item.readStatus} onChange={(v) => update(item.id, { readStatus: v })} options={s.statics.statuses.map((st) => ({ value: st.raw, label: st.name }))} />
          </Row>
        </>
      )}
      <Row label={t("分组")}>
        <div className="wrap">
          {groups.map((g) => <Chip key={g!.id} label={g!.name} color={g!.color ?? "#007AFF"} dark={dark} onRemove={() => call("items.removeFromGroup", { ids: [item.id], group: g!.id, includeSubgroups: false })} />)}
          <button className="small-add" onClick={(e) => openMenuAt(e.currentTarget, addGroupMenu())}><Plus size={13} /></button>
        </div>
      </Row>
      <Row label={t("标签")}>
        <div className="wrap">
          {tagsOf(s, item.id).map((tag) => <Chip key={tag.id} label={tag.name} color={tag.color} dark={dark} onRemove={() => call("items.setTag", { tag: tag.id, ids: [item.id], on: false })} />)}
          <button className="small-add" onClick={(e) => openMenuAt(e.currentTarget, addTagMenu())}><Plus size={13} /></button>
        </div>
      </Row>
    </>
  );
}

function FilesSection({ item }: { item: Item }) {
  const s = getState();
  useStore((x) => x.filesByItem[item.id]);
  const files = filesOf(s, item.id);
  return (
    <>
      <div className="ins-section">{t("文件")}</div>
      {files.map((file: FileRec) => (
        <button key={file.id} className={`file-row${file.id === item.defaultFileId && files.length > 1 ? " default" : ""}`} title={file.fileName}
          onClick={() => call("file.open", { id: file.id })}
          onContextMenu={(e) => { e.preventDefault(); openMenu(fileMenu(file), e.clientX, e.clientY); }}>
          {file.isMarkdown ? <FilePen size={14} className="secondary" style={{ flex: "none" }} /> : <FileText size={14} className="secondary" style={{ flex: "none" }} />}
          <span className="ellipsis">{file.title}</span>
          {file.id === item.defaultFileId && <span className="default-badge">{t("默认")}</span>}
        </button>
      ))}
      {item.kind === "regular" && <button className="btn small" style={{ marginTop: 6 }} onClick={() => call("files.attachPick", { item: item.id })}><Paperclip size={12} />{t("添加文件…")}</button>}
    </>
  );
}

let abstractOpen = true;

function InfoPage({ item }: { item: Item }) {
  const [open, setOpen] = useState(abstractOpen);
  const types = getState().statics.itemTypes;
  if (item.kind === "standalone") {
    const state = item.metadataState === "Pending" ? t("正在检索元数据…") : item.metadataState === "Failed" ? t("未检索到元数据") : item.metadataState === "NetworkFailed" ? t("网络不可用，稍后自动重试") : t("独立文件");
    return (
      <>
        <div className="ins-title selectable" style={{ overflowWrap: "anywhere" }}>{item.title}</div>
        <div className="secondary" style={{ fontSize: 12, marginTop: 6 }}>{state}</div>
        <div className="wrap" style={{ gap: 8, margin: "12px 0" }}>
          <button className="btn small" onClick={() => call("items.retrieve", { ids: [item.id] })}>{t("重新检索元数据")}</button>
          <button className="btn small" onClick={() => manualMatch(item)}>{t("手动匹配…")}</button>
        </div>
        <FilesSection item={item} />
        <LibrarySection item={item} />
      </>
    );
  }
  return (
    <>
      <button className="ins-type" onClick={(e) => openMenuAt(e.currentTarget, types.map((ty) => ({ label: ty.name, checked: ty.raw === item.type, action: () => update(item.id, { type: ty.raw }) })))}>{item.typeName}<ChevronDown size={10} /></button>
      <PlainEdit className="ins-title" value={item.title} onCommit={(v) => { if (v) update(item.id, { title: v }); }} />
      <div className="ins-authors"><PlainEdit value={item.authors.map((a) => a.full).join("; ")} placeholder={t("无作者")} title={t("编辑作者")} onCommit={(v) => update(item.id, { authors: v })} /></div>
      {item.citationKey && <div className="ins-key selectable">{item.citationKey}</div>}

      <div className="ins-section">{t("引用")}</div>
      <FieldRow label={t("年份")} value={item.year} onCommit={(v) => update(item.id, { year: v })} />
      <FieldRow label={t("来源")} value={item.source} onCommit={(v) => update(item.id, { source: v })} />
      {item.hasJournal && <JournalMetricsRow item={item} />}
      <FieldRow label={t("卷")} value={item.volume} onCommit={(v) => update(item.id, { volume: v })} />
      <FieldRow label={t("期")} value={item.issue} onCommit={(v) => update(item.id, { issue: v })} />
      <FieldRow label={t("页码")} value={item.pages} onCommit={(v) => update(item.id, { pages: v })} />
      <FieldRow label={t("出版社")} value={item.publisher} onCommit={(v) => update(item.id, { publisher: v })} />
      <FieldRow label="DOI" value={item.doi} onCommit={(v) => update(item.id, { doi: v })} link={item.doi ? `https://doi.org/${item.doi}` : undefined} />
      <FieldRow label="arXiv" value={item.arxivId} onCommit={(v) => update(item.id, { arxivId: v })} link={item.arxivId ? `https://arxiv.org/abs/${item.arxivId}` : undefined} />
      <FieldRow label="ISBN" value={item.isbn} onCommit={(v) => update(item.id, { isbn: v })} />
      <FieldRow label="URL" value={item.url} onCommit={(v) => update(item.id, { url: v })} link={item.url} />
      <FieldRow label={t("引用键")} value={item.citationKey} onCommit={(v) => update(item.id, { citationKey: v })} />

      <LibrarySection item={item} />

      {item.abstract && (
        <>
          <div className="ins-section">{t("内容")}</div>
          <button className="disclose-head" onClick={() => { abstractOpen = !open; setOpen(!open); }}>{open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}{t("摘要")}</button>
          {open && <div className="abstract"><PlainEdit multiline value={item.abstract} onCommit={(v) => update(item.id, { abstract: v })} /></div>}
        </>
      )}
      <FilesSection item={item} />
      <div className="stamps">{t("添加于 %@ · 修改于 %@", formatDateTime(item.dateAdded), formatDateTime(item.dateModified))}</div>
    </>
  );
}

function AnnotationsPage({ item }: { item: Item }) {
  const [results, setResults] = useState<any[] | null>(null);
  const [query, setQuery] = useState("");
  const sha = useStore((s) => filesOf(s, item.id).map((f) => f.id + f.sha).join(","));
  useEffect(() => {
    let live = true;
    setResults(null);
    call("annotations.read", { item: item.id }).then((r) => { if (live) setResults(r); }).catch(() => { if (live) setResults([]); });
    return () => { live = false; };
  }, [item.id, sha]);
  const s = getState();
  const q = query.trim().toLowerCase();
  let total = 0;
  return (
    <>
      <div className="search-small"><Search size={13} /><input placeholder={t("搜索标注")} spellCheck={false} value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => e.stopPropagation()} /></div>
      {results === null && <div style={{ textAlign: "center", paddingTop: 30 }}><span className="spinner" style={{ width: 18, height: 18 }} /></div>}
      {results?.map((r) => {
        const file = s.files.get(r.fileId);
        const matching = r.annotations.filter((a: any) => !q || (a.text ?? "").toLowerCase().includes(q) || (a.comment ?? "").toLowerCase().includes(q));
        if (!file || matching.length === 0) return null;
        total += matching.length;
        return (
          <div key={r.fileId}>
            <div className="anno-file"><span className="ellipsis">{file.title}</span><button onClick={() => call("file.open", { id: file.id })}>{t("阅读")}</button></div>
            {matching.map((a: any, i: number) => (
              <button key={i} className="anno-card" style={{ borderLeftColor: a.color }} onClick={() => openReader(file.id, a.page)}>
                {a.text && <div>{a.text}</div>}
                {a.comment && <div className="comment">{a.comment}</div>}
                <div className="meta">{t("第 %lld 页", a.page)}{a.author ? ` · ${a.author}` : ""}</div>
              </button>
            ))}
          </div>
        );
      })}
      {results && total === 0 && (
        <div className="ins-empty" style={{ paddingTop: 40 }}>
          <div>{q ? t("没有匹配的标注") : t("没有标注")}</div>
          {!q && <div style={{ fontSize: 11, marginTop: 4 }}>{t("在 Folio 阅读器中添加的高亮和批注会显示在这里")}</div>}
        </div>
      )}
    </>
  );
}

/** An item's Markdown note; saved a moment after typing stops. */
export function NoteEditor({ itemId, title, inputRef }: { itemId: string | null; title?: string; inputRef?: React.MutableRefObject<{ focus: () => void } | null> }) {
  const source = useMemo(() => ({
    key: itemId ? `note:${itemId}` : null,
    load: () => call<string>("note.get", { item: itemId }),
    save: (text: string) => { call("note.set", { item: itemId, text }); },
  }), [itemId]);
  return (
    <div className="note-area">
      {title !== undefined && <><div className="note-head">{t("笔记")}</div><div className="note-sub">{title}</div></>}
      <MarkdownEditor source={source} inputRef={inputRef} className="note-text" placeholder={t("记下想法、摘录与待办… 支持 Markdown")} />
    </div>
  );
}

/** A Markdown file in the inspector (MD-01): its name, a button to open it in a tab, and the editor. */
function MarkdownFileInspector({ file }: { file: FileRec }) {
  const focus = useStore((s) => s.markdownFocus === file.id);
  const source = useMemo(() => markdownSource(file.id), [file.id]);
  useEffect(() => { if (focus) setState({ markdownFocus: null }); }, [focus]);
  return (
    <div className="md-inspector">
      <div className="md-file-head">
        <FilePen size={14} className="secondary" style={{ flex: "none" }} />
        <span className="ellipsis" title={file.fileName}>{file.fileName}</span>
        <span style={{ flex: 1 }} />
        <button className="icon-button" title={t("在标签页中打开")} onClick={() => openReader(file.id)}><Maximize2 size={13} /></button>
      </div>
      <MarkdownEditor source={source} focus={focus} className="md-text" placeholder={t("开始书写… 支持 Markdown")} />
    </div>
  );
}

/** Where a Markdown file's text comes from and goes to. */
export function markdownSource(fileId: string) {
  return {
    key: `file:${fileId}`,
    load: () => call<string>("markdown.get", { file: fileId }),
    save: (text: string) => { call("markdown.set", { file: fileId, text }); },
  };
}

/** The Markdown file the inspector shows: a selected .md file, or a document item's own file. */
function inspectedMarkdownFile(s: State): FileRec | undefined {
  if (s.fileSelection) {
    const file = s.files.get(s.fileSelection);
    return file?.isMarkdown ? file : undefined;
  }
  if (s.selection.length !== 1) return undefined;
  const item = s.items.get(s.selection[0]);
  return item && isMarkdownItem(item, s) ? s.files.get(item.defaultFileId!) : undefined;
}

export function Inspector() {
  const selection = useStore((s) => s.selection);
  const page = useStore((s) => s.inspectorPage);
  const item = useStore((s) => (s.selection.length === 1 ? s.items.get(s.selection[0]) : undefined));
  const multi = useStore((s) => s.multiSelect);
  const fileSelection = useStore((s) => s.fileSelection);
  const markdown = useStore(inspectedMarkdownFile);
  const scroll = useRef<HTMLDivElement>(null);
  useEffect(() => { scroll.current?.scrollTo(0, 0); }, [item?.id, page]);
  // Several papers (or 多选): what can be done to all of them at once.
  if ((multi || selection.length > 1) && !fileSelection) return <MultiSelectionPanel />;
  return (
    <>
      <div className="inspector-switch">
        <Segmented value={page} onChange={(v) => setState({ inspectorPage: v })} options={[{ value: "info", label: t("信息") }, { value: "annotations", label: t("标注") }, { value: "notes", label: t("笔记") }]} />
      </div>
      {page === "info" && markdown
        ? <MarkdownFileInspector key={markdown.id} file={markdown} />
        : page === "notes"
        ? <NoteEditor itemId={item?.id ?? null} title={item?.title ?? ""} />
        : (
          <div className="inspector-scroll" ref={scroll}>
            {!item && <div className="ins-empty">{selection.length > 1 ? t("已选择 %lld 项", selection.length) : t("未选择文献")}</div>}
            {item && page === "info" && <InfoPage key={item.id} item={item} />}
            {item && page === "annotations" && <AnnotationsPage key={item.id} item={item} />}
          </div>
        )}
    </>
  );
}
