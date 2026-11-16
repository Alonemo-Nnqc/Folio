import { useLayoutEffect, useRef, useState } from "react";
import { Trash2 } from "lucide-react";
import { t } from "../i18n";
import { useLayer, within } from "../ui/dismiss";

export interface CardColor { key: string; title: string; hex: string }
export interface Anchor { left: number; top: number; right: number; bottom: number }

/** The sizes the text box's bar steps through, in points. */
export const TEXT_BOX_SIZES = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 40, 48];

/** A row of colour dots and 自定义颜色… (the note's card, the text box's bar). */
function Swatches({ palette, current, onPick, onMix }: { palette: CardColor[]; current?: string | null; onPick: (key: string) => void; onMix: () => void }) {
  return (
    <>
      {palette.map((c) => (
        <button key={c.key} className={`swatch-dot${c.key === current ? " on" : ""}`} title={c.title} aria-label={c.title} aria-pressed={c.key === current}
          style={{ background: c.hex }} onMouseDown={(e) => e.preventDefault()} onClick={() => onPick(c.key)} />
      ))}
      <button className="swatch-dot custom" title={t("自定义颜色…")} aria-label={t("自定义颜色…")} onMouseDown={(e) => e.preventDefault()} onClick={onMix} />
    </>
  );
}

/** A sticky note's or a highlight's comment (as on the Mac): a quiet card in the note's colour beside it, with nothing on
 *  it but the words. What is typed is kept; Esc, Ctrl+Enter or a click elsewhere close it. Its colours, when it was
 *  written and deleting it sit in one low line under the text. */
export function NoteCard({ anchor, text, quote, author, date, colorKey, palette, onColor, onMix, onText, onDelete, done, close }: {
  anchor: Anchor; text: string; quote?: string; author?: string; date?: string; colorKey?: string | null; palette: CardColor[];
  onColor: (key: string) => void; onMix: (apply: (key: string) => void) => void; onText?: (text: string) => void; onDelete: () => void;
  done: (text: string) => void; close: () => void;
}) {
  const [value, setValue] = useState(text);
  const [color, setColor] = useState(colorKey ?? palette[0]?.key);
  const ref = useRef<HTMLDivElement>(null);
  const latest = useRef(value);
  latest.current = value;
  const finished = useRef(false);
  const finish = () => {
    if (finished.current) return;
    finished.current = true;
    done(latest.current.replace(/\r\n/g, "\n").replace(/\s+$/, ""));
    close();
  };
  useLayer(true, { contains: (target) => within(ref.current, target), onPress: finish, onEscape: finish, onDeactivate: finish });
  const hex = palette.find((c) => c.key === color)?.hex ?? (color?.startsWith("#") ? color : "#FFD933");
  // Its size is the one the last card was left at (dragged from its corner).
  const [size, setSize] = useState<{ width: number; height: number }>(() => {
    try { const v = JSON.parse(localStorage.getItem("folio.noteCardSize") ?? ""); if (v?.width > 0) return v; } catch {}
    return { width: 290, height: 168 };
  });
  const width = size.width, height = size.height + (quote ? 40 : 0);
  // Beside the note: to its right, or its left where there is no room; level with its top. Where it goes is fixed
  // when it opens, from the note: as the page scrolls or zooms, it moves with the note.
  const place = useRef<{ dx: number; dy: number } | null>(null);
  if (!place.current) {
    const left = anchor.right + 12 + width < innerWidth - 8 ? anchor.right + 12 : Math.max(8, anchor.left - 12 - width);
    const top = Math.max(8, Math.min(anchor.top - 10, innerHeight - height - 8));
    place.current = { dx: left - anchor.right, dy: top - anchor.top };
  }
  const left = anchor.right + place.current.dx, top = anchor.top + place.current.dy;
  const pick = (key: string) => { setColor(key); onColor(key); };
  const resize = (e: React.PointerEvent) => {
    e.preventDefault();
    const start = { x: e.clientX, y: e.clientY, ...size };
    const target = e.currentTarget as HTMLElement;
    target.setPointerCapture(e.pointerId);
    let latestSize = size;
    const move = (m: PointerEvent) => {
      latestSize = { width: Math.min(640, Math.max(230, start.width + m.clientX - start.x)), height: Math.min(640, Math.max(120, start.height + m.clientY - start.y)) };
      setSize(latestSize);
    };
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
      try { localStorage.setItem("folio.noteCardSize", JSON.stringify(latestSize)); } catch {}
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
  };
  return (
    <div ref={ref} className="note-card-pop" style={{ left, top, width, height, ["--note" as any]: hex }} role="dialog" aria-label={t("便签")}>
      {quote && <div className="note-card-quote">{quote}</div>}
      <textarea className="note-card-text" autoFocus value={value} spellCheck={false}
        placeholder={quote === undefined ? t("写点什么…") : t("添加评论…")}
        onChange={(e) => { setValue(e.target.value); onText?.(e.target.value); }}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Escape" || (e.key === "Enter" && e.ctrlKey)) { e.preventDefault(); finish(); }
        }} />
      <div className="note-card-foot">
        <Swatches palette={palette} current={color} onPick={pick} onMix={() => onMix(pick)} />
        <span style={{ flex: 1 }} />
        {date && <span className="note-card-date" title={author}>{date}</span>}
        <button className="note-card-delete" title={t("删除批注")} aria-label={t("删除批注")} onClick={() => { finished.current = true; close(); onDelete(); }}><Trash2 size={13} /></button>
      </div>
      <span className="note-card-grip" onPointerDown={resize} aria-hidden="true" />
    </div>
  );
}

