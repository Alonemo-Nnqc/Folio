import { useState } from "react";
import { PanelLeft, PanelRight, Plus, Settings } from "lucide-react";
import { call, droppedPaths } from "../rpc";
import { t } from "../i18n";
import { closeTab, appMenu } from "../commands";
import { getState, setSetting, setState, useStore } from "../store";
import { openMenu } from "../ui/menu";
import { dragPointer } from "../ui/util";
import { SlidePanel, useMoving } from "../ui/slide";
import { Sidebar } from "./Sidebar";
import { ItemList } from "./ItemList";
import { Inspector } from "./Inspector";
import { QuickLook } from "./QuickLook";

/** What a toolbar leaves free for the sidebar button when the sidebar is hidden: 10 of margin and the button. */
const SIDEBAR_BUTTONS = 44;
export const LEAD_ROOM = SIDEBAR_BUTTONS + 6;
/** What a toolbar leaves free for the panel button beside Windows' buttons, when no panel is open. */
export const TOGGLE_ROOM = 40;

export function TabBar() {
  const tabs = useStore((s) => s.tabs);
  const active = useStore((s) => s.activeTab);
  const files = useStore((s) => s.files);
  if (tabs.length === 0) return null;
  return (
    <div className="tabbar">
      <div className={`tab${active === "library" ? " active" : ""}`} onClick={() => setState({ activeTab: "library" })}><span className="ellipsis">{t("文献库")}</span></div>
      {tabs.map((tab) => {
        const file = files.get(tab.fileId);
        return (
          <div key={tab.key} className={`tab${active === tab.key ? " active" : ""}`} title={file?.tabTip} onClick={() => setState({ activeTab: tab.key })}
            onMouseDown={(e) => { if (e.button === 1) { e.preventDefault(); closeTab(tab.key); } }}
            onContextMenu={(e) => {
              e.preventDefault();
              openMenu([
                { label: t("关闭标签页"), key: "Ctrl+W", action: () => closeTab(tab.key) },
                { label: t("关闭其他标签页"), action: () => getState().tabs.filter((x) => x.key !== tab.key).forEach((x) => closeTab(x.key)) },
              ], e.clientX, e.clientY);
            }}>
            <button className="close" title={t("关闭标签页")} onClick={(e) => { e.stopPropagation(); closeTab(tab.key); }}><XSmall /></button>
            <span className="ellipsis">{file?.tabTitle ?? ""}</span>
          </div>
        );
      })}
    </div>
  );
}

