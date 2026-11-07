import { useEffect } from "react";
import { X } from "lucide-react";
import { call } from "../rpc";
import { setState, useStore } from "../store";
import { namedIcon } from "./icons";

export function ToastHost() {
  const toast = useStore((s) => s.toast);
  useEffect(() => {
    if (!toast) return;
    const timer = setTimeout(() => setState({ toast: null }), toast.actionTitle || toast.message.length > 30 ? 6000 : 3500);
    return () => clearTimeout(timer);
  }, [toast]);
  if (!toast) return null;
  return (
    <div className="toast-layer">
      <div className="toast" key={toast.id}>
        {namedIcon(toast.icon, 15)}
        <span>{toast.message}</span>
        {toast.actionTitle && <button className="action" onClick={() => { call("toast.run", { id: toast.id }); setState({ toast: null }); }}>{toast.actionTitle}</button>}
        <button className="close" onClick={() => setState({ toast: null })}><X size={12} /></button>
      </div>
    </div>
  );
}
