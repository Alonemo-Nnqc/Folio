import { createRoot } from "react-dom/client";
import { call, inHost, setMock } from "./rpc";
import { boot, useStore } from "./store";
import { MainApp } from "./App";
import { SettingsApp } from "./settings/SettingsApp";
import { Onboarding } from "./onboarding/Onboarding";
import { MenuHost } from "./ui/menu";
import { SheetHost } from "./ui/sheet";
import { ToastHost } from "./ui/toast";

function Root({ route }: { route: string }) {
  const state = useStore((s) => s.windowState);
  return (
    <>
      {route === "main" && <MainApp />}
      {route === "settings" && <SettingsApp />}
      {route === "onboarding" && <Onboarding />}
      {state === "normal" && route !== "onboarding" && <div className="top-resize" onPointerDown={(e) => { if (e.button === 0) { e.preventDefault(); call("window.resize", { edge: "top" }); } }} />}
      <MenuHost />
      <SheetHost />
      <ToastHost />
    </>
  );
}

async function start() {
  const route = location.hash.replace("#", "") || "main";
  if (!inHost) setMock((await import("./mock")).mockCall);
  await boot(route);
  createRoot(document.getElementById("root")!).render(<Root route={route} />);
  requestAnimationFrame(() => call("app.ready"));
}

start();
