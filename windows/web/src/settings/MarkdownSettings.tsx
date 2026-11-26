import { useMemo } from "react";
import { t } from "../i18n";
import { useStore } from "../store";
import { Select, Slider, Switch } from "../ui/controls";
import { FACES, WIDTHS } from "../notes/MarkdownTools";
import { MarkdownEditor } from "../notes/markdown";
import { MD, mdOf, setMd, type MdKey } from "../notes/prefs";
import { Card, Header, Row } from "./parts";

/** 设置 ▸ Markdown, as on the Mac (MarkdownPreferences.swift). */
export function MarkdownSettings() {
  const s = useStore((x) => x.settings);
  const number = (key: MdKey) => mdOf(s, key) as number;
  const source = useMemo(() => ({
    key: "sample", save: () => {},
    load: async () => t("## 阅读笔记\n行高和段落间距决定读起来是否舒服。中英文混排时，**重点**、`code` 和 [链接](https://example.com) 都在同一行里。\n> 引用的一句话\n- 第一项\n- 第二项"),
  }), []);
  const slide = (title: string, key: MdKey, min: number, max: number, step: number, show: (v: number) => string) => (
    <Row title={title}>
      <Slider label={title} value={number(key)} min={min} max={max} step={step} onChange={(v) => setMd(key, v)} onCommit={(v) => setMd(key, v)} />
      <span className="secondary tabular md-value">{show(number(key))}</span>
    </Row>
  );
  const toggle = (title: string, key: MdKey) => <Row title={title}><Switch title={title} on={mdOf(s, key) as boolean} onChange={(v) => setMd(key, v)} /></Row>;
  const px = (v: number) => `${v} px`, percent = (v: number) => `${Math.round(v * 100)}%`;
  const keys = Object.keys(MD) as MdKey[], changed = keys.some((k) => k !== "markdownToolbar" && mdOf(s, k) !== MD[k]);
  return (
    <>
      <div className="set-card md-sample"><MarkdownEditor source={source} placeholder="" readOnly panel={false} /></div>
      <Header>{t("文字")}</Header>
      <Card>
        {slide(t("文档字号"), "markdownFontSize", 10, 32, 0.5, px)}
        {slide(t("侧栏字号"), "markdownPanelFontSize", 10, 24, 0.5, px)}
        <Row title={t("字体")}><Select value={mdOf(s, "markdownTypeface")} options={FACES().map(([value, label]) => ({ value, label }))} onChange={(v) => setMd("markdownTypeface", v)} /></Row>
        {slide(t("标题大小"), "markdownHeadingScale", 0.8, 1.4, 0.05, percent)}
        {slide(t("代码字号"), "markdownCodeScale", 0.75, 1.1, 0.05, percent)}
      </Card>
      <Header>{t("间距")}</Header>
      <Card>
        {slide(t("行高"), "markdownLineHeight", 1.2, 2.4, 0.05, (v) => v.toFixed(2))}
        {slide(t("段落间距"), "markdownParagraphSpacing", 0, 1.5, 0.1, (v) => v.toFixed(1))}
        <Row title={t("文档宽度")}><Select value={number("markdownReadableWidth")} options={WIDTHS().map(([value, label]) => ({ value, label }))} onChange={(v) => setMd("markdownReadableWidth", v)} /></Row>
      </Card>
      <Header>{t("显示")}</Header>
      <Card>
        {toggle(t("显示 Markdown 文档工具栏"), "markdownToolbar")}
        {toggle(t("指针移到一行时显示手柄"), "markdownShowsHandles")}
        {toggle(t("空行显示提示文字（标题 1、列表…）"), "markdownShowsPlaceholders")}
        {toggle(t("显示字数"), "markdownShowsWordCount")}
        {toggle(t("完成的任务加删除线"), "markdownStrikesDone")}
      </Card>
      <Header>{t("输入")}</Header>
      <Card>
        {toggle(t("输入“/”或“、”打开工具菜单"), "markdownSlashMenu")}
        {toggle(t("回车延续列表和引用"), "markdownContinuesLists")}
        {toggle(t("自动转换中文符号（》、【】、·）"), "markdownCompletesSymbols")}
        {toggle(t("选中文字粘贴网址时生成链接"), "markdownPastesLinks")}
        {toggle(t("检查拼写"), "markdownChecksSpelling")}
      </Card>
      <Header>{t("代码块")}</Header>
      <Card>
        {toggle(t("语法高亮"), "markdownHighlightsCode")}
        <Row title={t("缩进")}><Select value={number("markdownCodeIndent")} options={[2, 4, 8].map((n) => ({ value: n, label: t("%lld 个空格", n) }))} onChange={(v) => setMd("markdownCodeIndent", v)} /></Row>
      </Card>
      <div style={{ height: 14 }} />
      <Card>
        {slide(t("文档缩放"), "markdownZoom", 0.5, 3, 0.05, (v) => `${Math.round(v * 100)}%`)}
        {slide(t("侧栏缩放"), "markdownPanelZoom", 0.5, 3, 0.05, (v) => `${Math.round(v * 100)}%`)}
        <Row title={t("手势与快捷键")}><span className="secondary">{t("捏合或 Ctrl+滚轮、Ctrl+=、Ctrl+- 整页缩放，Ctrl+0 恢复 100%")}</span></Row>
        <Row title={t("恢复默认设置")}><button className="btn" disabled={!changed} onClick={() => keys.forEach((k) => { if (k !== "markdownToolbar") setMd(k, MD[k]); })}>{t("恢复")}</button></Row>
      </Card>
    </>
  );
}
