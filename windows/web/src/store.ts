import { useSyncExternalStore } from "react";
import { call, inHost, on } from "./rpc";

const inHostWindow = inHost;
/** What the host can do, known after boot. */
const statics = { translucency: false };
import { setStrings } from "./i18n";

export interface Author { family: string; given?: string; full: string }
export interface Item {
  id: string; kind: "regular" | "standalone"; type: string; typeName: string; title: string; authors: Author[]; authorsList: string;
  year?: number; source?: string; volume?: string; issue?: string; pages?: string; publisher?: string; doi?: string; arxivId?: string; isbn?: string; url?: string;
  abstract?: string; citationKey?: string; rating: number; readStatus: number; readStatusName: string; defaultFileId?: string; metadataState: string;
  dateAdded: number; dateModified: number; trashed: boolean; retrieving: boolean;
  /** The item has a journal worth asking easyScholar about (META-30). */
  hasJournal: boolean;
  /** Its journal's ranks: null until looked up; no badges when easyScholar does not list it. */
  journalMetrics: JournalMetrics | null;
}
export interface JournalBadge { kind: string; text: string; detail: string; emphasized: boolean }
export interface JournalMetrics { badges: JournalBadge[]; rank?: string; impactFactor?: string; summary: string }
/** 期刊指标's queue and key, for the inspector's hints and 设置. */
export interface JournalMetricsState { key: string; hasKey: boolean; autoFetch: boolean; pending: number; status?: string; attention: boolean; keyPage: string }
export interface FileRec {
  id: string; itemId: string; fileName: string; path: string; isPdf: boolean; translationOf?: string; translationKind?: "mono" | "dual"; translatedBy?: string;
  sha: string; dateAdded: number; title: string; tabTitle: string; tabTip: string;
}
export interface Group { id: string; parentId?: string; name: string; color?: string }
export interface Tag { id: string; name: string; color: string }
export interface Job { fileId: string; fraction?: number; stage: string; preview?: string }
export interface Toast { id: number; message: string; icon: string; actionTitle?: string }

export interface ReaderTabState { key: string; fileId: string; page?: number }

export interface State {
  items: Map<string, Item>;
  files: Map<string, FileRec>;
  filesByItem: Record<string, string[]>;
  groups: Map<string, Group>;
  topGroups: string[];
  childGroups: Record<string, string[]>;
  tags: Tag[];
  itemTags: Record<string, string[]>;
  itemGroups: Record<string, string[]>;
  noted: Set<string>;
  counts: Record<string, number>;
  root: string;
  libraryVersion: number;

  rows: string[];
  scope: string;
  searchText: string;
  searchWholeLibrary: boolean;
  includeFulltext: boolean;
  sortColumn?: string;
  sortAscending: boolean;

  selection: string[];
  fileSelection: string | null;
  expanded: Set<string>;

  settings: Record<string, any>;
  jobs: Record<string, Job>;
  journalMetrics: JournalMetricsState | null;
  /** 扫描件识别 under way, by file: pages done of pages to do (OCR-01). */
  ocr: Record<string, { done: number; total: number }>;
  toast: Toast | null;
  tabs: ReaderTabState[];
  activeTab: string; // "library" or a reader tab's key
  inspectorPage: "info" | "annotations" | "notes";
  /** 快速预览 of the selection is open. */
  quickLook: boolean;
  captionWidth: number;
  readerNotes: Record<string, boolean>; // reader tabs with their notes panel open
  windowState: string;
  active: boolean;
  dark: boolean;
  statics: Statics;
}

export interface Statics {
  version: string; channel: string; translucency: boolean;
  annotationColors: { key: string; title: string; hex: string }[];
  tagPresets: { name: string; hex: string }[];
  citationStyles: { raw: string; name: string }[];
  referenceFormats: { raw: string; name: string }[];
  itemTypes: { raw: string; name: string }[];
  statuses: { raw: number; name: string }[];
  homeFolder: string; userName: string;
}

let state: State = {
  items: new Map(), files: new Map(), filesByItem: {}, groups: new Map(), topGroups: [], childGroups: {}, tags: [], itemTags: {}, itemGroups: {}, noted: new Set(), counts: {}, root: "", libraryVersion: 0,
  rows: [], scope: "all", searchText: "", searchWholeLibrary: false, includeFulltext: false, sortAscending: true,
  selection: [], fileSelection: null, expanded: new Set(), settings: {}, jobs: {}, journalMetrics: null, ocr: {}, toast: null, tabs: [], activeTab: "library", inspectorPage: "info", quickLook: false,
  captionWidth: 138, readerNotes: {}, windowState: "normal", active: true, dark: false,
  statics: { version: "", channel: "", translucency: false, annotationColors: [], tagPresets: [], citationStyles: [], referenceFormats: [], itemTypes: [], statuses: [], homeFolder: "", userName: "" },
};

