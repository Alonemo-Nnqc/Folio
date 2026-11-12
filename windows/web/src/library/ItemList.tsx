import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { BookOpen, ChevronDown, ChevronRight, ChevronUp, FileText, Languages, Plus, Search, Share, Star, X, BookText } from "lucide-react";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { filesOf, getState, scopeGroupId, setSetting, setState, tagsOf, useStore, type Item, type State } from "../store";
import { addMenu, citeMenu, fileMenu, itemMenu, openItems, purgeItems, translate } from "../commands";
import { openMenu, openMenuAt, sep, type MenuEntry } from "../ui/menu";
import { Chip, SearchBox, Segmented } from "../ui/controls";
import { dragPointer, formatDate } from "../ui/util";
import { ITEMS_MIME, setDraggingItems } from "./Sidebar";
import { UpdateButton } from "../ui/update";
import { toggleQuickLook } from "./QuickLook";

const ROW = 32;

const COLUMNS: { key: string; title: string; sort: string; width: number }[] = [
  { key: "title", title: "标题", sort: "title", width: 300 }, { key: "source", title: "来源", sort: "source", width: 140 }, { key: "authors", title: "作者", sort: "authors", width: 150 },
  { key: "year", title: "年份", sort: "year", width: 56 }, { key: "tags", title: "标签", sort: "tags", width: 130 }, { key: "dateAdded", title: "添加日期", sort: "dateAdded", width: 96 },
  { key: "type", title: "类型", sort: "type", width: 80 }, { key: "dateModified", title: "修改日期", sort: "dateModified", width: 96 }, { key: "doi", title: "DOI", sort: "doi", width: 140 }, { key: "publisher", title: "出版社", sort: "publisher", width: 140 },
  { key: "volume", title: "卷", sort: "volume", width: 56 }, { key: "issue", title: "期", sort: "issue", width: 56 }, { key: "pages", title: "页码", sort: "pages", width: 80 },
  { key: "readStatus", title: "阅读状态", sort: "readStatus", width: 64 }, { key: "rating", title: "评分", sort: "rating", width: 78 }, { key: "fileCount", title: "文件数", sort: "fileCount", width: 56 },
  { key: "citationKey", title: "引用键", sort: "citationKey", width: 140 },
  { key: "journalRank", title: "分区", sort: "journalRank", width: 72 }, { key: "impactFactor", title: "影响因子", sort: "impactFactor", width: 68 },
];

const TITLE_MIN = 160;
/** How narrow the other columns get when the space is short (they give way before the table scrolls). */
const COLUMN_MIN = 48;

const dash = (v?: string | number | null) => (v === undefined || v === null || v === "" ? "—" : String(v));

function cellText(key: string, item: Item, s: State): string {
  switch (key) {
    case "source": return dash(item.source);
    case "authors": return dash(item.authorsList);
    case "year": return dash(item.year);
    case "dateAdded": return formatDate(item.dateAdded);
    case "dateModified": return formatDate(item.dateModified);
    case "type": return item.kind === "standalone" ? "—" : item.typeName;
    case "publisher": return dash(item.publisher);
    case "doi": return dash(item.doi);
    case "volume": return dash(item.volume);
    case "issue": return dash(item.issue);
    case "pages": return dash(item.pages);
    case "readStatus": return item.kind === "standalone" ? "—" : item.readStatusName;
    case "fileCount": return String(s.filesByItem[item.id]?.length ?? 0);
    case "citationKey": return dash(item.citationKey);
    case "journalRank": return dash(item.journalMetrics?.rank);
    case "impactFactor": return dash(item.journalMetrics?.impactFactor);
    default: return "";
  }
}

export function TranslationProgress({ itemId }: { itemId: string }) {
  const job = useStore((s) => s.jobs[itemId]);
  if (!job) return null;
  const fraction = Math.max(0, Math.min(1, job.fraction ?? 0));
  return (
    <span className="progress" title={t("翻译：%@", job.stage)}>
      <Languages size={12} />
      <span className="stage ellipsis">{job.stage}</span>
      <span className="track"><span className="fill" style={{ width: `${fraction * 100}%`, display: "block" }} /></span>
      <span className="tabular" style={{ width: 30, textAlign: "right" }}>{Math.round(fraction * 100)}%</span>
      <button title={t("取消翻译")} onClick={(e) => { e.stopPropagation(); call("translation.cancel", { item: itemId }); }}><X size={10} /></button>
    </span>
  );
}

interface FlatRow { itemId: string; fileId?: string }

