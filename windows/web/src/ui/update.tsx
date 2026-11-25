import { useEffect, useState } from "react";
import { ArrowDownCircle, RefreshCcw } from "lucide-react";
import { call, inHost, on } from "../rpc";
import { t } from "../i18n";

interface UpdateState { available?: string | null; downloaded: boolean; downloading: boolean }

/** The update waiting for the user: a flat, quiet row at the foot of the sidebar, there only while an update is found —
 *  a tinted fill instead of a card and shadow, the version in plain words and one small capsule that says what a click
 *  does (as on the Mac since 1.5). It downloads the update (unless done already) and offers to restart. */
export function UpdateButton() {
  const [state, setState] = useState<UpdateState | null>(null);
  useEffect(() => {
    if (inHost) call<UpdateState>("update.state").then(setState).catch(() => {});
    return on("update", setState);
  }, []);
  if (!state?.available) return null;
  const detail = state.downloading ? t("正在下载…") : state.downloaded ? t("已下载") : t("新版本可用");
  const tip = state.downloaded ? t("Folio %@ 已下载，点按重新启动并安装", state.available) : t("Folio %@ 可供更新", state.available);
  return (
    <button className="update-row" title={tip} disabled={state.downloading} onClick={() => call("update.install")}>
      {state.downloading ? <span className="spinner small" /> : state.downloaded ? <RefreshCwIcon /> : <ArrowDownCircle size={18} strokeWidth={2} className="icon" />}
      <span className="text">
        <span className="title tabular">Folio {state.available}</span>
        <span className="detail">{detail}</span>
      </span>
      {!state.downloading && <span className="action">{state.downloaded ? t("重启") : t("更新")}</span>}
    </button>
  );
}

function RefreshCwIcon() { return <RefreshCcw size={18} strokeWidth={2} className="icon" />; }
