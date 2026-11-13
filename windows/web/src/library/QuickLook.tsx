import { useEffect, useMemo, useRef, useState } from "react";
import { BookOpen, ExternalLink, FileText, X } from "lucide-react";
import { call } from "../rpc";
import { t } from "../i18n";
import { defaultFile, getState, setState, useStore, type FileRec } from "../store";
import { openReader } from "../commands";
import { readerLabels } from "../reader/ReaderTab";
import { useLayer } from "../ui/dismiss";

/**
 * 快速预览, like Quick Look on the Mac: Space (or a middle click — a three-finger tap on most touchpads) shows the selected
 * paper over the list, read-only; the arrow keys keep moving through the list and the preview follows.
 */
export function QuickLook() {
  const open = useStore((s) => s.quickLook);
  const selection = useStore((s) => s.selection);
  const fileSelection = useStore((s) => s.fileSelection);
  const files = useStore((s) => s.files);
  const items = useStore((s) => s.items);
  const dark = useStore((s) => s.dark);
  const [closing, setClosing] = useState(false);

  const target = useMemo(() => {
    const s = getState();
    const file = fileSelection ? files.get(fileSelection) : selection.length === 1 && items.get(selection[0]) ? defaultFile(s, items.get(selection[0])!) : undefined;
    const item = file ? items.get(file.itemId) : selection.length === 1 ? items.get(selection[0]) : undefined;
    return { file, item };
  }, [selection, fileSelection, files, items]);

  const close = () => {
    setClosing(true);
    window.setTimeout(() => { setClosing(false); setState({ quickLook: false }); }, 140);
  };

  useEffect(() => {
    if (!open) return;
    const key = (e: KeyboardEvent) => {
      if (e.key === " " && !(e.target as Element).closest?.("input, textarea")) { e.preventDefault(); e.stopPropagation(); close(); }
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  }, [open]);

  // Esc closes it, from its page too (the page forwards Esc while a layer is open).
  useLayer(open, { contains: () => true, onEscape: close });

  // Nothing (or several items) selected: nothing to show.
  useEffect(() => { if (open && !target.item) setState({ quickLook: false }); }, [open, target.item]);

  if (!open || !target.item) return null;
  const { file, item } = target;
  const title = item.kind === "regular" ? item.title : file?.fileName ?? item.title;
  return (
    <div className={`quicklook-scrim${closing ? " closing" : ""}`} onMouseDown={(e) => { if (e.target === e.currentTarget) close(); }}>
      <div className="quicklook" role="dialog" aria-label={t("快速预览")}>
        <div className="ql-head">
          <button className="ql-close" title={t("关闭（空格）")} onClick={close}><X size={13} strokeWidth={2.4} /></button>
          <div className="ql-title ellipsis" title={title}>{title}</div>
          {file && <button className="btn small" onClick={() => { close(); openReader(file.id); }}><BookOpen size={13} />{t("阅读")}</button>}
          {file && <button className="ql-icon" title={t("用默认应用打开")} onClick={() => call("file.open", { id: file.id, system: true })}><ExternalLink size={14} /></button>}
        </div>
        <div className="ql-body">
          {file?.isPdf ? <PdfPreview key={file.id} file={file} dark={dark} />
            : <div className="ql-placeholder">
                <FileText size={56} strokeWidth={1.2} />
                <div className="big">{file?.fileName ?? title}</div>
                {item.authorsList && <div className="secondary">{item.authorsList}{item.year ? ` · ${item.year}` : ""}</div>}
                {item.abstract && <div className="ql-abstract selectable">{item.abstract}</div>}
                {!file && !item.abstract && <div className="secondary">{t("这个条目没有附件")}</div>}
              </div>}
        </div>
      </div>
    </div>
  );
}

/** The paper in the reader's page (pdf.js), read-only: no tools, no sidebar. */
function PdfPreview({ file, dark }: { file: FileRec; dark: boolean }) {
  const frame = useRef<HTMLIFrameElement>(null);
  const session = useRef<string | null>(null);
  const queue = useRef<unknown[]>([]);
  const ready = useRef(false);
  const send = (m: unknown) => {
    if (ready.current && frame.current?.contentWindow) frame.current.contentWindow.postMessage(m, location.origin);
    else queue.current.push(m);
  };
  useEffect(() => {
    const listener = (e: MessageEvent) => {
      if (e.source !== frame.current?.contentWindow) return;
      const m = e.data?.folioReader;
      if (m?.type === "ready") {
        ready.current = true;
        queue.current.forEach((c) => frame.current?.contentWindow?.postMessage(c, location.origin));
        queue.current = [];
      } else if (m?.type === "link") call("shell.open", { target: m.url });
    };
    window.addEventListener("message", listener);
    (async () => {
      const labels = await readerLabels();
      const r = await call("reader.openFile", { file: file.id });
      session.current = r.session;
      send({ cmd: "theme", dark });
      // Thumbnails down the left, as Quick Look shows them; the glass shows through around the pages.
      send({ cmd: "insets", top: 0, sidebarTop: 0, sidebarWidth: 240 });
      send({ cmd: "sidebar", visible: true });
      send({ cmd: "sidebarTab", value: "thumbnails" });
      // Always the clearest glass, whatever 背景透明度 is.
      send({ cmd: "surface", alpha: 0 });
      document.documentElement.classList.add("quicklook-open");
      send({ cmd: "tool", tool: "select", color: "yellow" });
      send({ cmd: "open", url: r.url, zoom: "fitWidth", labels, layout: "single", author: "", page: r.state?.page });
    })();
    return () => {
      window.removeEventListener("message", listener);
      document.documentElement.classList.remove("quicklook-open");
      if (session.current) call("reader.close", { session: session.current });
    };
  }, [file.id]);
  return <iframe ref={frame} title="preview" src="reader/viewer.html" className="ql-frame" allowTransparency />;
}

/** Shows or hides the preview of what is selected. */
export function toggleQuickLook() {
  const s = getState();
  if (s.quickLook) { setState({ quickLook: false }); return; }
  if (s.selection.length === 1 || s.fileSelection) setState({ quickLook: true });
}
