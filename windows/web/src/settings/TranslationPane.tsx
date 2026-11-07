import { useEffect, useState } from "react";
import { AlertTriangle, CheckCircle2, ChevronDown } from "lucide-react";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { getState, type FileRec } from "../store";
import { Field, Select, Switch } from "../ui/controls";
import { askText, confirm, Sheet } from "../ui/sheet";
import { openMenuAt } from "../ui/menu";
import { Card, Header, Note, Row } from "./parts";

interface Detail { id: string; name: string; note?: string; category: string; isAgent: boolean; supportsProfiles: boolean; profiles: { id: string; name: string }[]; selectedProfile?: string; fields: FieldDef[]; advanced: FieldDef[]; reasoning?: any }
interface FieldDef { option: string; title: string; kind: string; placeholder: string; value: string; models: boolean; remembered?: string[] }

function FieldRow({ service, field, onDetail }: { service: string; field: FieldDef; onDetail: (d: Detail) => void }) {
  if (field.kind === "toggle") {
    return <Row title={field.title}><Switch on={field.value === "true"} onChange={(on) => call("translation.setField", { service, option: field.option, value: on ? "true" : "" }).then(onDetail)} /></Row>;
  }
  if (field.kind === "secret") {
    return <Row title={field.title}><Field className="set-field" secret value={field.value} placeholder={field.placeholder} onCommit={(value) => call("translation.setSecret", { service, option: field.option, value })} /></Row>;
  }
  if (field.models) return <ModelRow service={service} field={field} onDetail={onDetail} />;
  return <Row title={field.title}><Field className="set-field" value={field.value} placeholder={field.placeholder} onCommit={(value) => call("translation.setField", { service, option: field.option, value }).then(onDetail)} /></Row>;
}

/** The model: typed, or picked from the whole list the service offers (a combo box, as on macOS: the list is never
 *  narrowed to what the box already holds). */
function ModelRow({ service, field, onDetail }: { service: string; field: FieldDef; onDetail: (d: Detail) => void }) {
  const [models, setModels] = useState<string[]>(field.remembered ?? []);
  const [status, setStatus] = useState("");
  const fetchModels = async (): Promise<string[]> => {
    setStatus(t("正在获取模型列表…"));
    try { const list: string[] = await call("translation.fetchModels", { service }); setModels(list); setStatus(""); return list; }
    catch (e: any) { setStatus(e.message); return []; }
  };
  const choose = (value: string) => { if (value !== field.value) call("translation.setField", { service, option: field.option, value }).then(onDetail); };
  const showList = async (anchor: HTMLElement) => {
    const list = models.length ? models : await fetchModels();
    if (!list.length) return;
    openMenuAt(anchor, [...new Set(list)].map((m) => ({ label: m, checked: m === field.value, action: () => choose(m) })));
  };
  return (
    <Row title={field.title} detail={status || undefined}>
      <div style={{ width: 280, display: "flex", gap: 6 }}>
        <div className="combo">
          <input className="field" defaultValue={field.value} key={field.value} placeholder={field.placeholder} spellCheck={false}
            onBlur={(e) => choose(e.target.value.trim())}
            onKeyDown={(e) => {
              e.stopPropagation();
              if (e.key === "Enter") e.currentTarget.blur();
              if (e.key === "ArrowDown" && e.altKey) showList(e.currentTarget.parentElement as HTMLElement);
            }} />
          <button className="combo-arrow" title={t("模型")} onMouseDown={(e) => e.preventDefault()}
            onClick={(e) => showList(e.currentTarget.parentElement as HTMLElement)}><ChevronDown size={13} /></button>
        </div>
        <button className="btn" onClick={() => fetchModels()} title={t("刷新")}>↻</button>
      </div>
    </Row>
  );
}

function StatusRow({ detail, canTest }: { detail: Detail; canTest: boolean }) {
  const [state, setState] = useState<{ message: string; icon?: "ok" | "warn"; busy?: boolean }>({ message: t("翻译一句话，确认这个服务能用") });
  const [testing, setTesting] = useState(false);
  useEffect(() => {
    let live = true;
    if (detail.isAgent) {
      setState({ message: "", busy: true });
      call("translation.status", { service: detail.id }).then((r) => { if (live && r) setState({ message: r.message, icon: r.ok ? "ok" : "warn" }); });
    } else setState({ message: t("翻译一句话，确认这个服务能用") });
    return () => { live = false; };
  }, [detail.id]);
  return (
    <div className="set-row">
      <div className="main selectable" style={{ display: "flex", gap: 8, alignItems: "center", overflowWrap: "anywhere" }}>
        {state.busy && <span className="spinner" />}
        {state.icon === "ok" && <CheckCircle2 size={14} color="var(--green)" style={{ flex: "none" }} />}
        {state.icon === "warn" && <AlertTriangle size={14} color="var(--orange)" style={{ flex: "none" }} />}
        <span>{state.message}</span>
      </div>
      {canTest && <div className="ctl"><button className="btn" disabled={testing} onClick={async () => {
        setTesting(true);
        setState({ message: t("正在翻译一句话…"), busy: true });
        try { const r = await call("translation.test", { service: detail.id }); setState({ message: r.message, icon: r.ok ? "ok" : "warn" }); }
        catch (e: any) { setState({ message: e.message, icon: "warn" }); }
        setTesting(false);
      }}>{testing ? t("测试中…") : t("测试")}</button></div>}
    </div>
  );
}

