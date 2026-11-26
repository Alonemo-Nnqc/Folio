import { getState, setState } from "../store";
import type { EditorView } from "@codemirror/view";
import { call } from "../rpc";

// 设置 ▸ Markdown: how documents and notes are set, and what the editor does by itself. The keys and defaults are the Mac's
// (MarkdownPreferences.swift).

export const MD = {
  markdownFontSize: 15, markdownPanelFontSize: 13, markdownTypeface: "system", markdownLineHeight: 1.6, markdownParagraphSpacing: 0.4,
  markdownHeadingScale: 1, markdownCodeScale: 0.9, markdownReadableWidth: 760, markdownCodeIndent: 4, markdownZoom: 1, markdownPanelZoom: 1,
  markdownShowsHandles: true, markdownShowsPlaceholders: true, markdownShowsWordCount: true, markdownHighlightsCode: true, markdownStrikesDone: true,
  markdownChecksSpelling: false, markdownSlashMenu: true, markdownContinuesLists: true, markdownCompletesSymbols: true, markdownPastesLinks: true, markdownToolbar: true,
};
export type MdKey = keyof typeof MD;
export const mdOf = <K extends MdKey>(settings: Record<string, any>, key: K): (typeof MD)[K] => settings[key] ?? MD[key];
export const md = <K extends MdKey>(key: K) => mdOf(getState().settings, key);

const FONTS: Record<string, string> = {
  system: "var(--font)", serif: 'Georgia, Cambria, "Source Han Serif SC", "Noto Serif SC", SimSun, "Songti SC", serif',
  rounded: '"Segoe UI Rounded", "SF Pro Rounded", ui-rounded, "Microsoft YaHei UI", "PingFang SC", var(--font)', mono: '"Cascadia Code", Consolas, "Microsoft YaHei UI", monospace',
};

/** What style sheets need to know. */
export function applyMarkdown(settings: Record<string, any>) {
  const root = document.documentElement, get = <K extends MdKey>(key: K) => mdOf(settings, key);
  const set = (name: string, value: string) => root.style.setProperty(name, value);
  set("--md-size", `${get("markdownFontSize")}px`);
  set("--md-panel-size", `${get("markdownPanelFontSize")}px`);
  set("--md-font", FONTS[get("markdownTypeface")] ?? FONTS.system);
  set("--md-line", String(get("markdownLineHeight")));
  set("--md-gap", `${get("markdownParagraphSpacing")}`);
  set("--md-heading", String(get("markdownHeadingScale")));
  set("--md-code", String(get("markdownCodeScale")));
  set("--md-zoom", String(get("markdownZoom")));
  set("--md-panel-zoom", String(get("markdownPanelZoom")));
  const width = get("markdownReadableWidth");
  set("--md-width", width > 0 ? `${width}px` : "100%");
  root.classList.toggle("md-no-placeholders", !get("markdownShowsPlaceholders"));
  root.classList.toggle("md-no-strike", !get("markdownStrikesDone"));
}

export const sizeRange = (panel: boolean): [number, number] => (panel ? [10, 24] : [10, 32]);

let timer = 0;
const changed = new Map<string, unknown>();
/** Seen at once, kept a moment later (a pinch goes through many sizes). */
export function setMd(key: MdKey, value: unknown) {
  setState({ settings: { ...getState().settings, [key]: value } });
  applyMarkdown(getState().settings);
  changed.set(key, value);
  clearTimeout(timer);
  timer = window.setTimeout(() => { changed.forEach((v, k) => call("settings.set", { key: k, value: v })); changed.clear(); }, 180);
}

export const sizeKey = (panel: boolean): MdKey => (panel ? "markdownPanelFontSize" : "markdownFontSize");
export function setTextSize(size: number, panel: boolean) {
  const [min, max] = sizeRange(panel);
  setMd(sizeKey(panel), Math.min(max, Math.max(min, Math.round(size * 2) / 2)));
}
export const textSize = (panel: boolean) => md(sizeKey(panel)) as number;

// MARK: Zoom: the page as a whole (text, spacing, tables, pictures and the column they stand in)

