import { useEffect, useState } from "react";
import { AlertTriangle, BookOpen, Compass, Languages, Library, RefreshCw, Search, Settings as Gear, Sparkles } from "lucide-react";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { getState, setSetting, useStore } from "../store";
import { Field, Select, Switch } from "../ui/controls";
import { confirm, dialog, openSheet } from "../ui/sheet";
import { openMenu } from "../ui/menu";
import { Card, Header, Note, Row } from "./parts";
import { TranslationPane } from "./TranslationPane";
import { ZoteroSheet } from "./ZoteroSheet";

const PANES = [
  { key: "general", title: "通用", icon: Gear }, { key: "reader", title: "阅读", icon: BookOpen }, { key: "library", title: "文献库", icon: Library }, { key: "retrieval", title: "检索", icon: Search },
  { key: "translation", title: "翻译", icon: Languages }, { key: "browser", title: "浏览器", icon: Compass }, { key: "ai", title: "AI", icon: Sparkles },
];

let launchedLanguage: string | null = null;

function Appearance() {
  const value = useStore((s) => s.settings.appearance);
  const options: [string, string, string, string][] = [
    ["system", t("自动"), "linear-gradient(90deg, #9ec7f2, #3a3a3c)", "#e8e8ea"], ["light", t("浅色"), "linear-gradient(180deg, #9ec7f2, #d9e6fa)", "#ffffff"], ["dark", t("深色"), "linear-gradient(180deg, #404040, #1f1f1f)", "#2e2e2e"],
  ];
  return (
    <div className="appearance">
      {options.map(([key, title, back, window]) => (
        <button key={key} className={value === key ? "on" : ""} onClick={() => setSetting("appearance", key)}>
          <span className="preview" style={{ background: back }}><i style={{ background: window }} /></span>
          {title}
        </button>
      ))}
    </div>
  );
}

function General() {
  const s = useStore((x) => x.settings);
  const statics = useStore((x) => x.statics);
  launchedLanguage ??= s.language ?? "";
  return (
    <>
      <Header>{t("外观")}</Header>
      <Card><Appearance /></Card>
      <Header>{t("打开")}</Header>
      <Card>
        <Row title={t("打开 PDF 时使用")}><Select value={s.openWithMode} options={[{ value: "folio", label: t("Folio 阅读器") }, { value: "system", label: t("系统默认应用") }, { value: "custom", label: t("指定应用…") }]} onChange={(v) => setSetting("openWithMode", v)} /></Row>
        {s.openWithMode === "custom" && (
          <Row title={t("应用")}>
            <span className="secondary ellipsis">{s.openWithAppPath ? s.openWithAppPath.split(/[\\/]/).pop().replace(/\.exe$/i, "") : t("未选择")}</span>
            <button className="btn" onClick={async () => { const [path] = await call<string[]>("pick.file", { filter: "EXE|*.exe", multiple: false }); if (path) setSetting("openWithAppPath", path); }}>{t("选择…")}</button>
          </Row>
        )}
        <Row title={t("打开未读的论文时，标为\"在读\"")}><Switch on={s.markReadingOnOpen} onChange={(v) => setSetting("markReadingOnOpen", v)} /></Row>
        <Row title={t("启动时重新打开上次的论文标签页")}><Switch on={s.reopenReaderTabs} onChange={(v) => setSetting("reopenReaderTabs", v)} /></Row>
      </Card>
      <Header>{t("列表")}</Header>
      <Card>
        <Row title={t("父分组中显示子分组的条目")}><Switch on={s.includeSubgroupItems} onChange={(v) => setSetting("includeSubgroupItems", v)} /></Row>
        <Row title={t("默认引用样式")}><Select value={s.citationStyle} options={statics.citationStyles.map((c) => ({ value: c.raw, label: c.name }))} onChange={(v) => setSetting("citationStyle", v)} /></Row>
      </Card>
      <Header>{t("语言")}</Header>
      <Card>
        <Row title={t("界面语言")}><Select value={s.language ?? ""} options={[{ value: "", label: t("跟随系统") }, { value: "zh-Hans", label: "简体中文" }, { value: "en", label: "English" }]} onChange={(v) => setSetting("language", v)} /></Row>
        {(s.language ?? "") !== launchedLanguage && <Row title={t("重新启动 Folio 后生效")}><button className="btn" onClick={() => call("app.restart")}>{t("立即重新启动")}</button></Row>}
      </Card>
      <Header>{t("软件更新")}</Header>
      <Card>
        <Row title={t("当前版本")}><span className="secondary">{statics.version} ({statics.channel})</span><button className="btn" onClick={() => call("update.check")}>{t("检查更新…")}</button></Row>
        <Row title={t("自动检查更新")}><Switch on={s.autoCheckUpdates} onChange={(v) => setSetting("autoCheckUpdates", v)} /></Row>
        <Row title={t("接收测试版")}><Switch on={s.updatePrereleases} onChange={(v) => setSetting("updatePrereleases", v)} /></Row>
      </Card>
      <Note>{t("更新从 GitHub Releases 下载，在后台完成，重新启动即完成安装。")}</Note>
    </>
  );
}

