import { useEffect, useState } from "react";
import { BarChart3, BookOpen, Copy, ScanText, Download, Edit3, ExternalLink, FileText, Folder, FolderOpen, Languages, Library, Link, Paperclip, Plus, Quote, RefreshCw, Search, Share, Star, StickyNote, Tag as TagIcon, Trash2, Undo2, X } from "lucide-react";
import { call } from "./rpc";
import { t } from "./i18n";
import { defaultFile, filesOf, getState, groupsForMenus, scopeGroupId, setSetting, setState, type FileRec, type Group, type Item, type Tag } from "./store";
import { sep, type MenuEntry } from "./ui/menu";
import { askText, confirm, dialog, openSheet, Sheet } from "./ui/sheet";
import { Field } from "./ui/controls";
import { TranslateSheet } from "./settings/TranslationPane";
import { ZoteroSheet } from "./settings/ZoteroSheet";

const icon = (C: any) => <C size={14} />;

// MARK: Opening

export function openReader(fileId: string, page?: number) {
  const s = getState();
  const existing = s.tabs.find((tab) => tab.fileId === fileId);
  if (existing) {
    setState({ activeTab: existing.key, tabs: s.tabs.map((tab) => tab === existing ? { ...tab, page } : tab) });
    return;
  }
  const tabs = [...s.tabs, { key: fileId, fileId, page }];
  setState({ tabs, activeTab: fileId });
  call("settings.set", { key: "openReaderTabs", value: tabs.map((tab) => tab.fileId) });
}

export function closeTab(key: string) {
  const s = getState();
  const index = s.tabs.findIndex((tab) => tab.key === key);
  if (index < 0) return;
  const tabs = s.tabs.filter((tab) => tab.key !== key);
  const neighbour = tabs[Math.min(index, tabs.length - 1)];
  setState({ tabs, activeTab: s.activeTab === key ? neighbour?.key ?? "library" : s.activeTab });
  call("settings.set", { key: "openReaderTabs", value: tabs.map((tab) => tab.fileId) });
}

export function selectNextTab(back: boolean) {
  const s = getState();
  const keys = ["library", ...s.tabs.map((tab) => tab.key)];
  const i = keys.indexOf(s.activeTab);
  setState({ activeTab: keys[(i + (back ? -1 : 1) + keys.length) % keys.length] });
}

export function openItems(ids: string[]) {
  for (const id of ids.slice(0, 10)) call("item.open", { id });
}

export function revealFirstFile(ids: string[]) {
  const s = getState();
  for (const id of ids) {
    const item = s.items.get(id);
    const file = item && defaultFile(s, item);
    if (file) { call("file.reveal", { id: file.id }); return; }
  }
}

// MARK: Sheets

export function addFiles() { return call("files.importPick"); }
export function importReferences() { return call("references.import"); }
export function zoteroImport() { return openSheet((close) => <ZoteroSheet close={close} />); }

function Swatches({ colors, value, onChange }: { colors: { hex: string | null; title: string; fill?: string }[]; value: string | null; onChange: (hex: string | null) => void }) {
  return (
    <div className="swatches" style={{ marginTop: 12 }}>
      {colors.map((c) => <button key={c.hex ?? "default"} title={c.title} className={`swatch${c.hex === value ? " on" : ""}`} style={{ background: c.fill ?? c.hex ?? "var(--accent)" }} onClick={() => onChange(c.hex)} />)}
    </div>
  );
}

