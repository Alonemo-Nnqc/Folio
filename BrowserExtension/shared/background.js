// Folio background worker: finishes PDF downloads even after the popup closes, and adds "Save to Folio"
// to the page and link context menus (WEB-06).
if (typeof importScripts === "function") importScripts("connector.js");

const runtime = globalThis.browser ?? globalThis.chrome;
const menus = runtime.contextMenus ?? runtime.menus;

// Links worth saving directly: PDFs, DOIs and arXiv papers.
const LINK_PATTERNS = [
  "*://*/*.pdf", "*://*/*.pdf?*", "*://*/*.PDF", "*://doi.org/*", "*://dx.doi.org/*", "*://*/doi/10.*", "*://*/doi/*/10.*",
  "*://arxiv.org/abs/*", "*://arxiv.org/pdf/*", "*://*.arxiv.org/abs/*", "*://*.arxiv.org/pdf/*", "*://openreview.net/pdf*",
];

runtime.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "sendPDF") return false;
  sendPDF(message.pdfUrl, message.target)
    .then((result) => {
      flash(message.tabId, result.ok ? "\u2713" : "!", result.ok ? "#34C759" : "#FF9500");
      sendResponse(result);
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
  setTimeout(() => runtime.action.setBadgeText({ text: "", tabId }), 5000);
}

function createMenus() {
  if (!menus) return;
  // Promise-based in Chrome (MV3), Firefox and Safari alike; recreated so an update never duplicates them.
  Promise.resolve(menus.removeAll()).catch(() => {}).then(() => {
    menus.create({ id: "folio-save-page", title: runtime.i18n.getMessage("menuSavePage"), contexts: ["page", "frame", "selection"] });
    menus.create({ id: "folio-save-link", title: runtime.i18n.getMessage("menuSaveLink"), contexts: ["link"], targetUrlPatterns: LINK_PATTERNS });
  });
}
runtime.runtime.onInstalled.addListener(createMenus);
runtime.runtime.onStartup?.addListener(createMenus);

menus?.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "folio-save-link" && info.linkUrl) {
    saveLink(info.linkUrl, tab?.id);
  } else if (info.menuItemId === "folio-save-page") {
    // Opening the popup from a menu needs a user gesture, which a menu click is.
    runtime.action?.openPopup?.().catch?.(() => flash(tab?.id, "\u2191", "#007AFF"));
  }
});

/** Saves a linked PDF (imported, metadata looked up by Folio) or a DOI / arXiv link (looked up by identifier)
 *  into the group Folio is showing. */
async function saveLink(url, tabId) {
  try {
    const collections = await folioRequest("/collections");
    const groupId = collections.data?.currentGroupId || "";
    const arxiv = url.match(/arxiv\.org\/(?:abs|pdf)\/((?:\d{4}\.\d{4,5})|(?:[a-z-]+(?:\.[A-Z]{2})?\/\d{7}))/i);
    const doi = url.match(/\b(10\.\d{4,9}\/[^\s?#"'<>]+)/);
    const isPDF = /\.pdf($|[?#])/i.test(url) || /openreview\.net\/pdf/i.test(url);
    if (arxiv || (doi && !isPDF)) {
      const identifier = arxiv ? arxiv[1] : decodeURIComponent(doi[1]).replace(/[.,;)\]]+$/, "");
      const response = await folioRequest("/saveItems", {
        method: "POST", json: { items: [{ identifier, url }], groupId: groupId || null, tags: [], pdf: Boolean(arxiv) },
      });
      const saved = response.ok && response.data?.results?.[0]?.status !== "failed";
      flash(tabId, saved ? "\u2713" : "!", saved ? "#34C759" : "#FF9500");
      return;
    }
    const result = await sendPDF(url, { groupId });
    flash(tabId, result.ok ? "\u2713" : "!", result.ok ? "#34C759" : "#FF9500");
  } catch (error) {
    flash(tabId, "!", "#FF3B30");
  }
}
