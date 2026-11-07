import { useEffect, useRef, useState } from "react";
import { ChevronDown, ChevronRight, ExternalLink, FileText, Paperclip, Plus, Search, Star } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { filesOf, getState, groupsForMenus, setState, tagsOf, useStore, type FileRec, type Item } from "../store";
import { fileMenu, manualMatch, newTag, openReader } from "../commands";
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
          <FileText size={14} className="secondary" style={{ flex: "none" }} />
          <span className="ellipsis">{file.title}</span>
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
export function NoteEditor({ itemId, title, inputRef }: { itemId: string | null; title?: string; inputRef?: React.MutableRefObject<HTMLTextAreaElement | null> }) {
  const [text, setText] = useState("");
  const saved = useRef("");
  const shown = useRef<string | null>(null);
  const timer = useRef(0);
  const box = useRef<HTMLTextAreaElement | null>(null);
  const version = useStore((s) => s.libraryVersion);

  const flush = () => {
    clearTimeout(timer.current);
    const value = box.current?.value;
    if (shown.current && value !== undefined && value !== saved.current) {
      saved.current = value;
      call("note.set", { item: shown.current, text: value });
    }
  };

  useEffect(() => {
    flush();
    shown.current = itemId;
    if (!itemId) { setText(""); saved.current = ""; return; }
    let live = true;
    call<string>("note.get", { item: itemId }).then((note) => { if (live) { saved.current = note; setText(note); } });
    return () => { live = false; };
  }, [itemId]);

  // Another editor (a reader tab, an agent) changed the note; what is being typed here is not overwritten.
  useEffect(() => {
    if (!itemId || document.activeElement === box.current || box.current?.value !== saved.current) return;
    call<string>("note.get", { item: itemId }).then((note) => {
      if (note !== saved.current && document.activeElement !== box.current) { saved.current = note; setText(note); }
    });
  }, [version]);

  useEffect(() => flush, []);

  return (
    <div className="note-area">
      {title !== undefined && <><div className="note-head">{t("笔记")}</div><div className="note-sub">{title}</div></>}
      <textarea ref={(el) => { box.current = el; if (inputRef) inputRef.current = el; }} disabled={!itemId} value={text} spellCheck={false} placeholder={t("记下想法、摘录与待办… 支持 Markdown")}
        onChange={(e) => { setText(e.target.value); clearTimeout(timer.current); timer.current = window.setTimeout(flush, 600); }}
        onBlur={flush} onKeyDown={(e) => e.stopPropagation()} />
    </div>
  );
}

export function Inspector() {
  const selection = useStore((s) => s.selection);
  const page = useStore((s) => s.inspectorPage);
  const item = useStore((s) => (s.selection.length === 1 ? s.items.get(s.selection[0]) : undefined));
  const scroll = useRef<HTMLDivElement>(null);
  useEffect(() => { scroll.current?.scrollTo(0, 0); }, [item?.id, page]);
  return (
    <>
      <div className="inspector-switch">
        <Segmented value={page} onChange={(v) => setState({ inspectorPage: v })} options={[{ value: "info", label: t("信息") }, { value: "annotations", label: t("标注") }, { value: "notes", label: t("笔记") }]} />
      </div>
      {page === "notes"
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