function NameColorSheet({ title, placeholder, primary, initialName, initialColor, allowDefault, close }: { title: string; placeholder: string; primary: string; initialName: string; initialColor: string | null; allowDefault: boolean; close: (r?: { name: string; color: string | null }) => void }) {
  const [name, setName] = useState(initialName);
  const [color, setColor] = useState(initialColor);
  const presets = getState().statics.tagPresets.map((p) => ({ hex: p.hex as string | null, title: p.name }));
  const submit = () => { if (name.trim()) close({ name: name.trim(), color }); };
  return (
    <Sheet title={title} width={400} onEscape={() => close()} actions={
      <>
        <button className="btn" onClick={() => close()}>{t("取消")}</button>
        <button className="btn primary" disabled={!name.trim()} onClick={submit}>{primary}</button>
      </>}>
      <input className="field" style={{ marginTop: 6 }} autoFocus spellCheck={false} value={name} placeholder={placeholder} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => { e.stopPropagation(); if (e.key === "Enter") submit(); }} />
      <Swatches value={color} onChange={setColor} colors={allowDefault ? [{ hex: null, title: t("默认") }, ...presets] : presets} />
    </Sheet>
  );
}

export async function newGroup(parent: string | null = null, items: string[] = []): Promise<void> {
  const r = await openSheet<{ name: string; color: string | null }>((close) => <NameColorSheet title={parent ? t("新建子分组") : t("新建分组")} placeholder={t("分组名称")} primary={t("创建")} initialName="" initialColor={null} allowDefault close={close} />);
  if (!r) return;
  const id = await call<string>("group.create", { name: r.name, parent, color: r.color, items });
  if (id) call("library.scope", { scope: `group:${id}` });
}

export async function newTag(items: string[] = []) {
  const s = getState();
  const preset = s.statics.tagPresets[s.tags.length % s.statics.tagPresets.length]?.hex ?? "#007AFF";
  const r = await openSheet<{ name: string; color: string | null }>((close) => <NameColorSheet title={t("新建标签")} placeholder={t("标签名称")} primary={t("创建")} initialName="" initialColor={preset} allowDefault={false} close={close} />);
  if (r) call("tag.create", { name: r.name, color: r.color, items });
}

export async function editTag(tag: Tag) {
  const r = await openSheet<{ name: string; color: string | null }>((close) => <NameColorSheet title={t("编辑标签")} placeholder={t("标签名称")} primary={t("存储")} initialName={tag.name} initialColor={tag.color} allowDefault={false} close={close} />);
  if (r) call("tag.update", { id: tag.id, name: r.name, color: r.color });
}

export async function renameGroup(group: Group) {
  const name = await askText(t("重命名分组"), t("分组名称"), group.name, t("重命名"));
  if (name?.trim() && name !== group.name) call("group.rename", { id: group.id, name: name.trim() });
}

export async function deleteGroup(group: Group) {
  const answer = await dialog({ title: t("删除分组「%@」？", group.name), message: t("分组中的文献会保留在文献库中，也可以一并移到回收站。"), primary: t("删除分组"), secondary: t("删除分组并将文献移到回收站"), cancel: t("取消") });
  if (answer !== "cancel") call("group.delete", { id: group.id, trashItems: answer === "secondary" });
}

export async function deleteTag(tag: Tag) {
  const count = await call<number>("tag.itemCount", { id: tag.id });
  if (await confirm(t("删除标签「%@」？", tag.name), t("%lld 篇文献会失去这个标签，文献本身不受影响。", count), t("删除"), true)) call("tag.delete", { id: tag.id });
}

export async function emptyTrash() {
  if (await confirm(t("清空回收站？"), t("回收站中的文献和文件将被永久删除，无法恢复。"), t("清空回收站"), true)) call("trash.empty");
}

export async function purgeItems(ids: string[]) {
  if (await confirm(ids.length === 1 ? t("彻底删除这一项？") : t("彻底删除 %lld 项？", ids.length), t("文献和文件将被永久删除，无法恢复。"), t("彻底删除"), true)) call("items.purge", { ids });
}

function IdentifierSheet({ close }: { close: () => void }) {
  const [text, setText] = useState("");
  return (
    <Sheet title={t("通过标识符添加")} width={460} onEscape={close} actions={
      <>
        <button className="btn" onClick={close}>{t("取消")}</button>
        <button className="btn primary" disabled={!text.trim()} onClick={() => { close(); call("identifiers.add", { text }); }}>{t("添加")}</button>
      </>}>
      <textarea className="field" autoFocus rows={5} style={{ marginTop: 6 }} spellCheck={false} placeholder={t("DOI、arXiv ID 或 ISBN，每行一个")} value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.stopPropagation()} />
    </Sheet>
  );
}
export function addByIdentifier() { return openSheet((close) => <IdentifierSheet close={close} />); }