const subscribers = new Set<() => void>();
export function getState() { return state; }
export function setState(patch: Partial<State>) {
  state = { ...state, ...patch };
  subscribers.forEach((s) => s());
}
export function useStore<T>(selector: (s: State) => T): T {
  return useSyncExternalStore((cb) => { subscribers.add(cb); return () => subscribers.delete(cb); }, () => selector(state));
}

function applyLibrary(l: any) {
  const items = l.full ? new Map<string, Item>() : new Map(state.items);
  const files = l.full ? new Map<string, FileRec>() : new Map(state.files);
  for (const i of l.items ?? []) items.set(i.id, i);
  for (const id of l.removedItems ?? []) items.delete(id);
  for (const f of l.files ?? []) files.set(f.id, f);
  for (const id of l.removedFiles ?? []) files.delete(id);
  setState({
    items, files, filesByItem: l.filesByItem ?? {}, groups: new Map((l.groups ?? []).map((g: Group) => [g.id, g])), topGroups: l.topGroups ?? [], childGroups: l.childGroups ?? {},
    tags: l.tags ?? [], itemTags: l.itemTags ?? {}, itemGroups: l.itemGroups ?? {}, noted: new Set(l.noted ?? []), counts: l.counts ?? {}, root: l.root ?? state.root, libraryVersion: state.libraryVersion + 1,
  });
  closeMissingTabs();
}

function applyRows(r: any) {
  const present = new Set<string>(r.rows);
  const selection = state.selection.filter((id) => present.has(id));
  const changed = selection.length !== state.selection.length;
  setState({ rows: r.rows, scope: r.scope, searchText: r.searchText, searchWholeLibrary: !!r.searchWholeLibrary, includeFulltext: !!r.includeFulltext, sortColumn: r.sortColumn, sortAscending: r.sortAscending, selection });
  if (changed) call("library.select", { ids: selection });
}

function closeMissingTabs() {
  const tabs = state.tabs.filter((t) => state.files.has(t.fileId));
  if (tabs.length !== state.tabs.length) {
    setState({ tabs, activeTab: tabs.some((t) => t.key === state.activeTab) ? state.activeTab : "library" });
    rememberTabs();
  }
}

export function rememberTabs() {
  call("settings.set", { key: "openReaderTabs", value: state.tabs.map((t) => t.fileId) });
}

function resolveDark(settings: Record<string, any>) {
  const a = settings.appearance;
  return a === "dark" || (a !== "light" && matchMedia("(prefers-color-scheme: dark)").matches);
}

function applyTheme(settings: Record<string, any>) {
  const dark = resolveDark(settings);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  if (dark !== state.dark) setState({ dark });
  call("window.theme", { dark });
  applyTranslucency(settings.backgroundTranslucency ?? 0);
}

/** How much of the panels' colour stays over the desktop at a 背景透明度 of `amount` (1 opaque), as in the macOS app. */
export function veilFor(amount: number) { return amount > 0.001 ? 0.94 * Math.pow(1 - amount, 1.3) : 1; }

const SURFACES = ["--window", "--sidebar", "--inspector", "--content"];
let translucentNow = -1;
/** 背景透明度: the window's panels let the desktop (Acrylic) show through; text and pages stay as they are. */
export function applyTranslucency(amount: number) {
  if (!statics.translucency) amount = 0;
  const root = document.documentElement;
  for (const name of SURFACES) root.style.removeProperty(name);
  translucentNow = amount;
  const veil = veilFor(amount);
  root.classList.toggle("translucent", veil < 1);
  root.style.setProperty("--veil", String(veil));
  if (veil < 1) {
    const styles = getComputedStyle(root);
    for (const name of SURFACES) {
      const base = styles.getPropertyValue(name).trim();
      const share = name === "--sidebar" ? veil * 0.8 : veil;
      root.style.setProperty(name, `color-mix(in srgb, ${base} ${(share * 100).toFixed(1)}%, transparent)`);
    }
  }
  if (inHostWindow) call("window.translucency", { value: amount });
}
export function currentTranslucency() { return translucentNow; }

