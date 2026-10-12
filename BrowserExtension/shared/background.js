// Folio background worker: finishes PDF downloads even after the popup closes, and adds a
// "保存到 Folio" item to the page's context menu.
if (typeof importScripts === "function") importScripts("connector.js");

const runtime = (globalThis.browser ?? globalThis.chrome);

runtime.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "sendPDF") return false;
  sendPDF(message.pdfUrl, message.target)
    .then((result) => {
      flash(message.tabId, result.ok ? "✓" : "!", result.ok ? "#34C759" : "#FF9500");
      sendResponse({ ok: result.ok, data: result.data });
    })
    .catch((error) => {
      flash(message.tabId, "!", "#FF9500");
      sendResponse({ ok: false, error: String(error.message || error) });
    });
  return true; // async response
});

function flash(tabId, text, color) {
  if (!tabId || !runtime.action?.setBadgeText) return;
  runtime.action.setBadgeBackgroundColor?.({ color, tabId });
  runtime.action.setBadgeText({ text, tabId });
  setTimeout(() => runtime.action.setBadgeText({ text: "", tabId }), 4000);
}

runtime.runtime.onInstalled.addListener(() => {
  runtime.contextMenus?.create({ id: "folio-save", title: "保存到 Folio", contexts: ["page", "link"] });
});

runtime.contextMenus?.onClicked.addListener(() => {
  // Opening the popup programmatically is not available everywhere; fall back to a hint.
  if (runtime.action?.openPopup) runtime.action.openPopup().catch(() => {});
});
