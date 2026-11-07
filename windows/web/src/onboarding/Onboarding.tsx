import { useEffect, useState } from "react";
import { Compass, Languages, Library, Sparkles } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { getState, setSetting, useStore } from "../store";
import { Switch } from "../ui/controls";
import { openSheet } from "../ui/sheet";
import { ZoteroSheet } from "../settings/ZoteroSheet";
import { ServiceSection } from "../settings/TranslationPane";

const STEPS = ["welcome", "zotero", "browser", "agents", "translation"] as const;

function Welcome() {
  const root = useStore((s) => s.settings.libraryPath);
  return (
    <div className="guide-page guide-center">
      <img src="folio.png" width={96} height={96} alt="" />
      <h1>{t("欢迎使用 Folio")}</h1>
      <div className="secondary">{t("轻量的文献管理软件")}</div>
      <div className="secondary" style={{ marginTop: 24, maxWidth: 420 }}>{t("接下来用一分钟完成几项设置，每一步都可以跳过，之后也能在设置中更改。")}</div>
      <div className="secondary mono" style={{ marginTop: 12, fontSize: 12 }}>{t("文献库保存在 %@", root)}</div>
    </div>
  );
}

function ZoteroPage() {
  const [dir, setDir] = useState<string | null | undefined>(undefined);
  useEffect(() => { call("zotero.locate").then(setDir); }, []);
  return (
    <div className="guide-page">
      <Library size={32} color="var(--accent)" />
      <h2>{t("从 Zotero 迁移")}</h2>
      <div className="secondary" style={{ marginBottom: 18 }}>{t("导入条目、PDF、分组和标签，不会修改 Zotero")}</div>
      {dir === undefined && <span className="spinner" />}
      {dir === null && <div className="secondary">{t("未找到 Zotero 数据目录")}</div>}
      {dir && <div className="set-card"><div className="set-row"><div className="main"><div>Zotero</div><div className="detail mono">{dir}</div></div><div className="ctl"><button className="btn primary" onClick={() => openSheet((close) => <ZoteroSheet close={close} />)}>{t("从 Zotero 导入…")}</button></div></div></div>}
    </div>
  );
}

function BrowserPage() {
  const [browsers, setBrowsers] = useState<any[] | null>(null);
  useEffect(() => { call("browser.state").then((d) => setBrowsers(d.browsers)); }, []);
  return (
    <div className="guide-page">
      <Compass size={32} color="var(--accent)" />
      <h2>{t("浏览器插件")}</h2>
      <div className="secondary" style={{ marginBottom: 18 }}>{t("插件会以“已解压的扩展程序”方式加载：点击“安装”后，Folio 准备好插件文件夹并打开浏览器的扩展页面，打开“开发者模式”，选择“加载已解压的扩展程序”，再选中这个文件夹。")}</div>
      {browsers === null && <span className="spinner" />}
      {browsers?.length === 0 && <div className="secondary">{t("没有找到支持的浏览器")}</div>}
      {browsers && browsers.length > 0 && <div className="set-card">{browsers.map((b) => <div key={b.id} className="set-row"><div className="main"><div>{b.name}</div><div className="detail">{b.status}</div></div><div className="ctl"><button className="btn" onClick={() => call("browser.install", { id: b.id })}>{b.installed ? t("更新") : t("安装…")}</button></div></div>)}</div>}
    </div>
  );
}

