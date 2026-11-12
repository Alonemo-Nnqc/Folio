import { useEffect, useState } from "react";
import { AlertTriangle, CheckCircle2, ScanText, TerminalSquare, BookOpen, Compass, Languages, Library, RefreshCw, Search, Settings as Gear, Sparkles } from "lucide-react";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { getState, setSetting, setState, useStore } from "../store";
import { Field, Select, Slider, Switch } from "../ui/controls";
import { confirm, dialog, openSheet } from "../ui/sheet";
import { openMenu } from "../ui/menu";
import { ServiceLogo } from "../ui/serviceLogo";
import { Card, Header, Note, Row } from "./parts";
import { TranslationPane } from "./TranslationPane";
import { SelectionTranslationPane } from "./SelectionPane";
import { setCaption } from "../ui/caption";
import { ZoteroSheet } from "./ZoteroSheet";

const PANES = [
  { key: "general", title: "通用", icon: Gear }, { key: "reader", title: "阅读", icon: BookOpen },
  { key: "library", title: "文献库", icon: Library }, { key: "retrieval", title: "检索", icon: Search },
  { key: "translation", title: "翻译", icon: Languages }, { key: "selection", title: "划词翻译", icon: ScanText },
  { key: "browser", title: "浏览器", icon: Compass }, { key: "ai", title: "AI", icon: Sparkles },
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

let pendingTranslucency = 0;
let translucencyFrame = 0;
function Translucency() {
  const stored = useStore((x) => x.settings.backgroundTranslucency ?? 0);
  const supported = useStore((x) => x.statics.translucency);
  if (!supported) return null;
  // Every window follows while the slider moves (one change per frame).
  const change = (v: number) => {
    pendingTranslucency = v;
    if (!translucencyFrame) translucencyFrame = requestAnimationFrame(() => { translucencyFrame = 0; setSetting("backgroundTranslucency", pendingTranslucency); });
  };
  return (
    <Row title={t("背景透明度")}>
      <span className="slider-end opaque" />
      <Slider label={t("背景透明度")} value={stored} onChange={change} onCommit={change} />
      <span className="slider-end clear" />
    </Row>
  );
}

function General() {
  const s = useStore((x) => x.settings);
  const statics = useStore((x) => x.statics);
  launchedLanguage ??= s.language ?? "";
  return (
    <>
      <Header>{t("外观")}</Header>
      <Card><Appearance /><Translucency /></Card>
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
        <Row title={t("自动下载更新")}><Switch on={s.autoDownloadUpdates} disabled={!s.autoCheckUpdates} onChange={(v) => setSetting("autoDownloadUpdates", v)} /></Row>
        <Row title={t("接收测试版")}><Switch on={s.updatePrereleases} onChange={(v) => setSetting("updatePrereleases", v)} /></Row>
      </Card>
      <Header>{t("帮助")}</Header>
      <Card>
        <Row title={t("欢迎使用 Folio…")}><button className="btn" onClick={() => call("window.onboarding")}>{t("打开")}</button></Row>
        <Row title={t("Folio 主页")}><button className="btn" onClick={() => call("shell.open", { target: "https://alonemo-nnqc.github.io/Folio/" })}>{t("打开")}</button><button className="btn" onClick={() => call("shell.open", { target: "https://github.com/Alonemo-Nnqc/Folio/issues" })}>{t("报告问题…")}</button></Row>
      </Card>
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
      <Note>{t("可直接打开 Mac 版的文献库文件夹，两端格式相同")}</Note>
      <Header>{t("文件")}</Header>
      <Card>
        <Row title={t("检索到元数据后按「作者_年份_标题」重命名文件")}><Switch on={s.autoRenameFiles} onChange={(v) => setSetting("autoRenameFiles", v)} /></Row>
        <Row title={t("自动彻底删除回收站中超过 30 天的内容")}><Switch on={s.autoPurgeTrash} onChange={(v) => setSetting("autoPurgeTrash", v)} /></Row>
      </Card>
      <Header>{t("导入")}</Header>
      <Card><Row title="Zotero" detail={t("不会改动 Zotero 数据")}><button className="btn" onClick={() => openSheet((close) => <ZoteroSheet close={close} />)}>{t("从 Zotero 导入…")}</button></Row></Card>
    </>
  );
}

function Retrieval() {
  const s = useStore((x) => x.settings);
  return (
    <>
      <Card>
        <Row title={t("添加 PDF 后自动检索元数据")}><Switch on={s.autoRetrieveOnImport} onChange={(v) => setSetting("autoRetrieveOnImport", v)} /></Row>
        <Row title={t("使用 Zotero 识别服务")} detail={t("将发送 PDF 前 5 页文字，无需账号")}><Switch on={s.useZoteroRecognizer} onChange={(v) => setSetting("useZoteroRecognizer", v)} /></Row>
      </Card>
      <div style={{ height: 12 }} />
      <Card>
        <Row title={t("联系邮箱（选填）")}><Field className="set-field" value={s.crossrefMailto ?? ""} placeholder="name@example.com" onCommit={(v) => setSetting("crossrefMailto", v.trim())} /></Row>
        <Row title={t("OpenAlex API Key（选填）")}><Field className="set-field" secret value={s.openAlexAPIKey ?? ""} onCommit={(v) => setSetting("openAlexAPIKey", v.trim())} /></Row>
      </Card>
      <JournalMetricsSection />
    </>
  );
}

/** 期刊指标 (META-30): the easyScholar key, a test, and whether ranks are fetched by themselves. */
function JournalMetricsSection() {
  const state = useStore((x) => x.journalMetrics);
  const [draft, setDraft] = useState<string | null>(null);
  const [test, setTest] = useState<{ busy: boolean; ok?: boolean; text?: string }>({ busy: false });
  useEffect(() => { call("journalMetrics.state").then((journalMetrics) => setState({ journalMetrics })); }, []);
  if (!state) return null;
  const key = draft ?? state.key;
  const save = (value: string) => { setDraft(null); setTest({ busy: false }); call("journalMetrics.setKey", { key: value }).then((journalMetrics) => setState({ journalMetrics })); };
  const run = async () => {
    setTest({ busy: true });
    const r = await call<{ ok: boolean; text: string }>("journalMetrics.test", { key }).catch((e) => ({ ok: false, text: String(e.message ?? e) }));
    setTest({ busy: false, ...r });
    if (r.ok && key.trim() !== state.key) save(key);
  };
  const line = test.text ? { ok: !!test.ok, text: test.text } : state.hasKey && state.status ? { ok: !state.attention, text: state.status, progress: !state.attention } : null;
  return (
    <>
      <Header>{t("期刊指标")}</Header>
      <Card>
        <Row title={t("自动获取期刊分区与影响因子")} detail={t("为有期刊名的条目获取中科院分区、JCR 分区和影响因子，同一期刊只查询一次并缓存 30 天")}>
          <Switch on={state.autoFetch} onChange={(on) => call("journalMetrics.setAutoFetch", { on }).then((journalMetrics) => setState({ journalMetrics }))} />
        </Row>
        <Row title={t("easyScholar 密钥")} detail={<button className="link-button" onClick={() => call("shell.open", { target: state.keyPage })}>{t("如何获取密钥…")}</button>}>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <input className="field set-field" type="password" value={key} placeholder="SecretKey" spellCheck={false} autoComplete="off"
              onChange={(e) => setDraft(e.target.value)} onBlur={() => { if (draft !== null) save(draft); }}
              onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
            <button className="btn" style={{ minWidth: 56 }} disabled={test.busy || !key.trim()} title={t("用该密钥查询一次 Nature 的指标")} onClick={run}>
              {test.busy ? <span className="spinner" /> : t("测试")}
            </button>
          </div>
        </Row>
        {line && (
          <div className="jm-status">
            {"progress" in line && line.progress ? <span className="spinner" /> : line.ok ? <CheckCircle2 size={14} color="var(--green)" /> : <AlertTriangle size={14} color="var(--orange)" />}
            <span className="selectable">{line.text}</span>
          </div>
        )}
      </Card>
      <Note>{t("数据由 easyScholar 开放接口免费提供：登录 easyScholar 后，在“开放接口”页面复制 SecretKey。密钥加密保存在本机。")}</Note>
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
      <Note>{t("点击“安装”后，在浏览器扩展页面开启“开发者模式”，选择“加载已解压的扩展程序”并选中 Folio 打开的文件夹")}</Note>
      <div style={{ height: 10 }} />
      {data?.browsers.length === 0 && <Note>{t("没有找到支持的浏览器")}</Note>}
      {data?.browsers.length > 0 && <Card>{data.browsers.map((b: any) => <Row key={b.id} title={b.name} detail={b.status}><button className="btn" onClick={() => call("browser.install", { id: b.id })}>{b.installed ? t("更新") : t("安装…")}</button></Row>)}</Card>}
    </>
  );
}

/** The agent's official logo on an app-icon-like tile, as in the macOS app. Marks drawn in one colour follow the theme. */
const LOGOS: Record<string, "fill" | "mark" | "template"> = {
  codex: "fill", "gemini-cli": "fill", kiro: "fill", "claude-code": "mark", "claude-desktop": "mark", antigravity: "mark", "qwen-code": "mark",
  cline: "template", "copilot-cli": "template", cursor: "template", opencode: "template",
};
/** Agents that are translation services too: the service's logo. */
const SERVICE_LOGOS: Record<string, string> = {
  pi: "picli", grok: "grokcli", hermes: "hermesagent", openclaw: "openclawagent", kimi: "kimicli", amp: "ampcli", goose: "gooseagent", deepseek: "deepseekharness",
};
function AgentLogo({ id, name }: { id: string; name: string }) {
  const kind = LOGOS[id];
  const file = `agents/${id === "claude-desktop" ? "claude-code" : id}.png`;
  return (
    <span className={`agent-icon${kind ? ` logo-${kind}` : ""}`} aria-hidden>
      {kind === "fill" || kind === "mark" ? <img src={file} alt="" draggable={false} />
        : kind === "template" ? <i style={{ WebkitMaskImage: `url(${file})`, maskImage: `url(${file})` }} />
        : SERVICE_LOGOS[id] ? <ServiceLogo id={SERVICE_LOGOS[id]} size={18} />
        : <TerminalSquare size={15} strokeWidth={1.7} />}
      <span className="sr-only">{name}</span>
    </span>
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
      <AgentLogo id={agent.id} name={agent.name} />
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
        <Row title={t("允许 AI 修改文献库")} detail={t("关闭后仅可检索、阅读与引用")}><Switch on={s.aiAllowWrites} onChange={(v) => setSetting("aiAllowWrites", v)} /></Row>
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
      <Header action={<button className="btn small" disabled={detecting} title={t("重新查找已安装的智能体（安装或卸载后使用）")} onClick={() => detect(true)}><RefreshCw size={12} />{t("重新检测")}</button>}>{t("这台电脑上的智能体")}</Header>
      <Card>
        {agents === null && <div className="set-row"><span className="spinner" /><span className="secondary">{t("正在检测…")}</span></div>}
        {agents?.length === 0 && <div className="set-row"><div><div>{t("没有在这台电脑上找到可用的智能体")}</div><div className="detail">{t("支持 %@\n安装后点\"重新检测\"", info?.catalog ?? "")}</div></div></div>}
        {agents?.map((a) => <AgentRow key={a.id} agent={a} refresh={() => detect(false)} />)}
      </Card>
      <Note>{t("开关会写入或移除该智能体的配置（修改前自动备份），重启智能体后生效")}</Note>
      <Header>{t("手动配置")}</Header>
      <Card>
        <Row title={t("其他支持 MCP 的应用")}><button className="btn" onClick={() => call("ai.copyConfig")}>{t("拷贝 MCP 配置")}</button></Row>
        <Row title={t("Folio 技能")} detail={t("适用于 VS Code、Zed、Windsurf 等")}><button className="btn" onClick={() => call("ai.exportFolder")}>{t("导出技能文件夹…")}</button><button className="btn" onClick={() => call("ai.exportZip")}>{t("导出技能包（.zip）…")}</button></Row>
      </Card>
    </>
  );
}

export function SettingsApp() {
  const stored = useStore((s) => s.settings.settingsPane);
  const [pane, setPane] = useState<string>(PANES.some((p) => p.key === stored) ? stored : "general");
  useEffect(() => on("settings.page", (p) => { if (p) setPane(p); }), []);
  useEffect(() => { setCaption(getState().dark ? "#1c1c1e" : "#f4f4f6", getState().dark ? "#ffffff" : "#000000"); });
  const title = PANES.find((p) => p.key === pane)?.title ?? "";
  return (
    <div className="settings">
      <div className="settings-nav drag">
        {PANES.map((p) => {
          const Icon = p.icon;
          return (
            <button key={p.key} className={`no-drag${pane === p.key ? " on" : ""}`} onClick={() => { setPane(p.key); setSetting("settingsPane", p.key); }}>
              <Icon size={17} strokeWidth={1.7} />{p.key === "ai" ? "AI" : t(p.title)}
            </button>
          );
        })}
      </div>
      <div className="settings-main">
        <div className="settings-title drag" />
        <div className="settings-page" key={pane}>
          <h1 className="settings-heading">{title === "AI" ? "AI" : t(title)}</h1>
          {pane === "general" && <General />}
          {pane === "reader" && <Reader />}
          {pane === "library" && <LibraryPane />}
          {pane === "retrieval" && <Retrieval />}
          {pane === "translation" && <TranslationPane />}
          {pane === "selection" && <SelectionTranslationPane />}
          {pane === "browser" && <Browser />}
          {pane === "ai" && <Ai />}
        </div>
      </div>
    </div>
  );
}
