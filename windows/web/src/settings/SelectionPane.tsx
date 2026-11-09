import { useEffect, useState } from "react";
import { ChevronDown } from "lucide-react";
import { call, on } from "../rpc";
import { t } from "../i18n";
import { setSetting, useStore } from "../store";
import { Select, Switch } from "../ui/controls";
import { openMenuAt, sep, type MenuEntry } from "../ui/menu";
import { ServiceLogo } from "../ui/serviceLogo";
import { Card, Header, Row } from "./parts";
import { ShortcutRecorder } from "./TranslationPane";

/** 设置 ▸ 划词翻译: a selection in the reader translated in a popover, by its own service. */
export function SelectionTranslationPane() {
  const s = useStore((x) => x.settings);
  const [services, setServices] = useState<{ id: string; name: string }[]>([]);
  useEffect(() => {
    const load = () => call("translation.selectionServices").then((i) => setServices(i.services)).catch(() => {});
    load();
    return on("translation.servicesChanged", load);
  }, []);
  const enabled = s.selectionTranslationEnabled !== false;
  const chosen = s.selectionTranslationService ?? "";
  const shown = chosen || s.translationService || "";
  const name = chosen ? services.find((x) => x.id === chosen)?.name ?? chosen : t("与全文翻译相同");
  const pick = (el: HTMLElement) => openMenuAt(el, [
    { label: t("与全文翻译相同"), checked: !chosen, action: () => setSetting("selectionTranslationService", "") },
    sep,
    ...services.map((x) => ({ label: x.name, icon: <ServiceLogo id={x.id} />, checked: x.id === chosen, action: () => setSetting("selectionTranslationService", x.id) }) as MenuEntry),
  ]);
  return (
    <>
      <Card><Row title={t("划词翻译")}><Switch on={enabled} onChange={(v) => setSetting("selectionTranslationEnabled", v)} /></Row></Card>
      <div className={enabled ? undefined : "set-disabled"}>
        <Header>{t("使用")}</Header>
        <Card>
          <Row title={t("触发方式")}><Select value={s.selectionTranslationTrigger ?? "button"} options={[
            { value: "button", label: t("选中后显示翻译按钮") }, { value: "automatic", label: t("选中后自动翻译") }, { value: "shortcut", label: t("仅使用快捷键") },
          ]} onChange={(v) => setSetting("selectionTranslationTrigger", v)} /></Row>
          <Row title={t("快捷键")}><ShortcutRecorder value={s.selectionTranslationShortcut || "Alt+D"} onChange={(v) => setSetting("selectionTranslationShortcut", v)} /></Row>
        </Card>
        <Header>{t("服务")}</Header>
        <Card>
          <Row title={t("翻译服务")}>
            <button className="btn service-picker" onClick={(e) => pick(e.currentTarget)}><ServiceLogo id={shown} size={17} /><span className="label">{name}</span><ChevronDown size={13} className="secondary" /></button>
          </Row>
          <Row title={t("限流时自动换用其他免费服务")} detail={t("Google、Microsoft 互为备用")}><Switch on={s.selectionTranslationFallback !== false} onChange={(v) => setSetting("selectionTranslationFallback", v)} /></Row>
        </Card>
      </div>
    </>
  );
}
