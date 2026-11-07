import { useSyncExternalStore } from "react";
import { call, on } from "./rpc";
import { setStrings } from "./i18n";

export interface Author { family: string; given?: string; full: string }
export interface Item {
  id: string; kind: "regular" | "standalone"; type: string; typeName: string; title: string; authors: Author[]; authorsList: string;
  year?: number; source?: string; volume?: string; issue?: string; pages?: string; publisher?: string; doi?: string; arxivId?: string; isbn?: string; url?: string;
  abstract?: string; citationKey?: string; rating: number; readStatus: number; readStatusName: string; defaultFileId?: string; metadataState: string;
  dateAdded: number; dateModified: number; trashed: boolean; retrieving: boolean;
}
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
  toast: Toast | null;
  tabs: ReaderTabState[];
  activeTab: string; // "library" or a reader tab's key
  inspectorPage: "info" | "annotations" | "notes";
  captionWidth: number;
  readerNotes: Record<string, boolean>; // reader tabs with their notes panel open
  windowState: string;
  active: boolean;
  dark: boolean;
  statics: Statics;
}

export interface Statics {
  version: string; channel: string;
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
  selection: [], fileSelection: null, expanded: new Set(), settings: {}, jobs: {}, toast: null, tabs: [], activeTab: "library", inspectorPage: "info",
  captionWidth: 138, readerNotes: {}, windowState: "normal", active: true, dark: false,
  statics: { version: "", channel: "", annotationColors: [], tagPresets: [], citationStyles: [], referenceFormats: [], itemTypes: [], statuses: [], homeFolder: "", userName: "" },
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
}

/** Loads everything from the app; returns once the first render can happen. */
export async function boot(route: string) {
  const b = await call("app.boot");
  setStrings(b.strings, b.isEnglish);
  document.documentElement.lang = b.isEnglish ? "en" : "zh-Hans";
  setState({
    settings: b.settings, jobs: b.jobs ?? {}, captionWidth: b.captionWidth, windowState: b.windowState ?? "normal",
    statics: { version: b.version, channel: b.channel, annotationColors: b.annotationColors, tagPresets: b.tagPresets, citationStyles: b.citationStyles, referenceFormats: b.referenceFormats, itemTypes: b.itemTypes, statuses: b.statuses, homeFolder: b.homeFolder, userName: b.userName },
  });
  applyLibrary(b.library);
  applyRows(b.rows);
  applyTheme(b.settings);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => applyTheme(state.settings));
  on("library", applyLibrary);
  on("rows", applyRows);
  on("settings", (s) => { setState({ settings: s }); applyTheme(s); });
  on("translation.jobs", (jobs) => setState({ jobs }));
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

export function groupsForMenus(s: State): { group: Group; depth: number }[] {
  const out: { group: Group; depth: number }[] = [];
  for (const id of s.topGroups) {
    const g = s.groups.get(id);
    if (!g) continue;
    out.push({ group: g, depth: 0 });
    for (const c of s.childGroups[id] ?? []) {
      const child = s.groups.get(c);
      if (child) out.push({ group: child, depth: 1 });
    }
  }
  return out;
}

export function scopeGroupId(scope: string) { return scope.startsWith("group:") ? scope.slice(6) : null; }
