import { useEffect, useState } from "react";
import { ChevronDown, ChevronRight, Edit3, Folder, FolderPlus, Inbox, Library, Palette, Plus, Tag as TagIcon, Trash2 } from "lucide-react";
import { call, droppedPaths } from "../rpc";
import { t } from "../i18n";
import { canAddSubgroup, getState, groupAncestors, groupDepth, groupSubtreeHeight, MAX_GROUP_DEPTH, setSetting, useStore, type Group, type State } from "../store";
import { addMenu, deleteGroup, deleteTag, editTag, emptyTrash, newGroup, newTag, renameGroup } from "../commands";
import { openMenu, openMenuAt, sep, type MenuEntry } from "../ui/menu";

export const ITEMS_MIME = "application/x-folio-items";
export const GROUP_MIME = "application/x-folio-group";

type Zone = "before" | "on" | "after" | null;

/** Left padding of a row per level of group nesting. */
const INDENT = 14;

/** Collapsed groups, at any level (persisted, SIDE-05/17). */
function collapsedGroups(s: State): Set<string> {
  return new Set<string>(Array.isArray(s.settings.sidebarCollapsedGroups) ? s.settings.sidebarCollapsedGroups : []);
}

function setCollapsedGroups(s: State, collapsed: Set<string>) {
  setSetting("sidebarCollapsedGroups", [...collapsed].filter((id) => s.groups.has(id)));
}

/** Where a group dragged here goes (the macOS SidebarDragRules): onto a group it becomes its last subgroup, before or after
 *  a row it joins that row's level, and just below an open group with subgroups it becomes the first of them. The dragged
 *  group never goes inside itself, and with its own subgroups it stays within four levels. Null when it cannot. */
export function groupDrop(s: State, id: string, target: string | null, zone: Zone, isOpen: (g: string) => boolean = () => true):
  { parent: string | null; index: number } | null {
  if (!s.groups.has(id)) return null;
  const height = groupSubtreeHeight(s, id);
  const fits = (parent: string) => parent !== id && !groupAncestors(s, parent).includes(id) && groupDepth(s, parent) + height <= MAX_GROUP_DEPTH;
  const children = (parent: string) => (s.childGroups[parent] ?? []).filter((g) => g !== id);
  if (target === null) return { parent: null, index: s.topGroups.filter((g) => g !== id).length };
  if (target === id) return null;
  if (zone === "on") return fits(target) ? { parent: target, index: children(target).length } : null;
  if (zone === "after" && isOpen(target) && children(target).length > 0) return fits(target) ? { parent: target, index: 0 } : null;
  const parent = s.groups.get(target)?.parentId ?? null;
  if (parent !== null && !fits(parent)) return null;
  const siblings = parent === null ? s.topGroups.filter((g) => g !== id) : children(parent);
  return { parent, index: siblings.indexOf(target) + (zone === "after" ? 1 : 0) };
}

let draggingGroup: string | null = null;
export let draggingItems = false;
export function setDraggingItems(v: boolean) { draggingItems = v; }