export const ZOOMS: [number, number] = [0.5, 3];
const STEPS = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];
export const zoomKey = (panel: boolean): MdKey => (panel ? "markdownPanelZoom" : "markdownZoom");
export const zoomOf = (panel: boolean) => md(zoomKey(panel)) as number;

/** How much larger than itself an element is shown (in a zoomed page, what is measured on the screen is that much more). */
export const scaleOf = (el: HTMLElement) => el.offsetWidth ? el.getBoundingClientRect().width / el.offsetWidth || 1 : 1;

let label: HTMLElement | null = null, labelTimer = 0;
function showZoom(zoom: number, over: HTMLElement) {
  label ??= document.body.appendChild(Object.assign(document.createElement("div"), { className: "md-zoom-label" }));
  const r = over.getBoundingClientRect();
  label.textContent = `${Math.round(zoom * 100)}%`;
  label.style.left = `${r.left + r.width / 2}px`;
  label.style.top = `${r.top + 12}px`;
  label.classList.add("on");
  clearTimeout(labelTimer);
  labelTimer = window.setTimeout(() => label!.classList.remove("on"), 900);
}

/** Zooms what `view` is in; what is at (x, y) on the screen stays there (else what is at the top). */
export function setZoom(view: EditorView, zoom: number, panel: boolean, at?: { x: number; y: number }) {
  zoom = Math.min(ZOOMS[1], Math.max(ZOOMS[0], Math.round(zoom * 100) / 100));
  const scroller = view.dom.closest<HTMLElement>(".md-tab-body") ?? view.scrollDOM;
  const box = scroller.getBoundingClientRect(), content = view.contentDOM.getBoundingClientRect();
  const x = Math.min(Math.max(at?.x ?? content.left + 8, content.left + 2), content.right - 2), y = Math.min(Math.max(at?.y ?? box.top + 80, content.top + 1), content.bottom - 1);
  const pos = view.posAtCoords({ x, y }, false), before = view.coordsAtPos(pos)?.top;
  if (zoom !== zoomOf(panel)) setMd(zoomKey(panel), zoom);
  view.requestMeasure();
  showZoom(zoom, scroller);
  const follow = () => {
    const after = view.coordsAtPos(pos)?.top;
    if (before != null && after != null && Math.abs(after - before) > 0.5) scroller.scrollTop += (after - before) / (scroller === view.scrollDOM ? scaleOf(scroller) : 1);
  };
  (view as any).measure?.();
  follow();
  requestAnimationFrame(follow);
}

export function stepZoom(view: EditorView, by: 1 | -1 | 0, panel: boolean) {
  const now = zoomOf(panel);
  setZoom(view, by === 0 ? 1 : by > 0 ? STEPS.find((s) => s > now + 0.005) ?? ZOOMS[1] : [...STEPS].reverse().find((s) => s < now - 0.005) ?? ZOOMS[0], panel);
}

/** A touchpad pinch (Ctrl + a fine-grained wheel, where a scale of s is a delta of 100·ln(s)) or Ctrl + the mouse wheel. */
export function wheelZoom(view: () => EditorView | null, panel: boolean) {
  let pinched = 0, last = 0;
  return (e: WheelEvent) => {
    if (!e.ctrlKey) return;
    e.preventDefault();
    const v = view();
    if (!v) return;
    const at = { x: e.clientX, y: e.clientY };
    if (e.deltaMode !== 0 || Math.abs(e.deltaY) >= 50) {
      const now = zoomOf(panel);
      setZoom(v, e.deltaY < 0 ? STEPS.find((s) => s > now + 0.005) ?? ZOOMS[1] : [...STEPS].reverse().find((s) => s < now - 0.005) ?? ZOOMS[0], panel, at);
      return;
    }
    if (e.timeStamp - last > 400) pinched = zoomOf(panel);
    last = e.timeStamp;
    pinched = Math.min(ZOOMS[1], Math.max(ZOOMS[0], pinched * Math.exp(-e.deltaY / 100)));
    // Actual size holds a little, so it can be found again.
    setZoom(v, Math.abs(pinched - 1) < 0.025 ? 1 : pinched, panel, at);
  };
}