/** A text box written in place (as on the Mac): a transparent field over the box with a thin accent line, in its
 *  text's colour and size at the page's zoom, widening as it is typed; a small bar above it changes the colour and the
 *  size. Ends with Esc, Ctrl+Enter or a click elsewhere: `done` gets the text, its size on screen (CSS pixels) and the
 *  style it ended with. */
export function TextBoxField({ left: startLeft, top: startTop, width, scale, size, colorKey, palette, text, onStyle, onMix, done, close }: {
  left: number; top: number; width?: number; scale: number; size: number; colorKey: string; palette: CardColor[]; text: string;
  onStyle?: (style: { colorKey?: string; size?: number }) => void; onMix: (apply: (key: string) => void) => void;
  done: (text: string, box: { width: number; height: number }, style: { colorKey: string; size: number; changed: boolean; moved: { dx: number; dy: number }; scale: number }) => void; close: () => void;
}) {
  // Dragged by its edge (empty or not), the box moves: `moved` is how far, in page points (right and down), so it stays
  // where it was put as the page zooms.
  const [moved, setMoved] = useState({ dx: 0, dy: 0 });
  const left = startLeft + moved.dx * scale, top = startTop + moved.dy * scale;
  const [value, setValue] = useState(text);
  const [style, setStyle] = useState({ colorKey, size });
  const ref = useRef<HTMLTextAreaElement>(null);
  const bar = useRef<HTMLDivElement>(null);
  const measure = useRef<HTMLDivElement>(null);
  const finished = useRef(false);
  const latest = useRef({ value, style, changed: false, moved, scale });
  latest.current = { ...latest.current, value, style, moved, scale };
  const finish = () => {
    if (finished.current) return;
    finished.current = true;
    const box = measure.current?.getBoundingClientRect();
    const { value: v, style: s, changed, moved: m, scale: k } = latest.current;
    done(v.replace(/\r\n/g, "\n").replace(/\s+$/, ""), { width: box?.width ?? 0, height: box?.height ?? 0 }, { ...s, changed, moved: m, scale: k });
    close();
  };
  const frame = useRef<HTMLDivElement>(null);
  useLayer(true, { contains: (target) => within(ref.current, target) || within(bar.current, target) || within(frame.current, target), onPress: finish, onEscape: finish, onDeactivate: finish });
  const drag = (e: React.PointerEvent) => {
    e.preventDefault();
    const target = e.currentTarget as HTMLElement;
    target.setPointerCapture(e.pointerId);
    const start = { x: e.clientX, y: e.clientY, ...latest.current.moved };
    target.classList.add("dragging");
    const move = (m: PointerEvent) => setMoved({ dx: start.dx + (m.clientX - start.x) / scale, dy: start.dy + (m.clientY - start.y) / scale });
    const up = () => {
      target.classList.remove("dragging");
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
      requestAnimationFrame(() => ref.current?.focus());
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
  };
  const fontSize = style.size * scale;
  const maxWidth = width ?? 280 * scale;
  const hex = palette.find((c) => c.key === style.colorKey)?.hex ?? (style.colorKey.startsWith("#") ? style.colorKey : "#1C1C1F");
  useLayoutEffect(() => {
    const field = ref.current, sizer = measure.current;
    if (!field || !sizer) return;
    field.style.width = `${width ?? Math.min(maxWidth, Math.max(sizer.offsetWidth + 3, fontSize * 1.5))}px`;
    field.style.height = `${sizer.offsetHeight}px`;
    // The handle around it, 6 px wider on every side.
    if (frame.current) { frame.current.style.width = `${field.offsetWidth + 12}px`; frame.current.style.height = `${field.offsetHeight + 12}px`; }
  }, [value, fontSize, maxWidth, width]);
  useLayoutEffect(() => { const f = ref.current; if (f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); } }, []);
  const change = (next: { colorKey?: string; size?: number }) => {
    latest.current.changed = true;
    setStyle((s) => ({ ...s, ...next }));
    onStyle?.(next);
    requestAnimationFrame(() => ref.current?.focus());
  };
  const step = (direction: number) => {
    const next = direction > 0 ? TEXT_BOX_SIZES.find((x) => x > style.size) : [...TEXT_BOX_SIZES].reverse().find((x) => x < style.size);
    if (next) change({ size: next });
  };
  const font = { fontSize, lineHeight: 1.22, color: hex };
  const pad = 2 * scale;
  const barTop = top - 44 > 8 ? top - 44 : top + (measure.current?.offsetHeight ?? fontSize * 1.3) + 2 * pad + 12;
  return (
    <>
      <div ref={measure} className="text-box-measure" style={{ ...font, maxWidth, width: width ? maxWidth : undefined }} aria-hidden="true">{value || " "}{value.endsWith("\n") ? " " : ""}</div>
      <div ref={bar} className="text-box-bar" style={{ left: Math.max(8, left), top: barTop }} onMouseDown={(e) => { if (!(e.target as Element).closest("button")) e.preventDefault(); }}>
        <Swatches palette={palette} current={style.colorKey} onPick={(key) => change({ colorKey: key })} onMix={() => onMix((key) => change({ colorKey: key }))} />
        <span className="text-box-bar-sep" />
        <span className="text-box-size" role="group" aria-label={t("字号")}>
          <button className="text-box-size-step" title={t("缩小字号")} aria-label={t("缩小字号")} disabled={style.size <= TEXT_BOX_SIZES[0]} onMouseDown={(e) => e.preventDefault()} onClick={() => step(-1)}><span style={{ fontSize: 10 }}>A</span></button>
          <select className="text-box-size-value tabular" value={style.size} title={t("字号")} aria-label={t("字号")}
            onChange={(e) => change({ size: Number(e.target.value) })}>
            {TEXT_BOX_SIZES.map((x) => <option key={x} value={x}>{x}</option>)}
          </select>
          <button className="text-box-size-step" title={t("放大字号")} aria-label={t("放大字号")} disabled={style.size >= TEXT_BOX_SIZES[TEXT_BOX_SIZES.length - 1]} onMouseDown={(e) => e.preventDefault()} onClick={() => step(1)}><span style={{ fontSize: 15 }}>A</span></button>
        </span>
      </div>
      <div ref={frame} className="text-box-frame" title={t("拖动以移动文本框")} onPointerDown={drag}
        style={{ left: left - pad - 6, top: top - pad - 6 }} />
      <textarea ref={ref} className="text-box-field" style={{ ...font, left: left - pad, top: top - pad, padding: pad, caretColor: hex }} value={value} spellCheck={false}
        aria-label={t("文本框")}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => {
          e.stopPropagation();
          if (e.key === "Escape" || (e.key === "Enter" && e.ctrlKey)) { e.preventDefault(); finish(); }
        }} />
    </>
  );
}

/** Opens the system's colour picker and calls `onPick` with what is chosen ("#RRGGBB"). */
export function pickColor(initial: string, onPick: (hex: string) => void) {
  const input = document.createElement("input");
  input.type = "color";
  input.value = /^#[0-9a-f]{6}$/i.test(initial) ? initial : "#FFD933";
  input.style.cssText = "position:fixed;left:-100px;top:-100px;opacity:0";
  document.body.appendChild(input);
  input.addEventListener("change", () => { onPick(input.value.toUpperCase()); input.remove(); });
  input.addEventListener("blur", () => setTimeout(() => input.remove(), 1000));
  input.click();
}