function Reader() {
  const s = useStore((x) => x.settings);
  const colors = useStore((x) => x.statics.annotationColors);
  return (
    <>
      <Header>{t("页面")}</Header>
      <Card>
        <Row title={t("首次打开时的缩放")}><Select value={s.readerZoom} options={[{ value: "fitWidth", label: t("适合页宽") }, { value: "actualSize", label: t("实际大小") }]} onChange={(v) => setSetting("readerZoom", v)} /></Row>
        <Row title={t("显示方式")}><Select value={s.readerLayout} options={[{ value: "single", label: t("单页连续") }, { value: "twoUp", label: t("双页连续") }]} onChange={(v) => setSetting("readerLayout", v)} /></Row>
        <Row title={t("显示页面阴影")}><Switch on={s.readerPageShadows} onChange={(v) => setSetting("readerPageShadows", v)} /></Row>
      </Card>
      <Header>{t("批注")}</Header>
      <Card>
        <Row title={t("默认高亮颜色")}><div className="swatches">{colors.map((c) => <button key={c.key} title={c.title} className={`swatch${s.highlightColor === c.key ? " on" : ""}`} style={{ background: c.hex }} onClick={() => setSetting("highlightColor", c.key)} />)}</div></Row>
        <Row title={t("批注作者")}><Field className="set-field" value={s.annotationAuthor ?? ""} placeholder={getState().statics.userName} onCommit={(v) => setSetting("annotationAuthor", v.trim())} /></Row>
      </Card>
    </>
  );
}

