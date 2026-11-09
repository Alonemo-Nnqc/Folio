import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { ArrowLeftRight, Check, ChevronDown, Copy, Languages, NotebookPen, RotateCw, TriangleAlert } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { openMenuAt, sep, type MenuEntry } from "../ui/menu";
import { ServiceLogo } from "../ui/serviceLogo";

export interface Anchor { left: number; top: number; right: number; bottom: number }

/** The round button beside a selection (划词翻译). */
export function TranslateBadge({ x, y, onClick }: { x: number; y: number; onClick: () => void }) {
  const left = Math.min(Math.max(8, x + 6), innerWidth - 40), top = Math.min(Math.max(8, y), innerHeight - 40);
  return (
    <button className="translate-badge" style={{ left, top }} title={t("翻译所选文字")} aria-label={t("翻译所选文字")}
      onMouseDown={(e) => e.preventDefault()} onClick={onClick}>
      <Languages size={14} strokeWidth={2.1} />
    </button>
  );
}

const cache = new Map<string, string>();

type Phase = { kind: "translating" } | { kind: "done"; text: string } | { kind: "failed"; message: string };

/** The popover: the passage, its translation, and what to do with it. */
export function TranslatePopover({ anchor, text, close, addToNote }: { anchor: Anchor; text: string; close: () => void; addToNote: (source: string, translation: string) => void }) {
  const [info, setInfo] = useState<{ current: string; fullText: string; services: { id: string; name: string }[]; from: string; to: string } | null>(null);
  const [service, setService] = useState<string | null>(null);
  const [usedName, setUsedName] = useState("");
  const [notice, setNotice] = useState<string | null>(null);
  const [phase, setPhase] = useState<Phase>({ kind: "translating" });
  const [copied, setCopied] = useState(false);
  const [noted, setNoted] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const [place, setPlace] = useState<{ left: number; top: number; above: boolean } | null>(null);
  const ref = useRef<HTMLDivElement>(null);
  const run = useRef(0);
  const source = text.replace(/\s*\n\s*/g, " ").trim();

  const translate = async (id: string | null, fresh = false) => {
    const ticket = ++run.current;
    const key = `${id ?? ""}|${source}`;
    if (!fresh && cache.has(key)) { setPhase({ kind: "done", text: cache.get(key)! }); return; }
    setPhase({ kind: "translating" });
    setCopied(false); setNoted(false);
    try {
      setNotice(null);
      const r = await call<{ ok: boolean; text: string; service: string; serviceName: string; notice?: string }>("translation.selection", { text, service: id ?? undefined });
      if (ticket !== run.current) return;
      setUsedName(r.serviceName);
      setNotice(r.notice ?? null);
      if (r.ok) { cache.set(`${r.service}|${source}`, r.text); cache.set(key, r.text); setPhase({ kind: "done", text: r.text }); }
      else setPhase({ kind: "failed", message: r.text });
      if (!id) setService(r.service);
    } catch (e: any) {
      if (ticket === run.current) setPhase({ kind: "failed", message: e.message });
    }
  };

  useEffect(() => {
    call("translation.selectionServices").then((i) => { setInfo(i); setService((s) => s ?? i.current); }).catch(() => {});
    translate(null);
  }, [text]);

  useEffect(() => {
    const away = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node) && !(e.target as Element).closest?.(".menu")) close(); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(); } };
    window.addEventListener("mousedown", away, true);
    window.addEventListener("keydown", key, true);
    return () => { window.removeEventListener("mousedown", away, true); window.removeEventListener("keydown", key, true); };
  }, []);

  // Below the selection when there is room, else above it; always inside the window.
  useLayoutEffect(() => {
    const box = ref.current?.getBoundingClientRect();
    if (!box) return;
    const width = box.width, height = box.height;
    const below = anchor.bottom + 10, aboveTop = anchor.top - 10 - height;
    const above = below + height > innerHeight - 8 && aboveTop > 8;
    const center = (anchor.left + anchor.right) / 2;
    setPlace({ left: Math.min(Math.max(8, center - width / 2), innerWidth - width - 8), top: above ? aboveTop : Math.min(below, innerHeight - height - 8), above });
  }, [anchor.left, anchor.top, anchor.bottom, phase.kind, expanded, info !== null]);

  const choose = (id: string) => {
    setService(id);
    call("translation.setSelectionService", { id });
    translate(id);
  };

  const serviceMenu = (el: HTMLElement) => {
    if (!info) return;
    const entries: MenuEntry[] = info.services.map((s) => ({ label: s.name, icon: <ServiceLogo id={s.id} />, checked: s.id === service, action: () => choose(s.id) }));
    entries.push(sep, { label: t("划词翻译设置…"), action: () => { close(); call("window.settings", { page: "selection" }); } });
    openMenuAt(el, entries);
  };

  const result = phase.kind === "done" ? phase.text : null;
  const serviceName = info?.services.find((s) => s.id === service)?.name ?? usedName;

  return (
    <div ref={ref} className={`translate-pop${place?.above ? " above" : ""}`} style={place ? { left: place.left, top: place.top } : { left: -9999, top: 0 }} role="dialog" aria-label={t("翻译")}>
      <div className="tp-head">
        <span className="tp-langs">{info ? `${info.from} → ${info.to}` : ""}</span>
        <button className="tp-service" title={t("选择翻译服务")} onClick={(e) => serviceMenu(e.currentTarget)}>{service && <ServiceLogo id={service} size={13} />}{serviceName}<ChevronDown size={11} strokeWidth={2.2} /></button>
      </div>
      <div className={`tp-source selectable${expanded ? " expanded" : ""}`} onDoubleClick={() => setExpanded((v) => !v)}>{source}</div>
      <div className="tp-divider" />
      {notice && <div className="tp-notice"><ArrowLeftRight size={12} />{notice}</div>}
      <div className="tp-result">
        {phase.kind === "translating" && <div className="tp-shimmer" aria-label={t("正在翻译")}><i style={{ width: "100%" }} /><i style={{ width: "92%" }} /><i style={{ width: "60%" }} /></div>}
        {phase.kind === "done" && <div className="tp-text selectable">{phase.text}</div>}
        {phase.kind === "failed" && <div className="tp-error"><TriangleAlert size={14} /><span className="selectable">{phase.message}</span></div>}
      </div>
      <div className="tp-foot">
        <button className="tp-icon" title={t("拷贝译文")} disabled={!result} onClick={() => { if (result) { call("shell.copy", { text: result }); setCopied(true); } }}>{copied ? <Check size={15} /> : <Copy size={14} />}</button>
        <button className="tp-icon" title={t("添加到笔记")} disabled={!result} onClick={() => { if (result) { addToNote(source, result); setNoted(true); } }}>{noted ? <Check size={15} /> : <NotebookPen size={14} />}</button>
        <span style={{ flex: 1 }} />
        {phase.kind === "failed" && <button className="btn small" onClick={() => { close(); call("window.settings", { page: "selection" }); }}>{t("设置…")}</button>}
        <button className="tp-icon" title={t("重新翻译")} disabled={phase.kind === "translating"} onClick={() => translate(service, true)}><RotateCw size={14} /></button>
      </div>
    </div>
  );
}
