import { Layers2 } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import type { ReaderTabState } from "../store";

/** A tab dragged out of the main window runs in a window of its own (route "tab?file=…&note=…&page=…"). */
function parse() {
  const hash = location.hash.replace("#", "");
  if (!hash.startsWith("tab?")) return null;
  const q = new URLSearchParams(hash.slice(4));
  const page = q.get("page");
  return { fileId: q.get("file") ?? undefined, note: q.get("note") ?? undefined, page: page ? Number(page) : undefined };
}

export const detached = parse();

/** Takes a tab out of the main window into a window of its own, near the screen point it was dropped at. */
export function detachTab(tab: ReaderTabState, x?: number, y?: number) {
  return call("window.detach", { file: tab.note ? null : tab.fileId, note: tab.note ?? null, page: tab.page ?? null, x: x ?? null, y: y ?? null });
}

/** 放回标签页: at the leading end of a detached window's toolbar, an icon like the toolbar's others. */
export function ReturnToTabsButton({ page }: { page?: () => number | undefined }) {
  if (!detached) return null;
  return (
    <button className="glass-button return-tabs" title={t("放回标签页")} aria-label={t("放回标签页")}
      onClick={() => call("window.returnTab", { file: detached.note ? null : detached.fileId ?? null, note: detached.note ?? null, page: page?.() ?? detached.page ?? null })}>
      <Layers2 size={17} strokeWidth={1.7} />
    </button>
  );
}
