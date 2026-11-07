import { useState } from "react";
import { ChevronDown, ChevronRight, Edit3, Folder, FolderPlus, Inbox, Library, Palette, Plus, Tag as TagIcon, Trash2 } from "lucide-react";
import { call, droppedPaths } from "../rpc";
import { t } from "../i18n";
import { getState, useStore, type Group, type State } from "../store";
import { addMenu, deleteGroup, deleteTag, editTag, emptyTrash, newGroup, newTag, renameGroup } from "../commands";
import { openMenu, openMenuAt, sep, type MenuEntry } from "../ui/menu";

export const ITEMS_MIME = "application/x-folio-items";
export const GROUP_MIME = "application/x-folio-group";

type Zone = "before" | "on" | "after" | null;

/** Where a group dragged here goes (the macOS SidebarDragRules); null when it cannot. */
function groupDrop(s: State, id: string, target: string | null, zone: Zone): { parent: string | null; index: number } | null {
  if (!s.groups.has(id)) return null;
  const hasChildren = (s.childGroups[id] ?? []).length > 0;
  if (target === null) return { parent: null, index: s.topGroups.filter((g) => g !== id).length };
  if (target === id) return null;
  const parent = s.groups.get(target)?.parentId ?? null;
  if (zone === "on") return parent === null && !hasChildren ? { parent: target, index: (s.childGroups[target] ?? []).filter((g) => g !== id).length } : null;
  if (parent !== null && (hasChildren || parent === id)) return null;
  const siblings = (parent === null ? s.topGroups : s.childGroups[parent] ?? []).filter((g) => g !== id);
  return { parent, index: siblings.indexOf(target) + (zone === "after" ? 1 : 0) };
}

let draggingGroup: string | null = null;
export let draggingItems = false;
export function setDraggingItems(v: boolean) { draggingItems = v; }

function Row({ scope, name, icon, count, depth = 0, disclosure, onContext, groupId, hasFiles }: {
  scope: string; name: string; icon: React.ReactNode; count?: number; depth?: number; disclosure?: React.ReactNode; onContext: (e: React.MouseEvent) => void; groupId?: string; hasFiles?: boolean;
}) {
  const current = useStore((s) => s.scope === scope);
  const [zone, setZone] = useState<Zone>(null);
  const isGroup = !!groupId;

  const accepts = (e: React.DragEvent): Zone => {
    const s = getState();
    if (draggingGroup) {
      if (!isGroup) return null;
      const h = e.currentTarget.getBoundingClientRect();
      const y = e.clientY - h.top;
      const z: Zone = y < h.height * 0.28 ? "before" : y > h.height * 0.72 ? "after" : "on";
      return groupDrop(s, draggingGroup, groupId!, z) ? z : null;
    }
    if (draggingItems) {
      if (s.scope === "trash" || scope === s.scope) return null;
      return isGroup || scope.startsWith("tag:") || scope === "trash" ? "on" : null;
    }
    if (e.dataTransfer.types.includes("Files")) return isGroup || hasFiles ? "on" : null;
    return null;
  };

  return (
    <div className={`side-row${current ? " current" : ""}${zone ? ` drop-${zone}` : ""}`} style={{ paddingLeft: 6 + depth * 18 }} draggable={isGroup}
      onDragStart={(e) => { if (!isGroup) return; draggingGroup = groupId!; e.dataTransfer.setData(GROUP_MIME, groupId!); e.dataTransfer.effectAllowed = "move"; e.stopPropagation(); }}
      onDragEnd={() => { draggingGroup = null; }}
      onDragOver={(e) => {
        const z = accepts(e);
        setZone(z);
        if (z) { e.preventDefault(); e.stopPropagation(); e.dataTransfer.dropEffect = draggingGroup ? "move" : draggingItems ? "link" : "copy"; }
      }}
      onDragLeave={() => setZone(null)}
      onDrop={async (e) => {
        const z = zone;
        setZone(null);
        if (!z) return;
        e.preventDefault();
        e.stopPropagation();
        const s = getState();
        if (draggingGroup) {
          const move = groupDrop(s, draggingGroup, groupId!, z);
          if (move) call("group.move", { id: draggingGroup, parent: move.parent, index: move.index });
          return;
        }
        const items = e.dataTransfer.getData(ITEMS_MIME);
        if (items) {
          const ids = items.split("\n").filter(Boolean);
          if (groupId) call("items.addToGroup", { ids, group: groupId });
          else if (scope.startsWith("tag:")) call("items.setTag", { tag: scope.slice(4), ids, on: true });
          else if (scope === "trash") call("items.trash", { ids });
          return;
        }
        const paths = await droppedPaths(e.dataTransfer.files);
        if (paths.length) call("files.importTo", { paths, group: groupId ?? null });
      }}
      onClick={() => call("library.scope", { scope })} onContextMenu={onContext}>
      {disclosure}
      {icon}
      <span className="name ellipsis">{name}</span>
      {!!count && <span className="count">{count}</span>}
    </div>
  );
}

