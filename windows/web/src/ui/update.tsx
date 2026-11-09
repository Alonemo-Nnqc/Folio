import { useEffect, useState } from "react";
import { ArrowDownCircle, RotateCw } from "lucide-react";
import { call, inHost, on } from "../rpc";
import { t } from "../i18n";

interface UpdateState { available?: string | null; downloaded: boolean; downloading: boolean }

/** The toolbar's 更新 button: there while an update waits; it downloads it (unless done already) and offers to restart. */
export function UpdateButton() {
  const [state, setState] = useState<UpdateState | null>(null);
  useEffect(() => {
    if (inHost) call<UpdateState>("update.state").then(setState).catch(() => {});
    return on("update", setState);
  }, []);
  if (!state?.available) return null;
  const label = state.downloading ? t("正在下载…") : state.downloaded ? t("重新启动以更新") : t("更新");
  const tip = state.downloaded ? t("Folio %@ 已下载，点按重新启动并安装", state.available) : t("Folio %@ 可供更新", state.available);
  return (
    <button className="update-button" title={tip} disabled={state.downloading} onClick={() => call("update.install")}>
      {state.downloading ? <span className="spinner small" /> : state.downloaded ? <RotateCw size={14} strokeWidth={2} /> : <ArrowDownCircle size={15} strokeWidth={2} />}
      <span>{label}</span>
    </button>
  );
}
