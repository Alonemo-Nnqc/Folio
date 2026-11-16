import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { Check, ChevronRight } from "lucide-react";
import { emitLocal, on } from "../rpc";
import { useLayer } from "./dismiss";

export type MenuEntry =
  | { kind?: "item"; label: string; icon?: ReactNode; action?: () => void; disabled?: boolean; checked?: boolean; submenu?: MenuEntry[]; key?: string; dot?: string; indent?: number }
  | { kind: "separator" }
  | { kind: "title"; label: string }
  | { kind: "row"; label: string; choices: RowChoice[] };

/** One choice in a row of a menu (as the Mac shows them): a colour circle, the many-coloured circle that mixes a colour
 *  of one's own, a dot as thick as a pen's line, a ring as large as the eraser, or a letter as large as a text size. */
export interface RowChoice {
  title: string;
  look: { color: string } | { custom: true } | { dot: number; color: string } | { ring: number } | { letter: number };
  selected?: boolean;
  action: () => void;
}

export const sep: MenuEntry = { kind: "separator" };

/** Opens a menu at a point of the window. */
export function openMenu(items: MenuEntry[], x: number, y: number) {
  anchor = null;
  emitLocal("menu.open", { items: tidy(items), x, y });
}

/** Under a button: a second click on that button closes the menu. */
export function openMenuAt(element: Element, items: MenuEntry[]) {
  if (anchor === element) { emitLocal("menu.close", null); return; }
  const r = element.getBoundingClientRect();
  openMenu(items, r.left, r.bottom + 4);
  anchor = element;
}

let anchor: Element | null = null;

/** No separator first, last or twice. */
function tidy(items: MenuEntry[]): MenuEntry[] {
  const out: MenuEntry[] = [];
  for (const i of items) {
    if (i.kind === "separator" && (out.length === 0 || out[out.length - 1].kind === "separator")) continue;
    out.push(i);
  }
  while (out.length && out[out.length - 1].kind === "separator") out.pop();
  return out;
}

function Panel({ items, x, y, parentWidth, close, depth }: { items: MenuEntry[]; x: number; y: number; parentWidth?: number; close: () => void; depth: number }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);
  const [open, setOpen] = useState<{ index: number; x: number; y: number; width: number } | null>(null);
  const [active, setActive] = useState(-1);
  const timer = useRef(0);

  useLayoutEffect(() => {
    const el = ref.current!;
    const w = el.offsetWidth, h = el.offsetHeight;
    let left = x, top = y;
    if (left + w > innerWidth - 6) left = parentWidth !== undefined ? x - parentWidth - w : innerWidth - w - 6;
    if (top + h > innerHeight - 6) top = Math.max(6, parentWidth !== undefined ? innerHeight - h - 6 : y - h > 6 ? y - h : innerHeight - h - 6);
    setPos({ left: Math.max(6, left), top });
  }, [x, y, items]);

  const enabled = items.map((i, n) => ({ i, n })).filter(({ i }) => i.kind !== "separator" && i.kind !== "title" && i.kind !== "row" && !("disabled" in i && i.disabled));

  // Only the deepest open panel takes the keys.
  useEffect(() => {
    if (open) return;
    const onKey = (e: KeyboardEvent) => {
      const position = enabled.findIndex((v) => v.n === active);
      if (e.key === "ArrowDown") setActive(enabled[(position + 1) % enabled.length]?.n ?? -1);
      else if (e.key === "ArrowUp") setActive(enabled[(position - 1 + enabled.length) % enabled.length]?.n ?? -1);
      else if (e.key === "Enter" && active >= 0) { const it = items[active] as any; if (it.submenu) openSub(active); else { close(); it.action?.(); } }
      else if (e.key === "ArrowRight" && active >= 0 && (items[active] as any).submenu) openSub(active);
      else if (e.key === "ArrowLeft" && depth > 0) { emitLocal(`menu.back.${depth}`, null); }
      else return;
      e.preventDefault();
      e.stopPropagation();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  });
  useEffect(() => on(`menu.back.${depth + 1}`, () => setOpen(null)), [depth]);

  function openSub(index: number) {
    const row = ref.current?.querySelector(`[data-index="${index}"]`);
    if (!row) return;
    const r = row.getBoundingClientRect();
    setOpen({ index, x: r.right - 2, y: r.top - 4, width: r.width });
  }

  const hasIcons = items.some((i) => i.kind !== "separator" && i.kind !== "title" && i.kind !== "row" && (i.icon || i.dot || i.checked !== undefined));
  return (
    <>
      <div ref={ref} className="menu" style={pos ? { left: pos.left, top: pos.top } : { left: x, top: y, visibility: "hidden" }} onContextMenu={(e) => e.preventDefault()}>
        {items.map((item, index) => {
          if (item.kind === "separator") return <div key={index} className="menu-sep" />;
          if (item.kind === "title") return <div key={index} className="menu-title">{item.label}</div>;
          if (item.kind === "row") return <MenuRow key={index} row={item} close={close} />;
          const hasSub = !!item.submenu;
          return (
            <div key={index} data-index={index} className={`menu-item${item.disabled ? " disabled" : ""}${active === index || open?.index === index ? " active" : ""}`}
              onMouseEnter={() => {
                setActive(index);
                clearTimeout(timer.current);
                timer.current = window.setTimeout(() => { if (hasSub && !item.disabled) openSub(index); else setOpen(null); }, hasSub ? 120 : 200);
              }}
              onMouseLeave={() => { if (!hasSub) setActive(-1); }}
              onMouseUp={() => {
                if (item.disabled) return;
                if (hasSub) { openSub(index); return; }
                close();
                item.action?.();
              }}>
              {hasIcons && <span className="mi-icon" style={item.indent ? { marginLeft: item.indent * 12 } : undefined}>
                {item.checked && !item.icon ? <Check size={14} /> : item.dot ? <span className="mi-dot" style={{ background: item.dot }} /> : item.icon}
              </span>}
              <span className="mi-label" style={!hasIcons && item.indent ? { paddingLeft: item.indent * 12 } : undefined}>{item.label}</span>
              {item.checked && item.dot && !item.icon && <span className="mi-dot" style={{ background: item.dot }} />}
              {item.checked && item.icon && <Check size={13} className="mi-trail" />}
              {item.key && <span className="mi-key">{item.key}</span>}
              {hasSub && <ChevronRight size={13} className="secondary" style={{ marginLeft: 12 }} />}
            </div>
          );
        })}
      </div>
      {open && (items[open.index] as any).submenu && <Panel items={tidy((items[open.index] as any).submenu)} x={open.x} y={open.y} parentWidth={open.width} close={close} depth={depth + 1} />}
    </>
  );
}