export function Sidebar() {
  const topGroups = useStore((s) => s.topGroups);
  const groups = useStore((s) => s.groups);
  const childGroups = useStore((s) => s.childGroups);
  const tags = useStore((s) => s.tags);
  const counts = useStore((s) => s.counts);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const [folded, setFolded] = useState<Set<string>>(new Set());

  const toggle = (set: Set<string>, setter: (s: Set<string>) => void, id: string) => {
    const next = new Set(set);
    if (!next.delete(id)) next.add(id);
    setter(next);
  };

  const background: MenuEntry[] = [
    { label: t("新建分组…"), icon: <Plus size={14} />, action: () => newGroup() },
    { label: t("新建标签…"), icon: <TagIcon size={14} />, action: () => newTag() },
  ];

  const groupMenu = (g: Group): MenuEntry[] => {
    const presets = getState().statics.tagPresets;
    return [
      ...(g.parentId ? [] : [{ label: t("新建子分组…"), icon: <FolderPlus size={14} />, action: () => newGroup(g.id) } as MenuEntry]),
      { label: t("重命名…"), icon: <Edit3 size={14} />, action: () => renameGroup(g) },
      { label: t("颜色"), icon: <Palette size={14} />, submenu: [
        { label: t("默认"), checked: !g.color, action: () => call("group.color", { id: g.id, color: null }) },
        ...presets.map((p): MenuEntry => ({ label: p.name, dot: p.hex, checked: g.color === p.hex, action: () => call("group.color", { id: g.id, color: p.hex }) })),
      ] },
      sep,
      { label: t("删除分组…"), icon: <Trash2 size={14} />, action: () => deleteGroup(g) },
    ];
  };

  const context = (items: MenuEntry[]) => (e: React.MouseEvent) => { e.preventDefault(); e.stopPropagation(); openMenu(items, e.clientX, e.clientY); };

  const header = (id: string, title: string, add: (el: HTMLElement) => void, tip: string, dropHeader?: boolean) => (
    <div className={`side-header${folded.has(id) ? " folded" : ""}`} onClick={() => toggle(folded, setFolded, id)}
      onDragOver={dropHeader ? (e) => { if (draggingGroup) { e.preventDefault(); e.dataTransfer.dropEffect = "move"; } } : undefined}
      onDrop={dropHeader ? (e) => {
        if (!draggingGroup) return;
        e.preventDefault();
        const move = groupDrop(getState(), draggingGroup, null, "on");
        if (move) call("group.move", { id: draggingGroup, parent: move.parent, index: move.index });
      } : undefined}>
      <span>{title}</span>
      <span className="chev">{folded.has(id) ? <ChevronRight size={10} /> : <ChevronDown size={10} />}</span>
      <button className="add" title={tip} onClick={(e) => { e.stopPropagation(); add(e.currentTarget); }}><Plus size={13} /></button>
    </div>
  );

  const folderIcon = (g: Group) => <span className="icon" style={g.color ? { color: g.color } : undefined}><Folder size={18} strokeWidth={1.6} /></span>;

  return (
    <div className="sidebar-scroll" onContextMenu={context(background)}>
      {header("library", t("文献库"), (el) => openMenuAt(el, addMenu()), t("添加文献"))}
      {!folded.has("library") && <>
        <Row scope="all" name={t("所有文献")} icon={<span className="icon"><Library size={18} strokeWidth={1.6} /></span>} count={counts.all} hasFiles onContext={context(background)} />
        <Row scope="unfiled" name={t("未分组")} icon={<span className="icon"><Inbox size={18} strokeWidth={1.6} /></span>} count={counts.unfiled} hasFiles onContext={context(background)} />
        <Row scope="trash" name={t("回收站")} icon={<span className="icon"><Trash2 size={18} strokeWidth={1.6} /></span>} count={counts.trash} onContext={context([{ label: t("清空回收站…"), icon: <Trash2 size={14} />, disabled: !counts.trash, action: emptyTrash }])} />
      </>}
      {header("groups", t("分组"), () => newGroup(), t("新建分组"), true)}
      {!folded.has("groups") && topGroups.map((id) => {
        const g = groups.get(id);
        if (!g) return null;
        const children = childGroups[id] ?? [];
        const open = !collapsed.has(id);
        return (
          <div key={id}>
            <Row scope={`group:${id}`} groupId={id} name={g.name} count={counts[`group:${id}`]} icon={folderIcon(g)} onContext={context(groupMenu(g))}
              disclosure={children.length > 0
                ? <button className="disclosure" title={open ? t("折叠") : t("展开")} onClick={(e) => { e.stopPropagation(); toggle(collapsed, setCollapsed, id); }}>{open ? <ChevronDown size={11} /> : <ChevronRight size={11} />}</button>
                : <span style={{ width: 7, flex: "none", marginRight: -3 }} />} />
            {open && children.map((cid) => {
              const c = groups.get(cid);
              return c && <Row key={cid} scope={`group:${cid}`} groupId={cid} depth={1} name={c.name} count={counts[`group:${cid}`]} icon={folderIcon(c)} onContext={context(groupMenu(c))} />;
            })}
          </div>
        );
      })}
      {header("tags", t("标签"), () => newTag(), t("新建标签"))}
      {!folded.has("tags") && tags.map((tag) => (
        <Row key={tag.id} scope={`tag:${tag.id}`} name={tag.name} count={counts[`tag:${tag.id}`]} icon={<span className="dot" style={{ background: tag.color }} />}
          onContext={context([{ label: t("编辑标签…"), icon: <Edit3 size={14} />, action: () => editTag(tag) }, { label: t("删除标签…"), icon: <Trash2 size={14} />, action: () => deleteTag(tag) }])} />
      ))}
    </div>
  );
}
