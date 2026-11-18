import { useMemo, useState } from "react";
import { t } from "../i18n";
import { useStore } from "../store";
import { TabBar, SettingsButton } from "../library/LibraryPage";
import { markdownSource } from "../library/Inspector";
import { MarkdownEditor, PreviewToggle } from "./markdown";

/** A Markdown document in a tab of its own (MD-01): the editor at a comfortable reading width. */
export function MarkdownTab({ fileId, visible }: { fileId: string; visible: boolean }) {
  const file = useStore((s) => s.files.get(fileId));
  const item = useStore((s) => (file ? s.items.get(file.itemId) : undefined));
  const captionWidth = useStore((s) => s.captionWidth);
  const [preview, setPreview] = useState(false);
  const source = useMemo(() => markdownSource(fileId), [fileId]);
  if (!file) return null;
  const title = item?.kind === "standalone" ? item.title : file.fileName;
  const subtitle = item?.kind === "regular" ? item.title : "";
  return (
    <div className="md-tab window" style={{ display: visible ? "flex" : "none" }}>
      <div className="titlebar-row drag" style={{ paddingLeft: 10, paddingRight: captionWidth + 8 }}>
        <SettingsButton />
        <div className="list-title">
          <div className="name ellipsis" title={title}>{title}</div>
          {subtitle && <div className="count ellipsis" title={subtitle}>{subtitle}</div>}
        </div>
        <PreviewToggle preview={preview} onChange={setPreview} />
      </div>
      <TabBar />
      <div className="md-tab-body">
        <div className="md-tab-column">
          <MarkdownEditor source={source} preview={preview} className="md-text" placeholder={t("开始书写… 支持 Markdown")} />
        </div>
      </div>
    </div>
  );
}