export function MenuHost() {
  const [menu, setMenu] = useState<{ items: MenuEntry[]; x: number; y: number; n: number } | null>(null);
  const counter = useRef(0);
  useEffect(() => on("menu.open", (m) => setMenu({ ...m, n: ++counter.current })), []);
  useEffect(() => on("menu.close", () => setMenu(null)), []);
  useEffect(() => { if (!menu) anchor = null; }, [menu]);
  // Closes on a press anywhere else (the reader's pages included), Esc, and when the window goes to the background or resizes.
  useLayer(!!menu, {
    // Its button closes it on the click that follows, in openMenuAt; closing here too would open it again.
    contains: (target) => target instanceof Node && (!!(target instanceof Element && target.closest(".menu")) || !!anchor?.contains(target)),
    onPress: () => setMenu(null),
    onEscape: () => setMenu(null),
    onDeactivate: () => setMenu(null),
  });
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    window.addEventListener("resize", close);
    return () => window.removeEventListener("resize", close);
  }, [menu]);
  if (!menu) return null;
  return <Panel key={menu.n} items={menu.items} x={menu.x} y={menu.y} close={() => setMenu(null)} depth={0} />;
}

function MenuRow({ row, close }: { row: { label: string; choices: RowChoice[] }; close: () => void }) {
  const colors = row.choices.every((c) => "color" in c.look && !("dot" in c.look) || "custom" in c.look);
  return (
    <div className={`menu-row${colors ? " colors" : " sizes"}`} role="group" aria-label={row.label} onMouseEnter={() => {}}>
      {row.choices.map((choice, i) => {
        const look = choice.look as any;
        return (
          <button key={i} className={`menu-choice${choice.selected ? " on" : ""}`} title={choice.title} aria-label={choice.title} aria-pressed={!!choice.selected}
            onMouseUp={() => { close(); choice.action(); }}>
            {"custom" in look ? <span className="swatch-dot custom" />
              : "dot" in look ? <span className="menu-size-dot" style={{ width: look.dot, height: look.dot, background: look.color }} />
              : "ring" in look ? <span className="menu-size-ring" style={{ width: look.ring, height: look.ring }} />
              : "letter" in look ? <span className="menu-size-letter" style={{ fontSize: look.letter }}>A</span>
              : <span className="swatch-dot" style={{ background: look.color }}>{choice.selected && <Check size={11} strokeWidth={3} color={light(look.color) ? "rgba(0,0,0,.7)" : "#fff"} />}</span>}
          </button>
        );
      })}
    </div>
  );
}

/** Whether a "#RRGGBB" colour is light (a dark checkmark on it). */
function light(hex: string) {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
  if (!m) return false;
  const [r, g, b] = m.slice(1).map((x) => parseInt(x, 16) / 255);
  return 0.299 * r + 0.587 * g + 0.114 * b > 0.8;
}
