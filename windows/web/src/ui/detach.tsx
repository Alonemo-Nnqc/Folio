import { Layers2 } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { getState, type ReaderTabState } from "../store";
import { closeTab } from "../commands";

/** A tab dragged out of the main window runs in a window of its own (route "tab?file=…&note=…&page=…"); that window
 *  keeps tabs of its own too (a note enlarged there opens beside the paper). */
function parse() {
  const hash = location.hash.replace("#", "");
  if (!hash.startsWith("tab?")) return null;
  const q = new URLSearchParams(hash.slice(4));
  const page = q.get("page");
  return { fileId: q.get("file") ?? undefined, note: q.get("note") ?? undefined, page: page ? Number(page) : undefined };
}

export const detached = parse();

/** Takes a tab out of this window into a window of its own, near the screen point it was dropped at. */
export function detachTab(tab: ReaderTabState, x?: number, y?: number) {
  return call("window.detach", { file: tab.note ? null : tab.fileId, note: tab.note ?? null, page: tab.page ?? null, x: x ?? null, y: y ?? null });
}

/** Puts a tab of a dragged-out window back into the main window's tabs; the window closes with its last tab. */
export function returnTab(key: string, page?: number) {
  const tab = getState().tabs.find((x) => x.key === key);
  if (!tab) return;
  call("window.returnTab", { file: tab.note ? null : tab.fileId, note: tab.note ?? null, page: page ?? tab.page ?? null });
  closeTab(key);
}

/** 放回主窗口: at the leading end of every tab's toolbar in a dragged-out window, an icon like the toolbar's others. */
export function ReturnToTabsButton({ tabKey, page }: { tabKey: string; page?: () => number | undefined }) {
  if (!detached) return null;
  return (
    <button className="glass-button return-tabs" title={t("放回主窗口")} aria-label={t("放回主窗口")} onClick={() => returnTab(tabKey, page?.())}>
      <Layers2 size={17} strokeWidth={1.7} />
    </button>
  );
}
