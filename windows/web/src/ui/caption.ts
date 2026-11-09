import { call } from "../rpc";
import { getState } from "../store";

// Windows' caption buttons are drawn by the app beside the page: they take the colour of what the page shows under them,
// darkened like the page while a sheet's scrim covers it, so the two never differ.

let base = { background: "#ffffff", foreground: "#000000" };
let scrims = 0;

function hex(n: number) { return Math.round(Math.max(0, Math.min(255, n))).toString(16).padStart(2, "0"); }

function shaded(color: string, amount: number) {
  const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color);
  if (!m || amount <= 0) return color;
  const keep = 1 - amount;
  return "#" + [m[1], m[2], m[3]].map((h) => hex(parseInt(h, 16) * keep)).join("");
}

function send(animate: boolean) {
  // The scrim's black (styles.css --scrim), once per sheet in the stack.
  const alpha = getState().dark ? 0.38 : 0.18;
  const cover = 1 - Math.pow(1 - alpha, scrims);
  call("window.caption", { background: shaded(base.background, cover), foreground: base.foreground, animate }).catch(() => {});
}

/** What the page shows under the buttons. */
export function setCaption(background: string, foreground: string, animate = false) {
  base = { background, foreground };
  send(animate);
}

/** Sheets open over the page (each with its scrim). */
export function setScrims(count: number) {
  if (count === scrims) return;
  scrims = count;
  send(true);
}