function LibraryPane() {
  const s = useStore((x) => x.settings);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <>
      <Header>{t("文献库位置")}</Header>
      <Card>
        <div className="set-row stack" style={{ display: "block" }}>
          <div className="mono secondary selectable" style={{ fontSize: 12, overflowWrap: "anywhere" }}>{s.libraryPath}</div>
          <div className="ctl" style={{ display: "flex", justifyContent: "flex-end", gap: 8, marginTop: 8, maxWidth: "none" }}>
            {busy && <span className="spinner" />}
            <button className="btn" onClick={() => call("library.revealRoot")}>{t("在资源管理器中显示")}</button>
            <button className="btn" disabled={busy} title={t("选择新的文献库位置，Folio 会把整个文献库移动过去")} onClick={async () => {
              setBusy(true); setError(null);
              try { await call("library.relocate"); } catch (e: any) { setError(t("无法移动文献库：%@", e.message)); }
              setBusy(false);
            }}>{t("更改…")}</button>
            <button className="btn" onClick={async () => {
              const pick = await call<{ folder: string; exists: boolean } | null>("library.pickOther");
              if (!pick) return;
              if (!pick.exists && !(await confirm(t("这个文件夹还不是 Folio 文献库"), t("要在这里新建一个空的文献库吗？"), t("新建文献库")))) return;
              try { await call("library.switch", { folder: pick.folder }); }
              catch (e: any) { dialog({ title: t("无法打开文献库"), message: e.message }); }
            }}>{t("打开其他文献库…")}</button>
          </div>
          {error && <div style={{ color: "var(--red)", fontSize: 12, marginTop: 6 }}>{error}</div>}
        </div>
      </Card>
      <Note>{t("Mac 版 Folio 的文献库文件夹可以直接在这里打开（例如放在同步盘中），两边格式相同。")}</Note>
      <Header>{t("文件")}</Header>
      <Card>
        <Row title={t("检索到元数据后按「作者_年份_标题」重命名文件")}><Switch on={s.autoRenameFiles} onChange={(v) => setSetting("autoRenameFiles", v)} /></Row>
        <Row title={t("自动彻底删除回收站中超过 30 天的内容")}><Switch on={s.autoPurgeTrash} onChange={(v) => setSetting("autoPurgeTrash", v)} /></Row>
      </Card>
      <Header>{t("导入")}</Header>
      <Card><Row title="Zotero" detail={t("导入条目、PDF、分组和标签，不会修改 Zotero")}><button className="btn" onClick={() => openSheet((close) => <ZoteroSheet close={close} />)}>{t("从 Zotero 导入…")}</button></Row></Card>
    </>
  );
}

function Retrieval() {
  const s = useStore((x) => x.settings);
  return (
    <>
      <Card>
        <Row title={t("添加 PDF 后自动检索元数据")}><Switch on={s.autoRetrieveOnImport} onChange={(v) => setSetting("autoRetrieveOnImport", v)} /></Row>
        <Row title={t("使用 Zotero 识别服务")} detail={t("会把 PDF 前 5 页的文字发送给 Zotero，无需账号")}><Switch on={s.useZoteroRecognizer} onChange={(v) => setSetting("useZoteroRecognizer", v)} /></Row>
      </Card>
      <div style={{ height: 12 }} />
      <Card>
        <Row title={t("联系邮箱（选填）")} detail={t("Crossref 会更快地响应带联系邮箱的请求；邮箱只发送给 Crossref 和 OpenAlex")}><Field className="set-field" value={s.crossrefMailto ?? ""} placeholder="name@example.com" onCommit={(v) => setSetting("crossrefMailto", v.trim())} /></Row>
        <Row title={t("OpenAlex API Key（选填）")} detail={t("可在 openalex.org 免费申请，用于提高 OpenAlex 的访问额度")}><Field className="set-field" secret value={s.openAlexAPIKey ?? ""} onCommit={(v) => setSetting("openAlexAPIKey", v.trim())} /></Row>
      </Card>
      <Note>{t("选填，可让检索更快、更稳定\n不填也能正常检索")}</Note>
    </>
  );
}

function Browser() {
  const s = useStore((x) => x.settings);
  const [data, setData] = useState<any>(null);
  const load = () => call("browser.state").then(setData);
  useEffect(() => { load(); return on("connector", (connector) => setData((d: any) => (d ? { ...d, connector } : d))); }, []);
  return (
    <>
      <Card><Row title={t("允许浏览器插件保存到 Folio")}><Switch on={s.browserConnectorEnabled} onChange={(v) => setSetting("browserConnectorEnabled", v)} /></Row></Card>
      {data && <Note>{data.connector.message}</Note>}
      <Header>{t("安装浏览器插件")}</Header>
      <Note>{t("插件会以“已解压的扩展程序”方式加载：点击“安装”后，Folio 准备好插件文件夹并打开浏览器的扩展页面，打开“开发者模式”，选择“加载已解压的扩展程序”，再选中这个文件夹。")}</Note>
      <div style={{ height: 10 }} />
      {data?.browsers.length === 0 && <Note>{t("没有找到支持的浏览器")}</Note>}
      {data?.browsers.length > 0 && <Card>{data.browsers.map((b: any) => <Row key={b.id} title={b.name} detail={b.status}><button className="btn" onClick={() => call("browser.install", { id: b.id })}>{b.installed ? t("更新") : t("安装…")}</button></Row>)}</Card>}
    </>
  );
}

