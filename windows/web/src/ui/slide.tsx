import { useLayoutEffect, useRef, useState, type ReactNode } from "react";

/** A little longer than the transitions in styles.css (.2s), so they finish before the panel settles. */
const SETTLE_MS = 220;

export type PanelPhase = "closed" | "start" | "opening" | "open" | "closing";

/** A panel that shows and hides over time: it stays on the page while it goes, and starts from nothing when it comes. */
export function usePanelPhase(open: boolean): PanelPhase {
  const [phase, setPhase] = useState<PanelPhase>(open ? "open" : "closed");
  const first = useRef(true);
  useLayoutEffect(() => {
    if (first.current) { first.current = false; return; }
    // Coming back while still going needs no fresh start: the transition turns round by itself.
    if (open) setPhase((p) => (p === "closed" ? "start" : "opening"));
    else setPhase("closing");
    const settle = setTimeout(() => setPhase(open ? "open" : "closed"), SETTLE_MS);
    return () => clearTimeout(settle);
  }, [open]);
  // On the frame it appears, so it keeps time with whatever else moves: laid out once at nothing, it then transitions from there.
  useLayoutEffect(() => {
    if (phase !== "start") return;
    void document.body.offsetWidth;
    setPhase("opening");
  }, [phase]);
  return phase;
}

export const isShown = (phase: PanelPhase) => phase === "opening" || phase === "open";
/** For what comes in by a CSS animation instead of a transition. */
export const isEntering = (phase: PanelPhase) => phase === "start" || phase === "opening";
export const isMoving = (phase: PanelPhase) => phase === "start" || phase === "opening" || phase === "closing";

/** True while what these values lay out is moving: dragging a splitter must not animate, so transitions switch on only for this. */
export function useMoving(values: unknown[], onStart?: () => void): boolean {
  const [moving, setMoving] = useState(false);
  const first = useRef(true);
  useLayoutEffect(() => {
    if (first.current) { first.current = false; return; }
    setMoving(true);
    onStart?.();
    const settle = setTimeout(() => setMoving(false), SETTLE_MS);
    return () => clearTimeout(settle);
  }, values);
  return moving;
}

/** Takes its width from nothing to `width` and back. */
export function SlidePanel({ open, width, anchor, children }: { open: boolean; width: number; anchor: "left" | "right"; children: ReactNode }) {
  const phase = usePanelPhase(open);
  if (phase === "closed") return null;
  return (
    <div className={`slide${isMoving(phase) ? " moving" : ""}`} style={{ width: isShown(phase) ? width : 0 }}>
      <div className="slide-inner" style={{ width, [anchor]: 0 }}>{children}</div>
    </div>
  );
}
