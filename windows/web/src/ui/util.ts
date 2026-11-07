import { useEffect, useRef } from "react";

/** Drags a divider: reports how far the pointer moved since it was pressed. */
export function dragPointer(e: React.PointerEvent, move: (dx: number, dy: number) => void, done?: () => void) {
  e.preventDefault();
  e.stopPropagation();
  const startX = e.clientX, startY = e.clientY;
  const onMove = (m: PointerEvent) => move(m.clientX - startX, m.clientY - startY);
  const onUp = () => {
    window.removeEventListener("pointermove", onMove);
    window.removeEventListener("pointerup", onUp);
    document.body.style.cursor = "";
    document.querySelectorAll("iframe").forEach((f) => (f.style.pointerEvents = ""));
    done?.();
  };
  // Iframes would swallow the pointer on its way across them.
  document.querySelectorAll("iframe").forEach((f) => (f.style.pointerEvents = "none"));
  document.body.style.cursor = "col-resize";
  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", onUp);
}

export function useLatest<T>(value: T) {
  const ref = useRef(value);
  ref.current = value;
  return ref;
}

export function useEvent(target: EventTarget, type: string, handler: (e: any) => void, options?: AddEventListenerOptions) {
  const latest = useLatest(handler);
  useEffect(() => {
    const listener = (e: Event) => latest.current(e);
    target.addEventListener(type, listener, options);
    return () => target.removeEventListener(type, listener, options);
  }, [target, type]);
}

export function formatDate(ms: number) {
  const d = new Date(ms);
  return `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}`;
}

export function formatDateTime(ms: number) {
  const d = new Date(ms);
  return `${formatDate(ms)} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}
