import { useEffect, useRef, useState, type ReactNode } from "react";
import { emitLocal, handleRequest, on } from "../rpc";
import { t } from "../i18n";

/** Opens a sheet; its component gets `close(result)`. */
export function openSheet<T = void>(render: (close: (result?: T) => void) => ReactNode): Promise<T | undefined> {
  return new Promise((resolve) => emitLocal("sheet.open", { render, resolve }));
}

export function SheetHost() {
  const [stack, setStack] = useState<{ id: number; render: (close: (r?: any) => void) => ReactNode; resolve: (r: any) => void }[]>([]);
  const counter = useRef(0);
  useEffect(() => on("sheet.open", (s) => setStack((v) => [...v, { ...s, id: ++counter.current }])), []);
  return (
    <>
      {stack.map((s) => (
        <div key={s.id} className="scrim" onMouseDown={(e) => e.stopPropagation()} onContextMenu={(e) => e.preventDefault()}>
          {s.render((result) => { setStack((v) => v.filter((x) => x.id !== s.id)); s.resolve(result); })}
        </div>
      ))}
    </>
  );
}

export function Sheet({ title, width, children, actions, onEscape }: { title?: ReactNode; width?: number; children?: ReactNode; actions?: ReactNode; onEscape?: () => void }) {
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape" && onEscape) { e.preventDefault(); e.stopPropagation(); onEscape(); } };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onEscape]);
  return (
    <div className="sheet" style={width ? { width } : undefined} role="dialog">
      {title && <h2>{title}</h2>}
      {children}
      {actions && <div className="actions">{actions}</div>}
    </div>
  );
}

export type DialogAnswer = "primary" | "secondary" | "cancel";

export function dialog(o: { title: string; message?: string; primary?: string; secondary?: string; cancel?: string; destructive?: boolean }): Promise<DialogAnswer> {
  return openSheet<DialogAnswer>((close) => {
    const cancel = () => close("cancel");
    return (
      <Sheet title={o.title} width={440} onEscape={cancel} actions={
        <>
          {o.cancel && <button className="btn" onClick={cancel}>{o.cancel}</button>}
          {o.secondary && <button className="btn" onClick={() => close("secondary")}>{o.secondary}</button>}
          <button className={`btn ${o.destructive ? "danger" : "primary"}`} autoFocus onClick={() => close("primary")}>{o.primary ?? t("好")}</button>
        </>
      }>
        {o.message && <div className="message">{o.message}</div>}
      </Sheet>
    );
  }).then((r) => r ?? "cancel");
}

export async function confirm(title: string, message: string, primary: string, destructive = false): Promise<boolean> {
  return (await dialog({ title, message, primary, cancel: t("取消"), destructive })) === "primary";
}

function AskBody({ title, placeholder, initial, primary, close }: { title: string; placeholder: string; initial: string; primary: string; close: (v?: string) => void }) {
  const [text, setText] = useState(initial);
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => { ref.current?.focus(); ref.current?.select(); }, []);
  return (
    <Sheet title={title} width={400} onEscape={() => close()} actions={
      <>
        <button className="btn" onClick={() => close()}>{t("取消")}</button>
        <button className="btn primary" disabled={!text.trim()} onClick={() => close(text)}>{primary}</button>
      </>
    }>
      <input ref={ref} className="field" style={{ marginTop: 6 }} spellCheck={false} value={text} placeholder={placeholder} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => { e.stopPropagation(); if (e.key === "Enter" && text.trim()) close(text); }} />
    </Sheet>
  );
}

export function askText(title: string, placeholder: string, initial = "", primary = t("好")): Promise<string | undefined> {
  return openSheet<string>((close) => <AskBody title={title} placeholder={placeholder} initial={initial} primary={primary} close={close} />);
}

// The app's own questions (updates, imports, failures).
handleRequest("dialog", async (p) => dialog({ title: p.title, message: p.message, primary: p.primary, secondary: p.secondary, cancel: p.cancel || undefined, destructive: p.destructive }));
