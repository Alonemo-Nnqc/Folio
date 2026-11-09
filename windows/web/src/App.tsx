import { useEffect, useRef } from "react";
import { call, emitLocal, on } from "./rpc";
import { addByIdentifier, addFiles, closeTab, importReferences, newGroup, openReader, revealFirstFile, selectNextTab, showNotes, translate } from "./commands";
import { getState, setSetting, setState, useStore } from "./store";
import { LibraryPage } from "./library/LibraryPage";
import { ReaderTab, readers } from "./reader/ReaderTab";
import { useEvent } from "./ui/util";
import { setCaption } from "./ui/caption";

interface Key { key: string; code: string; ctrl: boolean; alt: boolean; shift: boolean }

/** The window's keys, the same as the macOS menu bar's where Windows has them free. True when used. */
function globalKey({ code, ctrl, alt, shift }: Key): boolean {
  const s = getState();
  const ids = s.selection;
  const library = s.activeTab === "library";
  const reader = readers.get(s.activeTab);
  if (code === "F11") { call("window.fullScreen"); return true; }
  if (!ctrl) return false;
  if (!alt && !shift) {
    switch (code) {
      case "KeyO": addFiles(); return true;
      case "KeyW": if (!library) closeTab(s.activeTab); return true;
      case "Digit1": setState({ activeTab: "library" }); return true;
      case "Tab": selectNextTab(false); return true;
      case "Comma": call("window.settings"); return true;
      case "KeyF": if (library) { emitLocal("focusSearch", null); return true; } return false;
    }
  }
  if (shift && !alt) {
    switch (code) {
      case "KeyO": addByIdentifier(); return true;
      case "KeyN": newGroup(); return true;
      case "KeyI": importReferences(); return true;
      case "KeyE": if (ids.length) { call("references.export", { ids, format: "bibtex" }); return true; } return false;
      case "KeyC": if (ids.length) { call("cite.copy", { ids }); return true; } return false;
      case "KeyR": if (ids.length === 1) { revealFirstFile(ids); return true; } return false;
      case "KeyL": setState({ activeTab: "library" }); return true;
      case "Tab": selectNextTab(true); return true;
    }
  }
  if (alt && !shift) {
    switch (code) {
      case "KeyS": if (reader) reader.toggleSidebar(); else setSetting("sidebarVisible", !s.settings.sidebarVisible); return true;
      case "KeyI": if (reader) reader.toggleNotes(); else setSetting("inspectorVisible", !s.settings.inspectorVisible); return true;
      case "KeyR": if (ids.length) { call("items.retrieve", { ids }); return true; } return false;
      case "KeyN": if (library) { showNotes(); return true; } return false;
      case "KeyT": if (library && ids.length) { translate(ids); return true; } return false;
    }
  }
  return false;
}

export function MainApp() {
  const tabs = useStore((s) => s.tabs);
  const activeTab = useStore((s) => s.activeTab);
  const dark = useStore((s) => s.dark);
  const panelUnderButtons = useStore((s) => (s.activeTab === "library" ? s.settings.inspectorVisible : s.readerNotes[s.activeTab] ?? false));
  const captionShown = useRef({ activeTab, dark });

  const dispatch = (k: Key, e?: Event) => {
    const reader = readers.get(getState().activeTab);
    if (globalKey(k) || reader?.handleKey(k)) e?.preventDefault();
  };
  useEvent(window, "folio-key", (e: CustomEvent) => dispatch(e.detail));
  useEvent(window, "keydown", (e: KeyboardEvent) => {
    if (document.querySelector(".scrim") || document.querySelector(".menu")) return;
    const typing = (e.target as Element)?.closest?.("input, textarea, select");
    if (typing && !e.ctrlKey && !e.altKey && !e.key.startsWith("F")) return;
    // Text boxes keep their own clipboard, undo and select-all.
    if (typing && e.ctrlKey && !e.altKey && !e.shiftKey && ["KeyA", "KeyC", "KeyV", "KeyX", "KeyZ", "KeyY"].includes(e.code)) return;
    if (e.altKey && !e.ctrlKey && (e.key === "F4" || e.key === " ")) return;
    if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return;
    dispatch({ key: e.key, code: e.code, ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey }, e);
  });
  // No browser behaviour: right clicks, page zoom, dropping a file on the page.
  useEvent(window, "contextmenu", (e: Event) => { if (!(e.target as Element).closest?.("input, textarea, .selectable")) e.preventDefault(); });
  useEvent(window, "wheel", (e: WheelEvent) => { if (e.ctrlKey) e.preventDefault(); }, { passive: false });
  useEvent(window, "dragover", (e: DragEvent) => e.preventDefault());
  useEvent(window, "drop", (e: DragEvent) => e.preventDefault());

  useEffect(() => on("reader.open", ({ fileId, page }) => openReader(fileId, page ?? undefined)), []);
  useEffect(() => on("library.willChange", () => {
    const tabs = getState().tabs;
    tabs.forEach((tab) => closeTab(tab.key));
  }), []);
  useEffect(() => on("reveal", () => setState({ activeTab: "library" })), []);
  // What is still in flight: a note being typed saves when its box loses focus, the readers save their place.
  useEffect(() => on("app.willClose", () => {
    (document.activeElement as HTMLElement | null)?.blur?.();
    readers.forEach((r) => r.flush());
  }), []);

  // What is under Windows' buttons follows what the page shows there.
  useEffect(() => {
    const light = panelUnderButtons ? "#f1f1f3" : "#ffffff";
    const night = panelUnderButtons ? "#252527" : "#1e1e1f";
    // A panel sliding in fades the colour with it; a change of tab or theme is immediate.
    const animate = captionShown.current.activeTab === activeTab && captionShown.current.dark === dark;
    captionShown.current = { activeTab, dark };
    setCaption(dark ? night : light, dark ? "#ffffff" : "#000000", animate);
  }, [activeTab, panelUnderButtons, dark]);

  useEffect(() => { call("window.title", { title: "Folio" }); emitLocal("focusList", null); }, []);
  useEffect(() => { if (activeTab === "library") emitLocal("focusList", null); }, [activeTab]);

  return (
    <>
      <LibraryPage visible={activeTab === "library"} />
      {tabs.map((tab) => <ReaderTab key={tab.key} tabKey={tab.key} fileId={tab.fileId} page={tab.page} visible={activeTab === tab.key} />)}
    </>
  );
}
