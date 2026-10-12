// Talks to Folio's local connector service (WEB-01). Safari may refuse an extension's request to
// http://127.0.0.1, so there it falls back to the Safari extension inside Folio.app (native messaging).
const api = globalThis.browser ?? globalThis.chrome;
const FOLIO = "http://127.0.0.1:23120";

async function folioRequest(path, { method = "GET", json, data, contentType } = {}) {
  const headers = { "X-Folio-Connector": "1" };
  let body;
  if (json !== undefined) {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify(json);
  } else if (data !== undefined) {
    headers["Content-Type"] = contentType || "application/octet-stream";
    body = data;
  }
  try {
    const response = await fetch(FOLIO + path, { method, headers, body });
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
  }
}

/** Downloads a PDF with the user's browser session and hands it to Folio. */
async function sendPDF(pdfUrl, target) {
  const response = await fetch(pdfUrl, { credentials: "include" });
  if (!response.ok) throw new Error(`PDF ${response.status}`);
  const bytes = await response.arrayBuffer();
  const name = decodeURIComponent((new URL(response.url || pdfUrl).pathname.split("/").pop() || "paper")).replace(/[^\w.\- ]+/g, "_");
  const query = target.itemId ? `/attach?item=${encodeURIComponent(target.itemId)}` : `/savePDF?groupId=${encodeURIComponent(target.groupId || "")}`;
  return folioRequest(`${query}&filename=${encodeURIComponent(name)}`, { method: "POST", data: bytes, contentType: "application/pdf" });
}
