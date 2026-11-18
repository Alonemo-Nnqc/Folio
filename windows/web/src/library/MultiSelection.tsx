import { ChevronRight, Layers, ListChecks } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { defaultFile, filesOf, getState, setState, useStore } from "../store";
import { itemMenu } from "../commands";
import { openMenuAt, type MenuEntry } from "../ui/menu";
import { Chip } from "../ui/controls";

function selectAll() {
  const rows = getState().rows;
  setState({ selection: rows, fileSelection: null });
  call("library.select", { ids: rows });
}

function selectNone() {
  setState({ selection: [], fileSelection: null });
  call("library.select", { ids: [] });
}

/** No separator first, last or twice in a row. */
function trimmed(entries: MenuEntry[]): MenuEntry[] {
  const out: MenuEntry[] = [];
  for (const e of entries) {
    if (e.kind === "separator" && (out.length === 0 || out[out.length - 1].kind === "separator")) continue;
    out.push(e);
  }
  while (out.length && out[out.length - 1].kind === "separator") out.pop();
  return out;
}

/** The inspector with several papers selected (or in 多选): what they are, the tags they share, and everything that can
 *  be done to all of them at once — the same commands as the list's context menu (one source: itemMenu), as rows. */
export function MultiSelectionPanel() {
  const selection = useStore((s) => s.selection);
  const rows = useStore((s) => s.rows);
  const multi = useStore((s) => s.multiSelect);
  const items = useStore((s) => s.items);
  const tags = useStore((s) => s.tags);
  const itemTags = useStore((s) => s.itemTags);
  const dark = useStore((s) => s.dark);
  useStore((s) => s.jobs);
  useStore((s) => s.filesByItem);

  if (selection.length === 0) {
    return (
      <div className="multi-empty">
        <ListChecks size={34} strokeWidth={1.4} className="secondary" />
        <div className="big">{t("多选")}</div>
        <div className="secondary">{t("点按条目即可选中或取消，选好后在这里批量添加标签、翻译、删除等。按 Esc 或再点一次“多选”退出。")}</div>
        <button className="btn small" onClick={selectAll}>{t("全选")}</button>
      </div>
    );
  }

  const s = getState();
  const inRows = new Set(selection);
  const ids = [...rows.filter((id) => inRows.has(id)), ...selection.filter((id) => !rows.includes(id))];
  const selected = ids.map((id) => items.get(id)).filter(Boolean) as NonNullable<ReturnType<typeof items.get>>[];
  const pdfs = selected.filter((i) => defaultFile(s, i)?.isPdf).length;
  const translated = selected.filter((i) => filesOf(s, i.id).some((f) => f.translationKind)).length;
  const shared = tags.filter((tag) => ids.every((id) => itemTags[id]?.includes(tag.id)));
  // Opening many papers at once is not what this panel is for.
  const entries = trimmed(itemMenu(ids).filter((e) => !(e.kind === undefined || e.kind === "item") || (e.label !== t("打开") && e.label !== t("打开方式"))));
  const destructive = new Set([t("删除"), t("彻底删除")]);

  return (
    <div className="inspector-scroll multi-panel">
      <div className="multi-head">
        <Layers size={30} strokeWidth={1.4} className="secondary" style={{ flex: "none" }} />
        <div style={{ minWidth: 0 }}>
          <div className="multi-title">{t("已选择 %lld 篇文献", selected.length)}</div>
          <div className="secondary multi-sub">{t("%lld 篇有 PDF · %lld 篇已翻译", pdfs, translated)}</div>
          <div className="multi-links">
            <button className="link-button" onClick={selectAll}>{t("全选")}</button>
            <button className="link-button" onClick={selectNone}>{t("取消选择")}</button>
            {multi && <button className="link-button" onClick={() => setState({ multiSelect: false })}>{t("完成")}</button>}
          </div>
        </div>
      </div>
      {shared.length > 0 && (
        <div className="multi-tags">
          <div className="multi-caption">{t("共同标签")}</div>
          <div className="wrap">
            {shared.map((tag) => <Chip key={tag.id} label={tag.name} color={tag.color} dark={dark} onRemove={() => call("items.setTag", { tag: tag.id, ids, on: false })} />)}
          </div>
        </div>
      )}
      <div className="multi-actions">
        {entries.map((e, k) => {
          if (e.kind === "separator") return <div key={k} className="multi-sep" />;
          if (e.kind === "title" || e.kind === "row") return null;
          return (
            <button key={k} className={`multi-row${destructive.has(e.label) ? " destructive" : ""}`} disabled={e.disabled}
              onClick={(ev) => { if (e.submenu) openMenuAt(ev.currentTarget, e.submenu); else e.action?.(); }}>
              <span className="multi-icon">{e.icon}</span>
              <span className="ellipsis">{e.label}</span>
              <span style={{ flex: 1 }} />
              {e.submenu && <ChevronRight size={12} className="secondary" />}
            </button>
          );
        })}
      </div>
    </div>
  );
}