function AgentRow({ agent, refresh }: { agent: any; refresh: () => void }) {
  const [busy, setBusy] = useState(false);
  const run = async (work: () => Promise<unknown>) => {
    setBusy(true);
    try { await work(); }
    catch (e: any) { await dialog({ title: t("无法修改 %@ 的配置", agent.name), message: e.message }); }
    setBusy(false);
    refresh();
  };
  return (
    <div className="agent-row" title={agent.details} onContextMenu={(e) => {
      e.preventDefault();
      if (agent.configPath) openMenu([{ label: t("在资源管理器中显示配置文件"), action: () => call("ai.revealConfig", { path: agent.configPath }) }], e.clientX, e.clientY);
    }}>
      <span className="agent-icon">{agent.name[0]}</span>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div>{agent.name}</div>
        {agent.location && <div className="secondary ellipsis" style={{ fontSize: 11 }}>{agent.version ? `${agent.location} · ${agent.version}` : agent.location}</div>}
        {agent.inline && <div className="secondary" style={{ fontSize: 11, whiteSpace: "pre-line" }}>{agent.inline}</div>}
      </div>
      {busy && <span className="spinner" />}
      <span className="sw">MCP <Switch on={agent.mcp} disabled={busy || !agent.mcpAvailable} onChange={(v) => run(() => call("ai.setMcp", { id: agent.id, on: v }))} /></span>
      <span className="sw" title={agent.skillAvailable ? undefined : agent.skillNote}>{t("技能")} <Switch on={agent.skill} disabled={busy || !agent.skillAvailable} onChange={(v) => run(async () => {
        if (!v) {
          const losing = await call("ai.losingSkill", { id: agent.id });
          if (losing && !(await confirm(losing.title, losing.message, t("移除")))) return;
        }
        await call("ai.setSkill", { id: agent.id, on: v });
      })} /></span>
    </div>
  );
}

