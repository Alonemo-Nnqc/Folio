// Talks to Folio's local connector service (WEB-01). Safari may refuse an extension's request to
// http://127.0.0.1, so there it falls back to the Safari extension inside Folio.app (native messaging).
// Keep every script the background page or a tab loads pure ASCII (non-ASCII text as \u escapes): Safari's generated
// background page declares no charset, so on a Chinese system it decodes UTF-8 as GBK and the script fails to parse.
const api = globalThis.browser ?? globalThis.chrome;
const FOLIO = "http://127.0.0.1:23120";
/** Version of the conversation with Folio; Folio rejects nothing, it only reports when it is newer. */
const CONNECTOR_API = 2;

async function folioRequest(path, { method = "GET", json, data, contentType, timeout = 120000 } = {}) {
  const headers = { "X-Folio-Connector": String(CONNECTOR_API) };
  let body;
  if (json !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(json);
  } else if (data !== undefined) {
    headers["Content-Type"] = contentType || "application/octet-stream";
    body = data;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const response = await fetch(FOLIO + path, { method, headers, body, signal: controller.signal });
    const payload = await response.json().catch(() => ({}));
    return { ok: response.ok, status: response.status, data: payload };
  } catch (error) {
    if (api?.runtime?.sendNativeMessage) {
      const bytes = data !== undefined ? new Uint8Array(data) : json !== undefined ? new TextEncoder().encode(body) : null;
      let binary = "";
      if (bytes) for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      const reply = await api.runtime.sendNativeMessage("com.nnqc.Folio.SafariExtension", {
        method, path, contentType: headers["Content-Type"] || "", bodyBase64: bytes ? btoa(binary) : "",
      }).catch(() => null);
      if (reply && reply.status) {
        let parsed = {};
        try { parsed = JSON.parse(reply.body || "{}"); } catch { /* not JSON */ }
        return { ok: reply.status < 400, status: reply.status, data: parsed };
      }
    }
    throw new Error("folio-offline");
  } finally {
    clearTimeout(timer);
  }
}

/** A short reason for a failed download, for the popup and Folio's notice. */
// Sign-in or subscription needed / link expired / download failed / the link opened a web page, not a PDF.
function describeDownloadFailure(status, type) {
  if (status === 401 || status === 403) return "\u9700\u8981\u767B\u5F55\u6216\u8BA2\u9605\u624D\u80FD\u4E0B\u8F7D PDF";
  if (status === 404) return "PDF \u94FE\u63A5\u5DF2\u5931\u6548\uFF08404\uFF09";
  if (status) return `\u4E0B\u8F7D PDF \u5931\u8D25\uFF08HTTP ${status}\uFF09`;
  return type ? `\u94FE\u63A5\u6253\u5F00\u7684\u662F\u7F51\u9875\uFF08${type}\uFF09\uFF0C\u4E0D\u662F PDF\uFF0C\u53EF\u80FD\u9700\u8981\u767B\u5F55\u6216\u8BA2\u9605` : "\u4E0B\u8F7D PDF \u5931\u8D25";
}

/** The PDF behind a publisher's landing or interstitial page (meta refresh, viewer frame, script redirect, PDF link). */
function pdfLinkInHTML(html, base) {
  const patterns = [
    /<meta[^>]+name=["']citation_pdf_url["'][^>]+content=["']([^"']+)["']/i,
    /<meta[^>]+content=["']([^"']+)["'][^>]+name=["']citation_pdf_url["']/i,
    /<meta[^>]+http-equiv=["']refresh["'][^>]+content=["'][^"']*url=([^"'>]+)["']/i,
    /<(?:iframe|embed)[^>]+src=["']([^"']+)["']/i,
    /window\.location(?:\.href)?\s*=\s*["']([^"']+)["']/i,
    /<a[^>]+href=["']([^"']+\.pdf(?:\?[^"']*)?)["']/i,
    /["'](https:\/\/pdf\.sciencedirectassets\.com\/[^"']+)["']/i,
  ];
  for (const pattern of patterns) {
    const match = html.match(pattern);
    if (!match) continue;
    try {
      const url = new URL(match[1].replace(/&amp;/g, "&").trim(), base);
      if (url.protocol === "http:" || url.protocol === "https:") return url.href;
    } catch { /* not a URL */ }
  }
  return "";
}

/** Downloads a PDF with the user's browser session (cookies, institutional access), following up to two
 *  interstitial pages. Returns { bytes, url } or throws an Error whose message explains the failure. */
async function downloadPDF(pdfUrl) {
  let url = pdfUrl;
  for (let hop = 0; hop < 3; hop += 1) {
    let response;
    try {
      response = await fetch(url, { credentials: "include", redirect: "follow" });
    } catch (error) {
      throw new Error(`\u65E0\u6CD5\u8FDE\u63A5 ${new URL(url).hostname}`);
    }
    if (!response.ok) throw new Error(describeDownloadFailure(response.status));
    const bytes = await response.arrayBuffer();
    const head = new TextDecoder("latin1").decode(new Uint8Array(bytes, 0, Math.min(1024, bytes.byteLength)));
    if (head.includes("%PDF")) return { bytes, url: response.url || url };
    const type = (response.headers.get("content-type") || "").split(";")[0];
    if (!/html|xml|text/.test(type) || hop === 2) throw new Error(describeDownloadFailure(0, type || "\u672A\u77E5\u7C7B\u578B"));
    const next = pdfLinkInHTML(new TextDecoder().decode(bytes), response.url || url);
    if (!next || next === url) throw new Error(describeDownloadFailure(0, type));
    url = next;
  }
  throw new Error(describeDownloadFailure(0, "\u7F51\u9875"));
}

function fileNameFor(url) {
  let name = "paper";
  try { name = decodeURIComponent(new URL(url).pathname.split("/").pop() || "paper"); } catch { /* keep default */ }
  name = name.replace(/[^\w.\- ]+/g, "_").slice(0, 120) || "paper";
  return /\.pdf$/i.test(name) ? name : `${name}.pdf`;
}

/** Downloads a PDF and hands it to Folio: attached to `target.itemId`, or imported into `target.groupId`.
 *  Folio is told about failures too, so the user learns about them even after the popup closed. */
async function sendPDF(pdfUrl, target) {
  let download;
  try {
    download = await downloadPDF(pdfUrl);
  } catch (error) {
    if (target.itemId) {
      await folioRequest(`/pdfFailed?item=${encodeURIComponent(target.itemId)}`, {
        method: "POST", json: { message: error.message, url: pdfUrl },
      }).catch(() => {});
    }
    return { ok: false, error: error.message };
  }
  const name = encodeURIComponent(fileNameFor(download.url));
  const path = target.itemId
    ? `/attach?item=${encodeURIComponent(target.itemId)}&filename=${name}`
    : `/savePDF?groupId=${encodeURIComponent(target.groupId || "")}&filename=${name}`;
  const response = await folioRequest(path, { method: "POST", data: download.bytes, contentType: "application/pdf", timeout: 300000 });
  return { ok: response.ok, data: response.data, error: response.ok ? "" : response.data?.error || `Folio \u8FD4\u56DE ${response.status}` };
}