function AgentsPage() {
  const [agents, setAgents] = useState<any[] | null>(null);
  const allow = useStore((s) => s.settings.aiAllowWrites);
  const load = () => call<any[]>("ai.detect").then(setAgents);
  useEffect(() => { load(); }, []);
  const all = async () => {
    for (const a of agents ?? []) {
      if (a.mcpAvailable && !a.mcp) await call("ai.setMcp", { id: a.id, on: true });
      if (a.skillAvailable && !a.skill) await call("ai.setSkill", { id: a.id, on: true });
    }
    load();
  };
  return (
    <div className="guide-page">
      <Sparkles size={32} color="var(--accent)" />
      <h2>{t("AI 智能体")}</h2>
      <div className="secondary" style={{ marginBottom: 14 }}>{t("智能体通过 MCP 查找、阅读、引用和整理你的文献\nFolio 技能教它正确地使用")}</div>
      {agents === null && <div style={{ display: "flex", gap: 8 }}><span className="spinner" /><span className="secondary">{t("正在检测…")}</span></div>}
      {agents?.length === 0 && <div className="secondary">{t("没有在这台电脑上找到可用的智能体")}</div>}
      {agents && agents.length > 0 && (
        <>
          <div className="set-header" style={{ marginLeft: 0, marginTop: 0 }}>{t("找到 %lld 个智能体", agents.length)}<button className="btn small" style={{ marginLeft: "auto" }} onClick={all}>{t("全部添加")}</button></div>
          <div className="set-card" style={{ maxHeight: 190, overflow: "auto" }}>
            {agents.map((a) => (
              <div key={a.id} className="agent-row">
                <span className="agent-icon">{a.name[0]}</span>
                <div style={{ flex: 1, minWidth: 0 }} className="ellipsis">{a.name}</div>
                <span className="sw">MCP <Switch on={a.mcp} disabled={!a.mcpAvailable} onChange={(v) => call("ai.setMcp", { id: a.id, on: v }).then(load)} /></span>
                <span className="sw">{t("技能")} <Switch on={a.skill} disabled={!a.skillAvailable} onChange={(v) => call("ai.setSkill", { id: a.id, on: v }).then(load)} /></span>
              </div>
            ))}
          </div>
        </>
      )}
      <div className="set-card" style={{ marginTop: 12 }}><div className="set-row"><div className="main"><div>{t("允许 AI 修改文献库")}</div><div className="detail">{t("关闭后只能搜索、阅读和引用\nAI 不能彻底删除任何内容")}</div></div><div className="ctl"><Switch on={allow} onChange={(v) => setSetting("aiAllowWrites", v)} /></div></div></div>
    </div>
  );
}

function TranslationPage() {
  return (
    <div className="guide-page">
      <Languages size={32} color="var(--accent)" />
      <h2>{t("整篇翻译")}</h2>
      <div className="secondary" style={{ marginBottom: 14 }}>{t("保留原文排版、公式和图表，翻译时就可以对照阅读\n译文会作为新文件加入该条目")}</div>
      <ServiceSection compact />
    </div>
  );
}

export function Onboarding() {
  const [step, setStep] = useState(0);
  useEffect(() => { const d = getState().dark; call("window.caption", { background: d ? "#1e1e1f" : "#ffffff", foreground: d ? "#ffffff" : "#000000" }); });
  const finish = () => call("app.onboardingDone");
  const name = STEPS[step];
  return (
    <div className="guide">
      <div className="drag" style={{ height: 40, position: "absolute", left: 0, right: 60, top: 0 }} />
      {name === "welcome" && <Welcome />}
      {name === "zotero" && <ZoteroPage />}
      {name === "browser" && <BrowserPage />}
      {name === "agents" && <AgentsPage />}
      {name === "translation" && <TranslationPage />}
      <div className="guide-bar">
        <div style={{ width: 150 }}>{step === 0 ? <button className="btn" onClick={finish}>{t("跳过设置")}</button> : <button className="btn" onClick={() => setStep(step - 1)}>{t("返回")}</button>}</div>
        <div className="dots">{STEPS.map((s, i) => <i key={s} className={i === step ? "on" : ""} />)}</div>
        <div style={{ width: 150, textAlign: "right" }}>
          {step === 0 && <button className="btn primary" onClick={() => setStep(1)}>{t("开始设置")}</button>}
          {step > 0 && step < STEPS.length - 1 && <button className="btn primary" onClick={() => setStep(step + 1)}>{t("继续")}</button>}
          {step === STEPS.length - 1 && <button className="btn primary" onClick={finish}>{t("开始使用")}</button>}
        </div>
      </div>
    </div>
  );
}