function Ai() {
  const s = useStore((x) => x.settings);
  const [info, setInfo] = useState<any>(null);
  const [agents, setAgents] = useState<any[] | null>(null);
  const [detecting, setDetecting] = useState(false);
  const [check, setCheck] = useState<{ message: string; state: string } | null>(null);
  const [checking, setChecking] = useState(false);
  const detect = async (user: boolean) => {
    setDetecting(true);
    if (user) setAgents(null);
    const started = Date.now();
    const result = await call<any[]>("ai.detect");
    // A check that ends in an instant reads as "nothing happened".
    if (user && Date.now() - started < 600) await new Promise((r) => setTimeout(r, 600));
    setAgents(result);
    setDetecting(false);
    if (user) call("toast.show", { message: result.length === 0 ? t("未找到智能体") : t("找到 %lld 个智能体", result.length), icon: "refresh" });
  };
  useEffect(() => { call("ai.info").then(setInfo); detect(false); }, []);
  return (
    <>
      <Header>{t("Folio 的 AI 接口")}</Header>
      <Card>
        <Row title={t("允许 AI 修改文献库")} detail={t("关闭后只能搜索、阅读和引用\nAI 不能彻底删除任何内容")}><Switch on={s.aiAllowWrites} onChange={(v) => setSetting("aiAllowWrites", v)} /></Row>
        <Row title={t("MCP 服务器")} detail={check && <span className={check.state === "ok" ? "status-ok" : check.state === "warn" ? "status-warn" : check.state === "bad" ? "status-bad" : ""}>{check.message}</span>}>
          <button className="btn" disabled={checking} title={t("像智能体一样启动 folio-cli，完成握手并读取文献库")} onClick={async () => {
            setChecking(true);
            setCheck({ message: t("正在检查…"), state: "" });
            try { const r = await call("ai.check"); setCheck({ message: r.message, state: r.ok ? "ok" : "warn" }); }
            catch (e: any) { setCheck({ message: e.message, state: "bad" }); }
            setChecking(false);
          }}>{t("检查")}</button>
        </Row>
        <Row title={t("命令行工具")} detail={info && <span className="mono selectable">{info.cliPath}</span>}><button className="btn" onClick={() => info && call("shell.reveal", { path: info.cliPath })}>{t("在资源管理器中显示")}</button></Row>
      </Card>
      {info && !info.cliExists && <Note><AlertTriangle size={11} /> {t("找不到 folio-cli：%@", info.cliPath)}</Note>}
      <Note>{t("智能体通过 MCP 查找、阅读、引用和整理你的文献\nFolio 技能教它正确地使用")}</Note>
      <Header action={<button className="btn small" disabled={detecting} title={t("重新查找已安装的智能体（安装或卸载后使用）")} onClick={() => detect(true)}><RefreshCw size={12} />{t("重新检测")}</button>}>{t("这台电脑上的智能体")}</Header>
      <Card>
        {agents === null && <div className="set-row"><span className="spinner" /><span className="secondary">{t("正在检测…")}</span></div>}
        {agents?.length === 0 && <div className="set-row"><div><div>{t("没有在这台电脑上找到可用的智能体")}</div><div className="detail">{t("支持 %@\n安装后点\"重新检测\"", info?.catalog ?? "")}</div></div></div>}
        {agents?.map((a) => <AgentRow key={a.id} agent={a} refresh={() => detect(false)} />)}
      </Card>
      <Note>{t("打开开关即按官方方式写入该智能体的配置，关闭即移除，修改前会备份\n重启智能体或开始新会话后生效")}</Note>
      <Header>{t("手动配置")}</Header>
      <Card>
        <Row title={t("其他支持 MCP 的应用")}><button className="btn" onClick={() => call("ai.copyConfig")}>{t("拷贝 MCP 配置")}</button></Row>
        <Row title={t("Folio 技能")} detail={t("用于列表之外的应用，如 VS Code、Zed、Windsurf")}><button className="btn" onClick={() => call("ai.exportFolder")}>{t("导出技能文件夹…")}</button><button className="btn" onClick={() => call("ai.exportZip")}>{t("导出技能包（.zip）…")}</button></Row>
      </Card>
    </>
  );
}

export function SettingsApp() {
  const stored = useStore((s) => s.settings.settingsPane);
  const [pane, setPane] = useState<string>(PANES.some((p) => p.key === stored) ? stored : "general");
  useEffect(() => on("settings.page", (p) => { if (p) setPane(p); }), []);
  useEffect(() => { call("window.caption", { background: getState().dark ? "#1e1e1f" : "#ffffff", foreground: getState().dark ? "#ffffff" : "#000000" }); });
  const title = PANES.find((p) => p.key === pane)?.title ?? "";
  return (
    <div className="settings">
      <div className="settings-nav drag">
        {PANES.map((p) => {
          const Icon = p.icon;
          return <button key={p.key} className={`no-drag${pane === p.key ? " on" : ""}`} onClick={() => { setPane(p.key); setSetting("settingsPane", p.key); }}><Icon size={17} strokeWidth={1.7} />{p.key === "ai" ? "AI" : t(p.title)}</button>;
        })}
      </div>
      <div className="settings-main">
        <div className="settings-title drag">{title === "AI" ? "AI" : t(title)}</div>
        <div className="settings-page" key={pane}>
          {pane === "general" && <General />}
          {pane === "reader" && <Reader />}
          {pane === "library" && <LibraryPane />}
          {pane === "retrieval" && <Retrieval />}
          {pane === "translation" && <TranslationPane />}
          {pane === "browser" && <Browser />}
          {pane === "ai" && <Ai />}
        </div>
      </div>
    </div>
  );
}