export function ServiceSection({ compact }: { compact: boolean }) {
  const [data, setData] = useState<any>(null);
  const [detail, setDetail] = useState<Detail | null>(null);
  const [advanced, setAdvanced] = useState(false);
  const load = async () => {
    const d = await call("translation.services");
    setData(d);
    setDetail(d.detail);
  };
  useEffect(() => { load(); return on("translation.servicesChanged", load); }, []);
  if (!data || !detail) return <div className="set-card"><div className="set-row"><span className="spinner" /></div></div>;
  const groups: any[] = data.groups;
  const reasoning = detail.reasoning;
  const profileValue = detail.selectedProfile ?? "";
  return (
    <>
      <div className="set-card">
        <Row title={t("翻译服务")}>
          <select className="select" value={detail.id} onChange={async (e) => { setDetail(await call("translation.setService", { id: e.target.value })); load(); }}>
            {groups.map((g) => <optgroup key={g.title} label={g.title}>{g.services.map((s: any) => <option key={s.id} value={s.id}>{s.label}</option>)}</optgroup>)}
          </select>
        </Row>
        {detail.supportsProfiles && (
          <Row title={t("配置")}>
            <Select value={profileValue} options={[{ value: "", label: t("未保存为配置") }, ...detail.profiles.map((p) => ({ value: p.id, label: p.name }))]} onChange={async (v) => { setDetail(await call("translation.selectProfile", { service: detail.id, profile: v })); }} />
            <button className="btn" onClick={async () => {
              const suggested = await call<string>("translation.suggestProfileName", { service: detail.id });
              const name = await askText(t("保存为配置"), t("配置名称"), suggested, t("保存"));
              if (name?.trim()) setDetail(await call("translation.saveProfile", { service: detail.id, name }));
            }}>{t("存为配置…")}</button>
            {profileValue && <button className="btn" onClick={async () => {
              const p = detail.profiles.find((x) => x.id === profileValue);
              if (p && await confirm(t("删除配置“%@”？", p.name), t("会删除这个配置保存的地址、模型和 Key。"), t("删除"), true)) setDetail(await call("translation.deleteProfile", { service: detail.id, profile: p.id }));
            }}>{t("删除")}</button>}
          </Row>
        )}
        {detail.fields.map((f) => <FieldRow key={detail.id + f.option + (detail.selectedProfile ?? "")} service={detail.id} field={f} onDetail={setDetail} />)}
        {reasoning?.kind === "choices" && (
          <Row title={reasoning.title}><Select value={reasoning.current} options={reasoning.choices.map((c: any) => ({ value: c.value, label: c.title }))} onChange={async (v) => setDetail(await call("translation.setReasoning", { service: detail.id, value: v }))} /></Row>
        )}
        {(detail.isAgent || (!compact && detail.category !== "free")) && <StatusRow detail={detail} canTest={!compact} />}
        {!compact && detail.advanced.length > 0 && (
          <div className="set-row stack" style={{ display: "block" }}>
            <button className="disclose-head" onClick={() => setAdvanced(!advanced)}>{advanced ? "▾" : "▸"} {t("高级")}</button>
            {advanced && detail.advanced.map((f) => <FieldRow key={f.option} service={detail.id} field={f} onDetail={setDetail} />)}
          </div>
        )}
      </div>
      {detail.note && <Note>{detail.note}</Note>}
      {reasoning?.kind === "decided" && <Note>{reasoning.note}</Note>}
    </>
  );
}