let anchor: string | null = null;

export function ItemList({ leadInset, trailingInset, tabs }: { leadInset?: number; trailingInset?: number; tabs?: React.ReactNode }) {
  const rows = useStore((s) => s.rows);
  const scope = useStore((s) => s.scope);
  const groups = useStore((s) => s.groups);
  const tags = useStore((s) => s.tags);
  const selection = useStore((s) => s.selection);
  const fileSelection = useStore((s) => s.fileSelection);
  const expanded = useStore((s) => s.expanded);
  const filesByItem = useStore((s) => s.filesByItem);
  const items = useStore((s) => s.items);
  const files = useStore((s) => s.files);
  const itemTags = useStore((s) => s.itemTags);
  const dark = useStore((s) => s.dark);
  const searchText = useStore((s) => s.searchText);
  const wholeLibrary = useStore((s) => s.searchWholeLibrary);
  const includeFulltext = useStore((s) => s.includeFulltext);
  const sortColumn = useStore((s) => s.sortColumn);
  const sortAscending = useStore((s) => s.sortAscending);
  const visible = useStore((s) => s.settings.visibleColumns as string[] | undefined) ?? ["title", "source", "authors", "year", "tags", "dateAdded"];
  const widths = useStore((s) => s.settings.columnWidths as Record<string, number> | undefined) ?? {};
  const state = getState();

  const scroller = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const [height, setHeight] = useState(600);
  const [insertion, setInsertion] = useState<number | null>(null);
  const [liveWidths, setLiveWidths] = useState<Record<string, number>>({});
  const [searching, setSearching] = useState(searchText);
  const typing = useRef(false);

  useEffect(() => { if (!typing.current) setSearching(searchText); }, [searchText]);

  const columns = useMemo(() => visible.map((k) => COLUMNS.find((c) => c.key === k)).filter(Boolean) as typeof COLUMNS, [visible]);
  const storedWidth = (key: string) => liveWidths[key] ?? widths[key] ?? COLUMNS.find((c) => c.key === key)!.width;
  // As on macOS: the title takes what the window has left (and follows the window's width); dragging a divider moves that
  // divider with the pointer and the columns after it along, so the table may grow wider than the window. What the user's
  // drags added to the title's share is kept as titleExtra.
  const [viewWidth, setViewWidth] = useState(0);
  const [liveExtra, setLiveExtra] = useState<number | null>(null);
  const extra = liveExtra ?? widths.titleExtra ?? 0;
  // When the window (or the space the inspector leaves) is too narrow for every column at its width, the other columns
  // give way in proportion, down to COLUMN_MIN each, so they all stay in view; only widths the user dragged wider than the
  // window make the table scroll sideways.
  const storedOthers = columns.reduce((sum, c) => sum + (c.key === "title" ? 0 : storedWidth(c.key)), 0);
  const squeeze = useMemo(() => {
    if (viewWidth <= 0 || (widths.titleExtra ?? 0) > 0) return 1;
    const room = viewWidth - 12 - TITLE_MIN;
    if (storedOthers <= room || storedOthers <= 0) return 1;
    // The column being dragged follows the pointer: only the others give way.
    const shrinkable = columns.reduce((sum, c) => sum + (c.key === "title" || c.key in liveWidths ? 0 : Math.max(0, storedWidth(c.key) - COLUMN_MIN)), 0);
    if (shrinkable <= 0) return 1;
    return Math.max(0, 1 - (storedOthers - room) / shrinkable);
  }, [viewWidth, extra, liveExtra, storedOthers, columns, widths, liveWidths]);
  const widthOf = (key: string) => {
    const w = storedWidth(key);
    return squeeze >= 1 || key === "title" || key in liveWidths ? w : Math.round(COLUMN_MIN + Math.max(0, w - COLUMN_MIN) * squeeze);
  };
  const othersWidth = columns.reduce((sum, c) => sum + (c.key === "title" ? 0 : widthOf(c.key)), 0);
  const titleWidth = viewWidth > 0 ? Math.max(TITLE_MIN, Math.round(viewWidth - 12 - othersWidth + extra)) : undefined;
  const titleStyle = titleWidth ? { width: titleWidth, flex: "none" } : { minWidth: TITLE_MIN };
  const minWidth = 12 + othersWidth + (titleWidth ?? TITLE_MIN);

  const resizeColumn = (e: React.PointerEvent, key: string) => {
    const title = titleWidth ?? TITLE_MIN;
    const extraStart = title - (viewWidth - 12 - othersWidth);
    const start = key === "title" ? title : widthOf(key);
    // A squeezed column is dragged from where it is shown: that width becomes its own.
    const squeezing = squeeze < 1;
    const shown = Object.fromEntries(columns.map((c) => [c.key, widthOf(c.key)]));
    const min = key === "title" ? TITLE_MIN : 40;
    let latest = start, latestExtra = extraStart;
    dragPointer(e, (dx) => {
      latest = Math.max(min, Math.round(start + dx));
      latestExtra = extraStart + latest - start;
      if (key !== "title") setLiveWidths({ [key]: latest });
      setLiveExtra(latestExtra);
    }, () => {
      const stored = { ...getState().settings.columnWidths, titleExtra: latestExtra };
      // Squeezed columns keep the width they are shown at: nothing jumps when the drag ends.
      if (squeezing) for (const c of columns) if (c.key !== "title" && c.key !== key) stored[c.key] = shown[c.key];
      if (key !== "title") stored[key] = latest;
      setSetting("columnWidths", stored);
      setLiveWidths({});
      setLiveExtra(null);
    });
  };

  const flat: FlatRow[] = useMemo(() => {
    const out: FlatRow[] = [];
    for (const id of rows) {
      out.push({ itemId: id });
      if (expanded.has(id)) for (const f of filesByItem[id] ?? []) out.push({ itemId: id, fileId: f });
    }
    return out;
  }, [rows, expanded, filesByItem]);

  const scopeName = scope === "all" ? t("所有文献") : scope === "unfiled" ? t("未分组") : scope === "trash" ? t("回收站")
    : scope.startsWith("group:") ? groups.get(scope.slice(6))?.name ?? "" : tags.find((tag) => `tag:${tag.id}` === scope)?.name ?? "";

  useLayoutEffect(() => {
    const el = scroller.current!;
    const measure = () => { setHeight(el.clientHeight); setViewWidth(el.clientWidth); };
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    measure();
    return () => observer.disconnect();
  }, []);

  useEffect(() => on("focusSearch", () => { searchRef.current?.focus(); searchRef.current?.select(); }), []);
  useEffect(() => on("focusList", () => scroller.current?.focus({ preventScroll: true })), []);
  useEffect(() => on("reveal", (id: string) => {
    setSelection([id]);
    anchor = id;
    requestAnimationFrame(() => scrollToItem(id));
  }));

  function setSelection(ids: string[], file: string | null = null) {
    setState({ selection: ids, fileSelection: file });
    call("library.select", { ids });
  }

  function scrollToItem(id: string) {
    const el = scroller.current;
    const index = (getState().rows.length, flatRef.current.findIndex((r) => r.itemId === id && !r.fileId));
    if (!el || index < 0) return;
    const top = index * ROW, bottom = top + ROW, head = 28;
    if (top < el.scrollTop) el.scrollTop = top;
    else if (bottom + head > el.scrollTop + el.clientHeight) el.scrollTop = bottom + head - el.clientHeight;
  }
  const flatRef = useRef(flat);
  flatRef.current = flat;

  const clickRow = (e: React.MouseEvent, row: FlatRow) => {
    scroller.current?.focus({ preventScroll: true });
    if (row.fileId) { setSelection([row.itemId], row.fileId); return; }
    const id = row.itemId;
    if (e.shiftKey && anchor && rows.includes(anchor)) {
      const a = rows.indexOf(anchor), b = rows.indexOf(id);
      setSelection(rows.slice(Math.min(a, b), Math.max(a, b) + 1));
    } else if (e.ctrlKey) {
      setSelection(selection.includes(id) ? selection.filter((x) => x !== id) : [...selection, id]);
      anchor = id;
    } else if (selection.length <= 1 || !selection.includes(id) || !pendingDragSelect.current) {
      setSelection([id]);
      anchor = id;
    }
  };
  const pendingDragSelect = useRef(false);

  const openRow = (row: FlatRow) => {
    if (row.fileId) call("file.open", { id: row.fileId });
    else call("item.open", { id: row.itemId });
  };

  const toggleExpanded = (id: string) => {
    const next = new Set(getState().expanded);
    if (!next.delete(id)) next.add(id);
    setState({ expanded: next });
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    const ids = selection;
    const move = (delta: number) => {
      const current = ids.length ? rows.indexOf(ids[ids.length - 1]) : -1;
      const next = Math.max(0, Math.min(rows.length - 1, current + delta));
      const id = rows[next];
      if (!id) return;
      if (e.shiftKey && anchor) {
        const a = rows.indexOf(anchor);
        setSelection(rows.slice(Math.min(a, next), Math.max(a, next) + 1).sort((x, y) => rows.indexOf(x) - rows.indexOf(y)));
      } else { setSelection([id]); anchor = id; }
      requestAnimationFrame(() => scrollToItem(id));
    };
    switch (e.key) {
      case "ArrowDown": move(1); break;
      case "ArrowUp": move(-1); break;
      case "PageDown": move(Math.floor(height / ROW)); break;
      case "PageUp": move(-Math.floor(height / ROW)); break;
      case "Home": move(-rows.length); break;
      case "End": move(rows.length); break;
      case "ArrowRight": { const next = new Set(expanded); ids.forEach((i) => next.add(i)); setState({ expanded: next }); break; }
      case "ArrowLeft": { const next = new Set(expanded); ids.forEach((i) => next.delete(i)); setState({ expanded: next }); break; }
      case "Enter": openItems(ids); break;
      case " ": toggleQuickLook(); break;
      case "a": if (e.ctrlKey) setSelection(rows); else return; break;
      case "Delete": case "Backspace": {
        if (ids.length === 0) return;
        const group = scopeGroupId(scope);
        if (fileSelection && scope !== "trash") call("files.trash", { ids: [fileSelection] });
        else if (scope === "trash") purgeItems(ids);
        else if (group && !e.shiftKey) call("items.removeFromGroup", { ids, group });
        else call("items.trash", { ids });
        break;
      }
      default: return;
    }
    e.preventDefault();
    e.stopPropagation();
  };

  const columnsMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    const entries: MenuEntry[] = COLUMNS.map((c) => ({
      label: c.title === "DOI" ? "DOI" : t(c.title), checked: visible.includes(c.key), disabled: c.key === "title",
      action: () => setSetting("visibleColumns", visible.includes(c.key) ? visible.filter((k) => k !== c.key) : [...visible, c.key]),
    }));
    openMenu([...entries, sep, { label: t("按自定义顺序排列"), action: () => call("library.sort", { column: null, ascending: true }) }], e.clientX, e.clientY);
  };

  const canReorder = searchText.trim().length === 0 && scope !== "trash";

  const insertionIndex = (e: React.DragEvent) => {
    const el = scroller.current!;
    const y = e.clientY - el.getBoundingClientRect().top + el.scrollTop - 28;
    let index = Math.round(y / ROW);
    index = Math.max(0, Math.min(flat.length, index));
    while (index < flat.length && flat[index]?.fileId) index++;
    return index;
  };

  const first = Math.max(0, Math.floor((scrollTop - 28) / ROW) - 6);
  const last = Math.min(flat.length, Math.ceil((scrollTop + height) / ROW) + 6);

  const selectedSet = useMemo(() => new Set(selection), [selection]);

  const renderCell = useCallback((key: string, item: Item) => {
    if (key === "tags") {
      const s = getState();
      const list = tagsOf(s, item.id);
      return (
        <>
          {list.slice(0, 1).map((tag) => <Chip key={tag.id} label={tag.name} color={tag.color} dark={dark} />)}
          {list.length > 1 && <span style={{ marginLeft: 4 }}><Chip label={`+${list.length - 1}`} color="#8E8E93" dark={dark} title={list.slice(1).map((x) => x.name).join("、")} /></span>}
        </>
      );
    }
    if (key === "rating") return <span style={{ color: "var(--star)", display: "inline-flex", gap: 1 }}>{Array.from({ length: item.rating }, (_, i) => <Star key={i} size={11} fill="currentColor" />)}</span>;
    return cellText(key, item, getState());
  }, [dark, itemTags]);

  const emptyMessage = rows.length > 0 ? null : searchText.trim() ? t("没有匹配的文献") : scope === "trash" ? t("回收站是空的") : scope === "all" ? t("把 PDF 拖到这里，或点击工具栏上的 + 添加文献") : t("这里还没有文献");

  return (
    <>
      <div className="titlebar-row drag" style={{ paddingLeft: leadInset || undefined, paddingRight: trailingInset ? trailingInset + 6 : undefined }}>
        <div className="list-title">
          <div className="name ellipsis">{scopeName}</div>
          <div className="count tabular">{t("%lld 项", rows.length)}</div>
        </div>
        <button className="glass-button" title={t("添加")} onClick={(e) => openMenuAt(e.currentTarget, addMenu())}><Plus size={18} /></button>
        <div className="glass-group">
          <button title={t("打开")} disabled={selection.length === 0} onClick={() => openItems(selection)}><BookOpen size={17} strokeWidth={1.7} /></button>
          <button title={t("翻译")} disabled={selection.length === 0} onClick={() => translate(selection)}><BookText size={17} strokeWidth={1.7} /></button>
          <button title={t("引用与导出")} disabled={selection.length === 0} onClick={(e) => openMenuAt(e.currentTarget, citeMenu(selection))}><Share size={16} strokeWidth={1.7} /></button>
        </div>
        <UpdateButton />
        <SearchBox inputRef={searchRef} value={searching} placeholder={t("搜索文献")} onChange={(v) => { typing.current = true; setSearching(v); call("library.search", { text: v }).finally(() => { typing.current = false; }); }} />
      </div>
      {tabs}
      {searchText.trim() && (
        <div className="scope-bar">
          <span className="secondary"><Search size={11} style={{ verticalAlign: -1 }} /> {t("搜索：")}</span>
          {scope === "all" ? <span>{t("所有文献")}</span> : (
            <Segmented value={wholeLibrary ? "all" : "current"} onChange={(v) => call("library.searchWhole", { on: v === "all" })} options={[{ value: "current", label: `「${scopeName}」` }, { value: "all", label: t("全部文献") }]} />
          )}
          <label className="checkbox" style={{ marginLeft: 10 }}><input type="checkbox" checked={includeFulltext} onChange={(e) => call("library.fulltext", { on: e.target.checked })} />{t("包含 PDF 全文")}</label>
        </div>
      )}
      <div ref={scroller} className="table" tabIndex={0} onKeyDown={onKeyDown} onScroll={(e) => setScrollTop(e.currentTarget.scrollTop)}
        onMouseDown={(e) => { if (e.target === e.currentTarget || (e.target as Element).classList.contains("table-inner")) setSelection([]); }}
        onDragOver={(e) => {
          if (!e.dataTransfer.types.includes(ITEMS_MIME) || !canReorder) return;
          e.preventDefault();
          e.dataTransfer.dropEffect = "link";
          setInsertion(insertionIndex(e));
        }}
        onDragLeave={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node)) setInsertion(null); }}
        onDrop={(e) => {
          setInsertion(null);
          const data = e.dataTransfer.getData(ITEMS_MIME);
          if (!data || !canReorder) return;
          e.preventDefault();
          e.stopPropagation();
          const index = insertionIndex(e);
          call("library.moveItems", { ids: data.split("\n").filter(Boolean), index: flat.slice(0, index).filter((r) => !r.fileId).length });
        }}>
        <div className="table-inner" style={{ height: 28 + flat.length * ROW + 8, minWidth }}>
          <div className="table-head" onContextMenu={columnsMenu}>
            {columns.map((c, index) => (
              <div key={c.key} className={`th${c.key === "title" ? " title" : ""}${index === columns.length - 1 ? " last" : ""}`} style={c.key === "title" ? titleStyle : { width: widthOf(c.key) }}
                onClick={() => call("library.sort", { column: c.sort, ascending: sortColumn === c.sort ? !sortAscending : true })}>
                <span className="ellipsis">{c.title === "DOI" ? "DOI" : t(c.title)}</span>
                {sortColumn === c.sort && (sortAscending ? <ChevronUp size={11} /> : <ChevronDown size={11} />)}
                {/* The last column ends at the list's edge: no divider there to drag. */}
                {index < columns.length - 1 && <span className="grip" onClick={(e) => e.stopPropagation()} onPointerDown={(e) => resizeColumn(e, c.key)} />}
              </div>
            ))}
          </div>
          {flat.slice(first, last).map((row, i) => {
            const index = first + i;
            const item = items.get(row.itemId);
            if (!item) return null;
            const top = 28 + index * ROW;
            if (row.fileId) {
              const file = files.get(row.fileId);
              if (!file) return null;
              return (
                <div key={row.fileId} className={`tr${fileSelection === row.fileId ? " selected" : ""}`} style={{ top, transform: "none" }} onClick={(e) => clickRow(e, row)} onDoubleClick={() => openRow(row)}
                  onMouseDown={(e) => { if (e.button === 1) e.preventDefault(); }} onAuxClick={(e) => { if (e.button === 1) { setSelection([row.itemId], row.fileId); setState({ quickLook: true }); } }}
                  onContextMenu={(e) => { e.preventDefault(); setSelection([row.itemId], row.fileId); openMenu(scope === "trash" ? itemMenu([row.itemId]) : fileMenu(file), e.clientX, e.clientY); }}>
                  <span style={{ width: 44, flex: "none" }} />
                  <FileText size={14} className="secondary" style={{ flex: "none" }} />
                  <span className="td ellipsis" style={{ fontSize: 12, flex: 1 }} title={file.fileName}>{file.title}</span>
                </div>
              );
            }
            const fileCount = filesByItem[item.id]?.length ?? 0;
            const standalone = item.kind === "standalone";
            return (
              <div key={item.id} className={`tr${selectedSet.has(item.id) && !fileSelection ? " selected" : ""}`} style={{ top }} draggable
                onAuxClick={(e) => { if (e.button === 1) { setSelection([item.id]); anchor = item.id; setState({ quickLook: true }); } }}
                onMouseDown={(e) => { if (e.button === 1) e.preventDefault(); pendingDragSelect.current = selectedSet.has(item.id) && !e.shiftKey && !e.ctrlKey && e.button === 0; if (!selectedSet.has(item.id) && e.button === 0 && !e.shiftKey && !e.ctrlKey) { setSelection([item.id]); anchor = item.id; } }}
                onMouseUp={(e) => { if (pendingDragSelect.current && e.button === 0) { pendingDragSelect.current = false; clickRow(e, row); } }}
                onClick={(e) => { if (e.shiftKey || e.ctrlKey) clickRow(e, row); }}
                onDoubleClick={(e) => { if (!(e.target as Element).closest("button")) openRow(row); }}
                onContextMenu={(e) => {
                  e.preventDefault();
                  const ids = selectedSet.has(item.id) ? selection : [item.id];
                  if (!selectedSet.has(item.id)) { setSelection(ids); anchor = item.id; }
                  openMenu(itemMenu(ids), e.clientX, e.clientY);
                }}
                onDragStart={(e) => {
                  pendingDragSelect.current = false;
                  const ids = selectedSet.has(item.id) ? selection : [item.id];
                  if (!selectedSet.has(item.id)) setSelection(ids);
                  setDraggingItems(true);
                  e.dataTransfer.setData(ITEMS_MIME, ids.join("\n"));
                  e.dataTransfer.effectAllowed = "copyLink";
                  const s = getState();
                  const first = filesOf(s, ids[0]).find((f) => f.isPdf);
                  // Dragging out to Explorer copies the paper.
                  if (first) e.dataTransfer.setData("DownloadURL", `application/pdf:${first.fileName}:${dragUrl(s, first.id)}`);
                }}
                onDragEnd={() => { setDraggingItems(false); setInsertion(null); }}>
                {columns.map((c) => {
                  if (c.key === "title") {
                    return (
                      <div key="title" className="td title" style={titleStyle}>
                        {fileCount > 0 && !standalone
                          ? <button className="disc" onClick={(e) => { e.stopPropagation(); toggleExpanded(item.id); }} onDoubleClick={(e) => e.stopPropagation()} onMouseDown={(e) => e.stopPropagation()}>{expanded.has(item.id) ? <ChevronDown size={12} /> : <ChevronRight size={12} />}</button>
                          : <span className="disc-space" />}
                        <FileText size={16} strokeWidth={1.5} className="secondary" style={{ flex: "none" }} />
                        {standalone && item.retrieving && <span className="spinner" />}
                        <span className="ellipsis" style={{ flex: 1 }} title={item.title}>{item.title}</span>
                        <TranslationProgress itemId={item.id} />
                      </div>
                    );
                  }
                  return <div key={c.key} className={`td${c.key === "dateAdded" || c.key === "dateModified" || c.key === "fileCount" || c.key === "readStatus" ? " dim" : ""}`} style={{ width: widthOf(c.key) }} title={c.key === "tags" || c.key === "rating" ? undefined : cellText(c.key, item, state)}>{renderCell(c.key, item)}</div>;
                })}
              </div>
            );
          })}
          {insertion !== null && <div className="insertion" style={{ top: 28 + insertion * ROW - 1 }} />}
        </div>
        {emptyMessage && <div className="empty">{scope === "all" && !searchText.trim() ? <><div className="big">{t("还没有文献")}</div><div>{emptyMessage}</div></> : <div>{emptyMessage}</div>}</div>}
      </div>
    </>
  );
}

function dragUrl(s: State, fileId: string) {
  const f = s.files.get(fileId);
  return f ? `https://folio.library/${f.path.split("/").map(encodeURIComponent).join("/")}` : "";
}