/** Loads everything from the app; returns once the first render can happen. */
export async function boot(route: string) {
  const b = await call("app.boot");
  setStrings(b.strings, b.isEnglish);
  statics.translucency = !!b.translucency;
  document.documentElement.lang = b.isEnglish ? "en" : "zh-Hans";
  setState({
    settings: b.settings, jobs: b.jobs ?? {}, captionWidth: b.captionWidth, windowState: b.windowState ?? "normal",
    statics: { version: b.version, channel: b.channel, translucency: !!b.translucency, annotationColors: b.annotationColors, tagPresets: b.tagPresets, citationStyles: b.citationStyles, referenceFormats: b.referenceFormats, itemTypes: b.itemTypes, statuses: b.statuses, homeFolder: b.homeFolder, userName: b.userName },
  });
  applyLibrary(b.library);
  applyRows(b.rows);
  applyTheme(b.settings);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => applyTheme(state.settings));
  on("library", applyLibrary);
  on("rows", applyRows);
  on("settings", (s) => { setState({ settings: s }); applyTheme(s); });
  on("translation.jobs", (jobs) => setState({ jobs }));
  on("journalMetrics", (journalMetrics) => setState({ journalMetrics }));
  on("ocr", (ocr) => setState({ ocr }));
  call("ocr.state").then((ocr) => setState({ ocr: ocr ?? {} })).catch(() => {});
  call("journalMetrics.state").then((journalMetrics) => setState({ journalMetrics })).catch(() => {});
  on("toast", (toast) => setState({ toast }));
  on("window.state", (windowState) => setState({ windowState }));
  on("window.active", (active) => setState({ active }));
  on("system.changed", () => applyTheme(state.settings));
  if (route === "main" && b.settings.reopenReaderTabs) {
    const tabs = (b.settings.openReaderTabs as string[]).filter((id) => state.files.has(id)).map((fileId) => ({ key: fileId, fileId }));
    setState({ tabs });
  }
}

export function setSetting(key: string, value: unknown) {
  setState({ settings: { ...state.settings, [key]: value } });
  return call("settings.set", { key, value });
}

// Derived helpers.

export function filesOf(s: State, itemId: string): FileRec[] {
  return (s.filesByItem[itemId] ?? []).map((id) => s.files.get(id)).filter(Boolean) as FileRec[];
}

export function tagsOf(s: State, itemId: string): Tag[] {
  const ids = s.itemTags[itemId] ?? [];
  return ids.map((id) => s.tags.find((t) => t.id === id)).filter(Boolean) as Tag[];
}

export function defaultFile(s: State, item: Item): FileRec | undefined {
  const files = filesOf(s, item.id);
  return files.find((f) => f.id === item.defaultFileId) ?? files[0];
}

/** Groups nest at most four levels deep (SIDE-17); a top-level group is level 1. */
export const MAX_GROUP_DEPTH = 4;

/** Every group in sidebar order, each followed by its subgroups; depth 0 at the top level. */
export function groupsForMenus(s: State): { group: Group; depth: number }[] {
  const out: { group: Group; depth: number }[] = [];
  const seen = new Set<string>();
  const visit = (ids: string[], depth: number) => {
    for (const id of ids) {
      const g = s.groups.get(id);
      if (!g || seen.has(id)) continue;
      seen.add(id);
      out.push({ group: g, depth });
      visit(s.childGroups[id] ?? [], depth + 1);
    }
  };
  visit(s.topGroups, 0);
  return out;
}

/** Ancestor ids from the top level down, without the group itself. */
export function groupAncestors(s: State, id: string): string[] {
  const chain: string[] = [];
  const seen = new Set([id]);
  for (let parent = s.groups.get(id)?.parentId; parent && !seen.has(parent) && s.groups.has(parent); parent = s.groups.get(parent)?.parentId) {
    seen.add(parent);
    chain.unshift(parent);
  }
  return chain;
}

/** The group's level: 1 at the top level. */
export function groupDepth(s: State, id: string): number {
  return groupAncestors(s, id).length + 1;
}

/** Levels the group and its subgroups span: 1 without subgroups. */
export function groupSubtreeHeight(s: State, id: string): number {
  const seen = new Set([id]);
  const height = (g: string): number => 1 + Math.max(0, ...(s.childGroups[g] ?? []).filter((c) => !seen.has(c) && seen.add(c)).map(height));
  return height(id);
}

/** Whether a subgroup can be created inside the group. */
export function canAddSubgroup(s: State, id: string): boolean {
  return s.groups.has(id) && groupDepth(s, id) < MAX_GROUP_DEPTH;
}

export function scopeGroupId(scope: string) { return scope.startsWith("group:") ? scope.slice(6) : null; }