function XSmall() { return <svg width="9" height="9" viewBox="0 0 9 9"><path d="M1 1l7 7M8 1L1 8" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" /></svg>; }

/** Bottom left of the sidebar: opens Settings. A right click still offers the app's menu (help, about, quit…). */
export function SettingsButton() {
  return (
    <div className="sidebar-foot">
      <button className="foot-button" title={t("设置（Ctrl+,）")} onClick={() => call("window.settings")}
        onContextMenu={(e) => { e.preventDefault(); e.stopPropagation(); openMenu(appMenu(), e.clientX, e.clientY); }}>
        <Settings size={17} strokeWidth={1.7} />
      </button>
    </div>
  );
}

export function SidebarToggle({ onClick }: { onClick: () => void }) {
  return <button className="glass-button" title={t("显示/隐藏边栏")} onClick={onClick}><PanelLeft size={17} strokeWidth={1.7} /></button>;
}

export function InspectorToggle({ onClick }: { onClick: () => void }) {
  return <button className="glass-button" title={t("显示/隐藏检查器")} onClick={onClick}><PanelRight size={17} strokeWidth={1.7} /></button>;
}

/** The sidebar button rides along with the sidebar's edge; the sidebar slides under it, a splitter drag moves it directly. */
export function SidebarButtons({ visible, width, onToggle }: { visible: boolean; width: number; onToggle: () => void }) {
  return <div className="sidebar-toggle" style={{ left: visible ? width - 45 : SIDEBAR_BUTTONS - 34 }}><SidebarToggle onClick={onToggle} /></div>;
}

/** One button for the right panel, in the same place whether the panel is open or not: the panel slides under it. */
export function PanelToggle({ onClick }: { onClick: () => void }) {
  const captionWidth = useStore((s) => s.captionWidth);
  return <div className="panel-toggle" style={{ right: captionWidth + 6 }}><InspectorToggle onClick={onClick} /></div>;
}

export function Splitter({ side, width, min, max, onLive, onDone, offset }: { side: "left" | "right"; width: number; min: number; max: number; onLive: (w: number) => void; onDone: (w: number) => void; offset?: number }) {
  return <div className="splitter" style={side === "left" ? { right: offset ?? -3 } : { left: offset ?? -3 }} onPointerDown={(e) => {
    let latest = width;
    dragPointer(e, (dx) => { latest = Math.max(min, Math.min(max, width + (side === "left" ? dx : -dx))); onLive(latest); }, () => onDone(latest));
  }} />;
}

export function LibraryPage({ visible }: { visible: boolean }) {
  const sidebarVisible = useStore((s) => s.settings.sidebarVisible);
  const inspectorVisible = useStore((s) => s.settings.inspectorVisible);
  const storedSidebar = useStore((s) => s.settings.sidebarWidth);
  const storedInspector = useStore((s) => s.settings.inspectorWidth);
  const captionWidth = useStore((s) => s.captionWidth);
  const scope = useStore((s) => s.scope);
  const [sidebarWidth, setSidebarWidth] = useState<number | null>(null);
  const [inspectorWidth, setInspectorWidth] = useState<number | null>(null);
  const [dropping, setDropping] = useState(false);

  const toggleSidebar = () => setSetting("sidebarVisible", !getState().settings.sidebarVisible);
  const toggleInspector = () => setSetting("inspectorVisible", !getState().settings.inspectorVisible);

  const moving = useMoving([sidebarVisible, inspectorVisible]);

  return (
    <div className={`window${moving ? " moving" : ""}`} style={{ display: visible ? "flex" : "none", position: "relative" }}
      onDragOver={(e) => {
        if (!e.dataTransfer.types.includes("Files") || scope === "trash") return;
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
        setDropping(true);
      }}
      onDragLeave={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node)) setDropping(false); }}
      onDrop={async (e) => {
        setDropping(false);
        if (!e.dataTransfer.types.includes("Files") || scope === "trash") return;
        e.preventDefault();
        const paths = await droppedPaths(e.dataTransfer.files);
        if (paths.length) call("files.import", { paths });
      }}>
      <SlidePanel open={sidebarVisible} width={sidebarWidth ?? storedSidebar} anchor="right">
        <div className="column column-sidebar" style={{ width: "100%" }}>
          <div className="titlebar-row drag" />
          <Sidebar />
          <SettingsButton />
          <Splitter side="left" width={sidebarWidth ?? storedSidebar} min={210} max={400} onLive={setSidebarWidth} onDone={(w) => { setSetting("sidebarWidth", w); setSidebarWidth(null); }} />
        </div>
      </SlidePanel>
      <div className="column column-center">
        <ItemList leadInset={sidebarVisible ? 0 : LEAD_ROOM} trailingInset={inspectorVisible ? 0 : captionWidth + TOGGLE_ROOM} tabs={<TabBar />} />
      </div>
      <SlidePanel open={inspectorVisible} width={inspectorWidth ?? storedInspector} anchor="left">
        <div className="column column-inspector" style={{ width: "100%" }}>
          <div className="titlebar-row drag" />
          <Inspector />
          <Splitter side="right" width={inspectorWidth ?? storedInspector} min={270} max={520} onLive={setInspectorWidth} onDone={(w) => { setSetting("inspectorWidth", w); setInspectorWidth(null); }} />
        </div>
      </SlidePanel>
      <SidebarButtons visible={sidebarVisible} width={sidebarWidth ?? storedSidebar} onToggle={toggleSidebar} />
      <PanelToggle onClick={toggleInspector} />
      <QuickLook />
      {dropping && (
        <div className="drop-overlay">
          <div className="drop-card">
            <Plus size={36} color="var(--accent)" />
            <div className="big">{t("松开以添加文件")}</div>
            <div className="secondary">{t("PDF 会自动检索元数据并创建条目")}</div>
          </div>
        </div>
      )}
    </div>
  );
}
