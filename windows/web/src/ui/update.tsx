import { useEffect, useState } from "react";
import { ArrowDown, ChevronRight, RotateCw } from "lucide-react";
import { call, inHost, on } from "../rpc";
import { t } from "../i18n";

interface UpdateState { available?: string | null; downloaded: boolean; downloading: boolean }

/** The update waiting for the user: a small card at the foot of the sidebar, out of the way of the toolbar and the
 *  reading, there only while an update is found. It downloads it (unless done already) and offers to restart. */
export function UpdateButton() {
  const [state, setState] = useState<UpdateState | null>(null);
  useEffect(() => {
    if (inHost) call<UpdateState>("update.state").then(setState).catch(() => {});
    return on("update", setState);
  }, []);
  if (!state?.available) return null;
  const title = state.downloading ? t("正在下载…") : state.downloaded ? t("重新启动以更新") : t("有新版本可用");
  const tip = state.downloaded ? t("Folio %@ 已下载，点按重新启动并安装", state.available) : t("Folio %@ 可供更新", state.available);
  return (
    <button className="update-card" title={tip} disabled={state.downloading} onClick={() => call("update.install")}>
      <span className="badge">
        {state.downloading ? <span className="spinner small" /> : state.downloaded ? <RotateCw size={12} strokeWidth={2.6} /> : <ArrowDown size={12} strokeWidth={2.6} />}
      </span>
      <span className="text">
        <span className="title">{title}</span>
        <span className="version tabular">Folio {state.available}</span>
      </span>
      <ChevronRight size={13} className="chev" />
    </button>
  );
}