export function OptionsSection({ compact }: { compact: boolean }) {
  const [data, setData] = useState<any>(null);
  useEffect(() => { call("translation.services").then(setData); }, []);
  if (!data) return null;
  const o = data.options;
  const languages = data.languages.map((l: any) => ({ value: l.code, label: l.name }));
  const update = (patch: Record<string, unknown>) => {
    const options = { ...o, ...patch };
    setData({ ...data, options });
    call("translation.setOptions", { options });
  };
  return (
    <>
      <Header>{compact ? t("选项") : t("语言")}</Header>
      <Card>
        <Row title={t("原文语言")}><Select value={o.langIn} options={languages} onChange={(v) => update({ langIn: v })} /></Row>
        <Row title={t("译文语言")}><Select value={o.langOut} options={languages} onChange={(v) => update({ langOut: v })} /></Row>
        {compact && <OutputRows o={o} update={update} compact />}
      </Card>
      {!compact && <>
        <Header>{t("输出")}</Header>
        <Card><OutputRows o={o} update={update} compact={false} /></Card>
        <Note>{t("同一服务和模型再翻译一次时；保留两者时按翻译时间区分，替换的旧译文会移到回收站")}</Note>
        <Header>{t("翻译内容")}</Header>
        <Card>
          <Row title={t("翻译表格")} detail={t("逐格翻译表格中的文字；数字和符号保持原样")}><Switch on={o.translateTables} onChange={(v) => update({ translateTables: v })} /></Row>
          <Row title={t("翻译参考文献")} detail={t("默认保留参考文献列表的原文")}><Switch on={o.translateReferences} onChange={(v) => update({ translateReferences: v })} /></Row>
          <Row title={t("术语表（选填）")} detail={t("CSV 文件，两列：原文, 译文")}>
            <span className="secondary ellipsis" style={{ maxWidth: 160 }}>{o.glossaryFile ? o.glossaryFile.split(/[\\/]/).pop() : t("未选择")}</span>
            {o.glossaryFile && <button className="btn" onClick={() => update({ glossaryFile: null })}>{t("清除")}</button>}
            <button className="btn" onClick={async () => { const path = await call<string | null>("translation.pickGlossary"); if (path) setData({ ...data, options: { ...o, glossaryFile: path } }); }}>{t("选择…")}</button>
          </Row>
        </Card>
        <Header>{t("速度")}</Header>
        <Card>
          <Row title={t("同时请求数")} detail={t("付费接口额度较高时调大可以更快；遇到限流时调小")}><Select value={o.concurrency ?? 0} options={[0, 1, 2, 4, 8, 12, 16].map((n) => ({ value: n, label: n === 0 ? t("自动") : String(n) }))} onChange={(v) => update({ concurrency: v === 0 ? null : v })} /></Row>
          <Row title={t("重新翻译（不使用缓存）")} detail={t("默认会复用同一篇论文用同一服务翻译过的段落，重试时更快、更省")}><Switch on={o.ignoreCache} onChange={(v) => update({ ignoreCache: v })} /></Row>
        </Card>
      </>}
    </>
  );
}

function OutputRows({ o, update, compact }: { o: any; update: (p: Record<string, unknown>) => void; compact: boolean }) {
  return (
    <>
      <Row title={t("生成")}><Select value={o.outputs} options={[{ value: "both", label: t("纯译文和双语对照") }, { value: "mono", label: t("仅纯译文") }, { value: "dual", label: t("仅双语对照") }]} onChange={(v) => update({ outputs: v })} /></Row>
      {o.outputs !== "mono" && <Row title={t("双语排版")}><Select value={o.dualLayout} options={[{ value: "sideBySide", label: t("原文与译文左右并排") }, { value: "alternatingPages", label: t("原文页与译文页交替") }]} onChange={(v) => update({ dualLayout: v })} /></Row>}
      {!compact && <Row title={t("再次翻译")}><Select value={o.duplicates} options={[{ value: "keepBoth", label: t("保留两者") }, { value: "replace", label: t("替换旧的译文") }]} onChange={(v) => update({ duplicates: v })} /></Row>}
      <Row title={t("页码范围（选填）")}><Field className="set-field" value={o.pages ?? ""} placeholder={t("全部，例如 1-3,5")} onCommit={(v) => update({ pages: v.trim() || null })} /></Row>
      {compact && <Row title={t("翻译表格")}><Switch on={o.translateTables} onChange={(v) => update({ translateTables: v })} /></Row>}
    </>
  );
}

export function TranslationPane() {
  return (
    <>
      <ServiceSection compact={false} />
      <OptionsSection compact={false} />
      <Header>{t("翻译引擎")}</Header>
      <Card><Row title={t("翻译日志")}><button className="btn" onClick={() => call("translation.revealLogs")}>{t("在资源管理器中显示")}</button></Row></Card>
      <Note>{t("Folio 内置的翻译引擎直接解析 PDF 版面并按原样排入译文，图表内文字和公式保持原样，无需下载任何组件")}</Note>
    </>
  );
}

/** "翻译…": confirm service, languages and outputs for this run (they become the new defaults). */
export function TranslateSheet({ files, close }: { files: FileRec[]; close: () => void }) {
  const s = getState();
  const title = files.length > 1 ? t("%lld 篇文献", files.length) : s.items.get(files[0].itemId)?.title ?? files[0].fileName;
  return (
    <Sheet title={t("翻译全文")} width={540} onEscape={close} actions={
      <>
        <button className="btn" onClick={close}>{t("取消")}</button>
        <button className="btn primary" onClick={() => { close(); call("translation.start", { files: files.map((f) => f.id) }); }}>{t("开始翻译")}</button>
      </>}>
      <div className="secondary ellipsis" title={title} style={{ marginBottom: 8 }}>{title}</div>
      <div className="body" style={{ maxHeight: "60vh" }}>
        <ServiceSection compact />
        <OptionsSection compact />
        <Note>{t("保留原文排版、公式和图表，翻译时就可以对照阅读\n译文会作为新文件加入该条目")}</Note>
      </div>
    </Sheet>
  );
}
