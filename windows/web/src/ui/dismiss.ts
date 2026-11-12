import { useEffect, useRef } from "react";
import { on } from "../rpc";

// Floating layers (menus, popovers, the comment editor, 划词翻译, 快速预览) close when the user turns away from them: a press
// anywhere else, Esc, or the window going to the background (WIN-30).
//
// The pages of the reader and of 快速预览 are iframes (public/reader/viewer.js): a press or a key there never reaches this
// window, and clicking into them moves no focus when they had it already. The page tells this window instead, with a
// "press" message for every button, "escape" while a layer is open, and "blur" when it loses focus.

export interface PressInfo {
  /** What was pressed: an element of this window, or the iframe the press was in. */
  target: EventTarget | null;
  /** The iframe the press was in, if it was in one. */
  frame: HTMLIFrameElement | null;
  button: number;
}

export interface Layer {
  /** A press on the layer itself, or on what belongs to it (its button, its submenus, a menu it opened). */
  contains(target: EventTarget | null): boolean;
  /** A press anywhere else. Without it the layer stays (a pinned 划词翻译 window) and the press goes on to the layers below. */
  onPress?(press: PressInfo): void;
  /** Esc: only the topmost layer that takes it gets it. */
  onEscape?(): void;
  /** The window went to the background. */
  onDeactivate?(): void;
}

const layers: Layer[] = [];

/** Adds a layer on top of the others; the function returned takes it away. */
export function addLayer(layer: Layer): () => void {
  layers.push(layer);
  announce();
  return () => {
    const index = layers.indexOf(layer);
    if (index >= 0) layers.splice(index, 1);
    announce();
  };
}

/** A layer while `active`; the handlers may change from one render to the next. */
export function useLayer(active: boolean, layer: Layer) {
  const latest = useRef(layer);
  latest.current = layer;
  useEffect(() => {
    if (!active) return;
    return addLayer({
      contains: (target) => latest.current.contains(target),
      onPress: layer.onPress && ((press) => latest.current.onPress?.(press)),
      onEscape: layer.onEscape && (() => latest.current.onEscape?.()),
      onDeactivate: layer.onDeactivate && (() => latest.current.onDeactivate?.()),
    });
    // Which handlers there are decides how the layer behaves (a pinned window ignores presses elsewhere).
  }, [active, !!layer.onPress, !!layer.onEscape, !!layer.onDeactivate]);
}

/** True when `target` is inside `element`, or inside a menu (menus belong to whatever opened them). */
export function within(element: Element | null | undefined, target: EventTarget | null) {
  if (!(target instanceof Node)) return false;
  if (element?.contains(target)) return true;
  return target instanceof Element && !!target.closest(".menu");
}

function press(info: PressInfo) {
  // Top down: a press on a layer leaves it and those below it alone.
  for (const layer of [...layers].reverse()) {
    if (!layers.includes(layer)) continue;
    if (layer.contains(info.target)) return;
    layer.onPress?.(info);
  }
}

function escape(): boolean {
  for (let i = layers.length - 1; i >= 0; i--) {
    const layer = layers[i];
    if (layer.onEscape) { layer.onEscape(); return true; }
  }
  return false;
}

function deactivate() {
  for (const layer of [...layers].reverse()) if (layers.includes(layer)) layer.onDeactivate?.();
}

/** The reader pages forward Esc only while there is a layer to close: otherwise it is theirs (deselecting, leaving a tool). */
const escapable = () => layers.some((l) => l.onEscape);

function frames(): HTMLIFrameElement[] {
  return [...document.querySelectorAll("iframe")];
}

function announce(frame?: Window | null) {
  const message = { cmd: "overlay", open: escapable() };
  for (const target of frame ? [frame] : frames().map((f) => f.contentWindow)) target?.postMessage(message, location.origin);
}

/** After focus has settled: gone from this window and from every page in it (document.hasFocus counts the iframes). */
function checkFocus() {
  setTimeout(() => { if (!document.hasFocus()) deactivate(); }, 0);
}

window.addEventListener("pointerdown", (e) => press({ target: e.target, frame: null, button: e.button }), true);
// Registered before any other key listener of the window: a layer's Esc goes no further (not to a sheet below, not to a field).
window.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || e.isComposing || !layers.length) return;
  if (escape()) { e.preventDefault(); e.stopImmediatePropagation(); }
}, true);
window.addEventListener("blur", checkFocus);
on("window.active", (active) => { if (!active) deactivate(); });
window.addEventListener("message", (e) => {
  const m = e.data?.folioReader;
  if (!m || e.origin !== location.origin) return;
  const frame = frames().find((f) => f.contentWindow === e.source) ?? null;
  if (!frame) return;
  switch (m.type) {
    case "press": press({ target: frame, frame, button: m.button ?? 0 }); break;
    case "escape": escape(); break;
    case "blur": checkFocus(); break;
    case "ready": announce(frame.contentWindow); break;
  }
});