function ManualMatchSheet({ item, close }: { item: Item; close: () => void }) {
  const [query, setQuery] = useState(item.title.replace(/\.[^.]{1,5}$/, ""));
  const [results, setResults] = useState<any[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [chosen, setChosen] = useState(-1);
  const search = async (q: string) => {
    setBusy(true); setChosen(-1);
    try { setResults(await call("match.search", { query: q })); } catch { setResults([]); }
    setBusy(false);
  };
  useEffect(() => { search(query); }, []);
  return (
    <Sheet title={t("手动匹配元数据")} width={560} onEscape={close} actions={
      <>
        <button className="btn" onClick={close}>{t("取消")}</button>
        <button className="btn primary" disabled={chosen < 0} onClick={() => { close(); call("match.apply", { index: chosen, item: item.id }); }}>{t("使用所选")}</button>
      </>}>
      <div style={{ marginTop: 6, display: "flex", gap: 8 }}>
        <Field value={query} onCommit={(v) => { setQuery(v); search(v); }} placeholder={t("标题、DOI、arXiv ID 或 ISBN")} autoFocus />
      </div>
      <div className="body" style={{ height: 300, marginTop: 10 }}>
        {busy && <div className="secondary" style={{ padding: 12, display: "flex", gap: 8, alignItems: "center" }}><span className="spinner" />{t("正在检索…")}</div>}
        {!busy && results?.length === 0 && <div className="secondary" style={{ padding: 12 }}>{t("没有找到匹配的文献")}</div>}
        {!busy && results?.map((r) => (
          <div key={r.index} className={`result-row${chosen === r.index ? " selected" : ""}`} onClick={() => setChosen(r.index)} onDoubleClick={() => { close(); call("match.apply", { index: r.index, item: item.id }); }}>
            <div style={{ fontWeight: 600 }}>{r.title}</div>
            <div className="secondary" style={{ fontSize: 12 }}>{[r.authors, r.year, r.source].filter(Boolean).join(" · ")}</div>
          </div>
        ))}
      </div>
    </Sheet>
  );
}
export function manualMatch(item: Item) { return openSheet((close) => <ManualMatchSheet item={item} close={close} />); }

export function translate(ids: string[], file?: FileRec) {
  const s = getState();
  const files = file ? [file] : ids.map((id) => filesOf(s, id).find((f) => f.isPdf && !f.translationKind)).filter(Boolean) as FileRec[];
  if (files.length === 0) { call("toast.show", { message: t("所选文献没有可翻译的 PDF"), icon: "question" }); return; }
  const waiting = files.filter((f) => !s.jobs[f.itemId]);
  if (waiting.length === 0) { call("toast.show", { message: t("这篇论文正在翻译"), icon: "translate" }); return; }
  openSheet((close) => <TranslateSheet files={waiting} close={close} />);
}

// MARK: Menus

export function addMenu(): MenuEntry[] {
  return [
    { label: t("添加文件…"), icon: icon(Plus), key: "Ctrl+O", action: addFiles },
    { label: t("通过标识符添加…"), icon: icon(Link), key: "Ctrl+Shift+O", action: addByIdentifier },
    sep,
    { label: t("新建分组"), icon: icon(Folder), key: "Ctrl+Shift+N", action: () => newGroup() },
    { label: t("新建标签…"), icon: icon(TagIcon), action: () => newTag() },
    sep,
    { label: t("导入 BibTeX / RIS…"), icon: icon(Download), action: importReferences },
    { label: t("从 Zotero 导入…"), icon: icon(Library), action: zoteroImport },
  ];
}

export function citeMenu(ids: string[]): MenuEntry[] {
  const s = getState();
  const any = ids.some((id) => s.items.get(id)?.kind === "regular");
  const style = s.statics.citationStyles.find((c) => c.raw === s.settings.citationStyle) ?? s.statics.citationStyles[0];
  return [
    { label: t("复制 %@ 引用", style?.name ?? ""), icon: icon(Copy), disabled: !any, key: "Ctrl+Shift+C", action: () => call("cite.copy", { ids }) },
    { label: t("复制引用"), icon: icon(Copy), disabled: !any, submenu: s.statics.citationStyles.map((c) => ({ label: c.name, checked: c.raw === s.settings.citationStyle, action: () => call("cite.copy", { ids, style: c.raw }) })) },
    { label: t("复制文内引用"), icon: icon(Quote), disabled: !any, action: () => call("cite.inText", { ids }) },
    sep,
    ...s.statics.referenceFormats.map((f) => ({ label: t("导出 %@…", f.name), icon: icon(Share), disabled: !any, action: () => call("references.export", { ids, format: f.raw }) })),
  ];
}

function openWithMenu(file: FileRec): MenuEntry {
  return {
    label: t("打开方式"), icon: icon(ExternalLink), submenu: [
      ...(file.isPdf ? [{ label: t("在 Folio 中阅读"), icon: icon(BookOpen), action: () => openReader(file.id) } as MenuEntry] : []),
      { label: t("系统默认应用"), action: () => call("file.openSystem", { id: file.id }) },
      sep,
      { label: t("其他应用…"), action: () => call("file.openWithDialog", { id: file.id }) },
    ],
  };
}

function groupMenu(selected: Item[]): MenuEntry {
  const s = getState();
  const ids = selected.map((i) => i.id);
  const here = scopeGroupId(s.scope);
  const groups = groupsForMenus(s).filter((g) => g.group.id !== here);
  return {
    label: t("添加到"), icon: icon(Folder), submenu: [
      ...groups.map(({ group, depth }): MenuEntry => ({
        label: group.name, indent: depth, checked: ids.every((id) => s.itemGroups[id]?.includes(group.id)),
        action: () => call("items.addToGroup", { ids, group: group.id }),
      })),
      ...(groups.length === 0 ? [{ label: t("没有其他分组"), disabled: true } as MenuEntry] : []),
      sep,
      { label: t("新建分组…"), icon: icon(Plus), action: () => newGroup(null, ids) },
    ],
  };
}

function tagMenu(ids: string[]): MenuEntry {
  const s = getState();
  return {
    label: t("标签"), icon: icon(TagIcon), submenu: [
      ...s.tags.map((tag): MenuEntry => {
        const all = ids.every((id) => s.itemTags[id]?.includes(tag.id));
        return { label: tag.name, dot: tag.color, checked: all, action: () => call("items.setTag", { tag: tag.id, ids, on: !all }) };
      }),
      sep,
      { label: t("新建标签…"), icon: icon(Plus), action: () => newTag(ids) },
    ],
  };
}

function translateEntry(itemId: string, run: () => void): MenuEntry {
  return getState().jobs[itemId]
    ? { label: t("取消翻译"), icon: icon(X), action: () => call("translation.cancel", { item: itemId }) }
    : { label: t("翻译全文…"), icon: icon(Languages), key: "Ctrl+Alt+T", action: run };
}

export function showNotes() {
  setState({ activeTab: "library", inspectorPage: "notes" });
  if (!getState().settings.inspectorVisible) setSetting("inspectorVisible", true);
}

export function itemMenu(ids: string[]): MenuEntry[] {
  const s = getState();
  const selected = ids.map((id) => s.items.get(id)).filter(Boolean) as Item[];
  if (selected.length === 0) return [];
  if (s.scope === "trash") {
    return [
      { label: t("恢复"), icon: icon(Undo2), action: () => call("items.restore", { ids }) },
      { label: t("彻底删除"), icon: icon(Trash2), action: () => purgeItems(ids) },
    ];
  }
  const single = selected.length === 1 ? selected[0] : null;
  const allRegular = selected.every((i) => i.kind === "regular");
  const entries: MenuEntry[] = [{ label: t("打开"), icon: icon(FolderOpen), key: "Enter", action: () => openItems(ids) }];
  const singleFile = single && defaultFile(s, single);
  if (singleFile) entries.push(openWithMenu(singleFile));
  entries.push(sep, groupMenu(selected), tagMenu(ids));
  if (allRegular) {
    entries.push(
      { label: t("阅读状态"), icon: icon(BookOpen), submenu: s.statics.statuses.map((st) => ({ label: st.name, checked: selected.every((i) => i.readStatus === st.raw), action: () => call("items.update", { ids, patch: { readStatus: st.raw } }) })) },
      { label: t("评分"), icon: icon(Star), submenu: [0, 1, 2, 3, 4, 5].map((v) => ({ label: v === 0 ? t("无评分") : "★".repeat(v), checked: selected.every((i) => i.rating === v), action: () => call("items.update", { ids, patch: { rating: v } }) })) },
      { label: t("引用与导出"), icon: icon(Share), submenu: citeMenu(ids) },
    );
  }
  entries.push(sep);
  if (single) {
    entries.push({ label: t("编辑笔记"), icon: icon(StickyNote), key: "Ctrl+Alt+N", action: showNotes });
    if (s.noted.has(single.id)) entries.push({ label: t("导出笔记…"), icon: icon(Share), action: () => call("note.export", { item: single.id }) });
    if (singleFile?.isPdf) {
      entries.push(translateEntry(single.id, () => translate([single.id])));
      entries.push({ label: t("识别文字（OCR）"), icon: icon(ScanText), disabled: !!s.ocr[singleFile.id], action: () => call("ocr.recognize", { files: [singleFile.id] }) });
    }
    entries.push(sep);
    if (single.kind === "regular") {
      entries.push({ label: t("添加文件…"), icon: icon(Paperclip), action: () => call("files.attachPick", { item: single.id }) });
      entries.push({ label: t("重新检索元数据"), icon: icon(RefreshCw), key: "Ctrl+Alt+R", action: () => call("items.retrieve", { ids }) });
      if (single.hasJournal) entries.push({ label: t("刷新期刊指标"), icon: icon(BarChart3), action: () => refreshJournalMetrics(ids) });
    } else {
      entries.push({ label: t("重新检索元数据"), icon: icon(RefreshCw), disabled: single.metadataState === "Pending" || !filesOf(s, single.id)[0]?.isPdf, action: () => call("items.retrieve", { ids }) });
      entries.push({ label: t("手动匹配…"), icon: icon(Search), action: () => manualMatch(single) });
    }
  } else if (selected.some((i) => defaultFile(s, i)?.isPdf)) {
    entries.push({ label: t("翻译全文…"), icon: icon(Languages), action: () => translate(ids) });
  }
  if (!single && selected.some((i) => i.hasJournal)) entries.push({ label: t("刷新期刊指标"), icon: icon(BarChart3), action: () => refreshJournalMetrics(ids) });
  if (selected.some((i) => defaultFile(s, i))) entries.push({ label: t("在资源管理器中显示"), icon: icon(Folder), key: "Ctrl+Shift+R", action: () => revealFirstFile(ids) });
  entries.push(sep);
  const group = scopeGroupId(s.scope);
  if (group) entries.push({ label: t("从当前分组移除"), icon: icon(X), key: "Delete", action: () => call("items.removeFromGroup", { ids, group }) });
  entries.push({ label: t("删除"), icon: icon(Trash2), key: group ? "Shift+Delete" : "Delete", action: () => call("items.trash", { ids }) });
  return entries;
}

export function fileMenu(file: FileRec): MenuEntry[] {
  const s = getState();
  const item = s.items.get(file.itemId);
  return [
    { label: t("打开"), icon: icon(FolderOpen), action: () => call("file.open", { id: file.id }) },
    openWithMenu(file),
    sep,
    { label: t("设为默认打开文件"), icon: icon(Star), disabled: item?.defaultFileId === file.id, action: () => call("file.setDefault", { id: file.id }) },
    { label: t("重命名…"), icon: icon(Edit3), action: async () => {
      const name = await askText(t("重命名文件"), t("文件名"), file.fileName.replace(/\.[^.]+$/, ""), t("重命名"));
      if (name?.trim()) call("file.rename", { id: file.id, name: name.trim() });
    } },
    ...(file.isPdf && !file.translationKind ? [translateEntry(file.itemId, () => translate([file.itemId], file))] : []),
    { label: t("在资源管理器中显示"), icon: icon(Folder), action: () => call("file.reveal", { id: file.id }) },
    sep,
    { label: t("删除"), icon: icon(Trash2), action: () => call("files.trash", { ids: [file.id] }) },
  ];
}

/** The menu bar of the macOS app, under one button. */
export function appMenu(): MenuEntry[] {
  const s = getState();
  const ids = s.selection;
  return [
    { label: t("文件"), icon: icon(FileText), submenu: [
      ...addMenu(),
      sep,
      { label: t("导出参考文献…"), disabled: ids.length === 0, submenu: s.statics.referenceFormats.map((f) => ({ label: f.name, action: () => call("references.export", { ids, format: f.raw }) })) },
      { label: t("导出笔记…"), disabled: ids.length !== 1 || !s.noted.has(ids[0]), action: () => call("note.export", { item: ids[0] }) },
    ] },
    { label: t("条目"), icon: icon(Library), disabled: ids.length === 0, submenu: itemMenu(ids) },
    { label: t("显示"), icon: icon(BookOpen), submenu: [
      { label: t("显示/隐藏边栏"), key: "Ctrl+Alt+S", action: () => setSetting("sidebarVisible", !s.settings.sidebarVisible) },
      { label: t("显示/隐藏检查器"), key: "Ctrl+Alt+I", action: () => setSetting("inspectorVisible", !s.settings.inspectorVisible) },
      { label: t("检查器"), submenu: ([["info", t("信息")], ["annotations", t("标注")], ["notes", t("笔记")]] as const).map(([page, label]) => ({ label, checked: s.inspectorPage === page, action: () => { setState({ inspectorPage: page }); if (!s.settings.inspectorVisible) setSetting("inspectorVisible", true); } })) },
      sep,
      { label: t("按自定义顺序排列"), action: () => call("library.sort", { column: null, ascending: true }) },
      sep,
      { label: t("全屏"), key: "F11", action: () => call("window.fullScreen") },
    ] },
    sep,
    { label: t("设置…"), key: "Ctrl+,", action: () => call("window.settings") },
    { label: t("检查更新…"), action: () => call("update.check") },
    { label: t("帮助"), submenu: [
      { label: t("欢迎使用 Folio…"), action: () => call("window.onboarding") },
      { label: t("在资源管理器中显示文献库"), action: () => call("library.revealRoot") },
      sep,
      { label: t("Folio 主页"), action: () => call("shell.open", { target: "https://alonemo-nnqc.github.io/Folio/" }) },
      { label: t("报告问题…"), action: () => call("shell.open", { target: "https://github.com/Alonemo-Nnqc/Folio/issues" }) },
    ] },
    { label: t("关于 Folio"), action: () => dialog({ title: "Folio", message: `${s.statics.version} (${s.statics.channel})\n\n${t("轻量的文献管理软件")}` }) },
    sep,
    { label: t("退出 Folio"), action: () => call("window.quit") },
  ];
}

/** 刷新期刊指标 (META-30): the selected items' journals are asked again, first in the queue. */
export async function refreshJournalMetrics(ids: string[]) {
  const r = await call<{ needsKey: boolean }>("journalMetrics.refresh", { items: ids });
  if (r.needsKey) {
    call("toast.show", { message: t("请先在设置中填写 easyScholar 密钥"), icon: "key" });
    call("window.settings", { page: "retrieval" });
  } else call("toast.show", { message: t("正在刷新期刊指标…"), icon: "refresh" });
}
