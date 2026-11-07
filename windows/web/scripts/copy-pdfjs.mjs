// pdf.js comes pinned from npm; only what the reader loads is copied next to it.
import { cpSync, mkdirSync, existsSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const pkg = join(root, "node_modules/pdfjs-dist");
const out = join(root, process.argv[2] ?? "public", "pdfjs");
if (existsSync(out)) rmSync(out, { recursive: true });
mkdirSync(join(out, "build"), { recursive: true });
mkdirSync(join(out, "web"), { recursive: true });
for (const f of ["build/pdf.min.mjs", "build/pdf.worker.min.mjs", "web/pdf_viewer.mjs", "web/pdf_viewer.css", "LICENSE"]) cpSync(join(pkg, f), join(out, f));
for (const d of ["web/images", "cmaps", "standard_fonts", "wasm"]) if (existsSync(join(pkg, d))) cpSync(join(pkg, d), join(out, d), { recursive: true });