function Row({ scope, name, icon, count, depth = 0, disclosure, onContext, groupId, hasFiles, open }: {
  scope: string; name: string; icon: React.ReactNode; count?: number; depth?: number; disclosure?: React.ReactNode; onContext: (e: React.MouseEvent) => void; groupId?: string; hasFiles?: boolean;
  /** Whether the group row's subgroups are showing. */
  open?: boolean;
}) {
  const current = useStore((s) => s.scope === scope);
  const [zone, setZone] = useState<Zone>(null);
  const isGroup = !!groupId;
  const isOpen = (g: string) => g === groupId ? !!open : !collapsedGroups(getState()).has(g);

  const accepts = (e: React.DragEvent): Zone => {
    const s = getState();
    if (draggingGroup) {
      if (!isGroup) return null;
      const h = e.currentTarget.getBoundingClientRect();
      const y = e.clientY - h.top;
      const z: Zone = y < h.height * 0.28 ? "before" : y > h.height * 0.72 ? "after" : "on";
      return groupDrop(s, draggingGroup, groupId!, z, isOpen) ? z : null;
    }
    if (draggingItems) {
      if (s.scope === "trash" || scope === s.scope) return null;
      return isGroup || scope.startsWith("tag:") || scope === "trash" ? "on" : null;
    }
    if (e.dataTransfer.types.includes("Files")) return isGroup || hasFiles ? "on" : null;
    return null;
  };

  // The insertion line starts where the folder icons of the level the group would join start.
  const into = zone === "after" && isGroup && open && (getState().childGroups[groupId!] ?? []).some((g) => g !== draggingGroup);
  const style = { paddingLeft: 6 + depth * INDENT, "--drop-left": `${6 + (depth + (into ? 1 : 0)) * INDENT + 13}px` } as React.CSSProperties;

  return (
    <div className={`side-row${current ? " current" : ""}${zone ? ` drop-${zone}` : ""}`} style={style} draggable={isGroup}
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
          const move = groupDrop(s, draggingGroup, groupId!, z, isOpen);
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

/** A group row and, below it, its subgroups at every level, sliding open and closed. */
function GroupBranch({ id, depth, menu }: { id: string; depth: number; menu: (g: Group) => (e: React.MouseEvent) => void }) {
  const g = useStore((s) => s.groups.get(id));
  const children = useStore((s) => s.childGroups[id]) ?? [];
  const count = useStore((s) => s.counts[`group:${id}`]);
  const open = useStore((s) => !collapsedGroups(s).has(id));
  if (!g) return null;
  const toggle = (e: React.MouseEvent) => {
    e.stopPropagation();
    const s = getState();
    const next = collapsedGroups(s);
    if (!next.delete(id)) next.add(id);
    setCollapsedGroups(s, next);
  };
  return (
    <>
      <Row scope={`group:${id}`} groupId={id} depth={depth} open={open && children.length > 0} name={g.name} count={count} onContext={menu(g)}
        icon={<span className="icon" style={g.color ? { color: g.color } : undefined}><Folder size={18} strokeWidth={1.6} /></span>}
        disclosure={children.length > 0
          ? <button className={`disclosure${open ? " open" : ""}`} title={open ? t("折叠") : t("展开")} onClick={toggle}><ChevronRight size={11} /></button>
          : <span className="disclosure" aria-hidden />} />
      {children.length > 0 && (
        <div className={`side-children${open ? " open" : ""}`}>
          <div className="side-children-inner">
            {children.map((cid) => <GroupBranch key={cid} id={cid} depth={depth + 1} menu={menu} />)}
          </div>
        </div>
      )}
    </>
  );
}

export function Sidebar() {
  const topGroups = useStore((s) => s.topGroups);
  const tags = useStore((s) => s.tags);
  const counts = useStore((s) => s.counts);
  const scope = useStore((s) => s.scope);
  const [folded, setFolded] = useState<Set<string>>(new Set());

  // A group chosen elsewhere (a new subgroup, a menu) is revealed: its collapsed ancestors open.
  useEffect(() => {
    if (!scope.startsWith("group:")) return;
    const s = getState();
    const collapsed = collapsedGroups(s);
    const hidden = groupAncestors(s, scope.slice(6)).filter((a) => collapsed.has(a));
    if (hidden.length === 0) return;
    hidden.forEach((a) => collapsed.delete(a));
    setCollapsedGroups(s, collapsed);
  }, [scope]);

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
      // Groups nest four levels deep: the last level has no 新建子分组 (SIDE-06/17).
      ...(canAddSubgroup(getState(), g.id) ? [{ label: t("新建子分组…"), icon: <FolderPlus size={14} />, action: () => newGroup(g.id) } as MenuEntry] : []),
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


  return (
    <div className="sidebar-scroll" onContextMenu={context(background)}>
      {header("library", t("文献库"), (el) => openMenuAt(el, addMenu()), t("添加文献"))}
      {!folded.has("library") && <>
        <Row scope="all" name={t("所有文献")} icon={<span className="icon"><Library size={18} strokeWidth={1.6} /></span>} count={counts.all} hasFiles onContext={context(background)} />
        <Row scope="unfiled" name={t("未分组")} icon={<span className="icon"><Inbox size={18} strokeWidth={1.6} /></span>} count={counts.unfiled} hasFiles onContext={context(background)} />
        <Row scope="trash" name={t("回收站")} icon={<span className="icon"><Trash2 size={18} strokeWidth={1.6} /></span>} count={counts.trash} onContext={context([{ label: t("清空回收站…"), icon: <Trash2 size={14} />, disabled: !counts.trash, action: emptyTrash }])} />
      </>}
      {header("groups", t("分组"), () => newGroup(), t("新建分组"), true)}
      {!folded.has("groups") && topGroups.map((id) => <GroupBranch key={id} id={id} depth={0} menu={(g) => context(groupMenu(g))} />)}
      {header("tags", t("标签"), () => newTag(), t("新建标签"))}
      {!folded.has("tags") && tags.map((tag) => (
        <Row key={tag.id} scope={`tag:${tag.id}`} name={tag.name} count={counts[`tag:${tag.id}`]} icon={<span className="dot" style={{ background: tag.color }} />}
          onContext={context([{ label: t("编辑标签…"), icon: <Edit3 size={14} />, action: () => editTag(tag) }, { label: t("删除标签…"), icon: <Trash2 size={14} />, action: () => deleteTag(tag) }])} />
      ))}
    </div>
  );
}
