import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { Search, X } from "lucide-react";

export function Segmented<T extends string | number>({ options, value, onChange, accent, className }: { options: { value: T; label: ReactNode; title?: string }[]; value: T; onChange: (v: T) => void; accent?: boolean; className?: string }) {
  return (
    <div className={`segmented${accent ? " accent" : ""} ${className ?? ""}`}>
      {options.map((o) => (
        <button key={String(o.value)} title={o.title} className={o.value === value ? "on" : ""} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

export function Switch({ on, onChange, disabled, title }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; title?: string }) {
  return <button role="switch" aria-checked={on} title={title} disabled={disabled} className={`switch${on ? " on" : ""}`} onClick={() => onChange(!on)} />;
}

export function Select<T extends string | number>({ value, options, onChange, title }: { value: T; options: { value: T; label: string; disabled?: boolean }[]; onChange: (v: T) => void; title?: string }) {
  return (
    <select className="select" title={title} value={String(value)} onChange={(e) => {
      const hit = options.find((o) => String(o.value) === e.target.value);
      if (hit) onChange(hit.value);
    }}>
      {options.map((o) => <option key={String(o.value)} value={String(o.value)} disabled={o.disabled}>{o.label}</option>)}
    </select>
  );
}

/** A text field that commits when it loses focus or on Enter. */
export function Field({ value, onCommit, placeholder, secret, className, autoFocus }: { value: string; onCommit: (v: string) => void; placeholder?: string; secret?: boolean; className?: string; autoFocus?: boolean }) {
  const [text, setText] = useState(value);
  useEffect(() => setText(value), [value]);
  const commit = () => { if (text !== value) onCommit(text); };
  return <input className={`field ${className ?? ""}`} type={secret ? "password" : "text"} value={text} placeholder={placeholder} autoFocus={autoFocus} spellCheck={false}
    onChange={(e) => setText(e.target.value)} onBlur={commit} onKeyDown={(e) => { if (e.key === "Enter") commit(); e.stopPropagation(); }} />;
}

/** Looks like a label until focused: the macOS inspector's fields. */
export function PlainEdit({ value, onCommit, className, placeholder, multiline, title }: { value: string; onCommit: (v: string) => void; className?: string; placeholder?: string; multiline?: boolean; title?: string }) {
  const [text, setText] = useState(value);
  const ref = useRef<HTMLTextAreaElement>(null);
  const initial = useRef(value);
  useEffect(() => {
    if (document.activeElement !== ref.current) { setText(value); initial.current = value; }
  }, [value]);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "0";
    el.style.height = `${el.scrollHeight}px`;
  });
  const commit = () => {
    const clean = text.replace(/\r\n/g, "\n").trim();
    if (clean !== initial.current.trim()) { initial.current = clean; onCommit(clean); }
  };
  return (
    <textarea ref={ref} rows={1} title={title} className={`plain-edit ${className ?? ""}`} value={text} placeholder={placeholder} spellCheck={false}
      onChange={(e) => setText(multiline ? e.target.value : e.target.value.replace(/\n/g, ""))} onBlur={commit}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter" && !multiline) { e.preventDefault(); e.currentTarget.blur(); }
        if (e.key === "Escape") { setText(initial.current); requestAnimationFrame(() => ref.current?.blur()); }
      }} />
  );
}

export function SearchBox({ value, onChange, placeholder, inputRef, onKeyDown, trailing }: { value: string; onChange: (v: string) => void; placeholder: string; inputRef?: React.Ref<HTMLInputElement>; onKeyDown?: (e: React.KeyboardEvent<HTMLInputElement>) => void; trailing?: ReactNode }) {
  return (
    <label className="search-field">
      <Search size={15} />
      <input ref={inputRef} value={value} placeholder={placeholder} spellCheck={false} onChange={(e) => onChange(e.target.value)} onKeyDown={(e) => {
        onKeyDown?.(e);
        if (e.key === "Escape" && value) { onChange(""); e.preventDefault(); e.stopPropagation(); }
      }} />
      {trailing}
      {value && <button className="clear-button" tabIndex={-1} onClick={(e) => { e.preventDefault(); onChange(""); }}><X size={10} strokeWidth={3} /></button>}
    </label>
  );
}

function tint(hex: string, dark: boolean) {
  return { color: dark ? `color-mix(in srgb, ${hex} 75%, white)` : `color-mix(in srgb, ${hex} 78%, black)`, background: `color-mix(in srgb, ${hex} ${dark ? 24 : 14}%, transparent)`, borderColor: `color-mix(in srgb, ${hex} 32%, transparent)` };
}

export function Chip({ label, color, dark, onRemove, title }: { label: string; color: string; dark: boolean; onRemove?: () => void; title?: string }) {
  return (
    <span className="chip" style={tint(color, dark)} title={title ?? label}>
      <span className="ellipsis">{label}</span>
      {onRemove && <button className="x" title="" onClick={(e) => { e.stopPropagation(); onRemove(); }}><X size={9} strokeWidth={3} /></button>}
    </span>
  );
}

/** A range slider that saves when released and shows the value while dragged. */
export function Slider({ value, onChange, onCommit, min = 0, max = 1, step = 0.01, label }: { value: number; onChange?: (v: number) => void; onCommit: (v: number) => void; min?: number; max?: number; step?: number; label?: string }) {
  const fraction = (value - min) / (max - min);
  return (
    <input type="range" className="slider" aria-label={label} min={min} max={max} step={step} value={value}
      style={{ ["--fill" as any]: `${fraction * 100}%` }}
      onChange={(e) => onChange?.(Number(e.target.value))}
      onPointerUp={(e) => onCommit(Number((e.target as HTMLInputElement).value))}
      onKeyUp={(e) => onCommit(Number((e.target as HTMLInputElement).value))} />
  );
}
