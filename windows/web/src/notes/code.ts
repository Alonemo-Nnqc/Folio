import hljs from "highlight.js/lib/common";
import latex from "highlight.js/lib/languages/latex";
import matlab from "highlight.js/lib/languages/matlab";
import julia from "highlight.js/lib/languages/julia";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import powershell from "highlight.js/lib/languages/powershell";
import scala from "highlight.js/lib/languages/scala";
import haskell from "highlight.js/lib/languages/haskell";
import dart from "highlight.js/lib/languages/dart";
import cmake from "highlight.js/lib/languages/cmake";
import fortran from "highlight.js/lib/languages/fortran";
import "./code-languages.js";

// highlight.js with the same languages as the Mac's copy, and what Folio does with it (code-languages.js, the same file).
for (const [name, language] of Object.entries({ latex, matlab, julia, dockerfile, powershell, scala, haskell, dart, cmake, fortran })) hljs.registerLanguage(name, language);
(globalThis as any).hljs = hljs;

interface Tools {
  languages: [string, string][];
  names: Record<string, string>;
  resolve(info: string): string | null;
  detect(code: string): string | null;
  tokens(code: string, language: string): (number | string)[];
}
const tools = (globalThis as any).folioCode as Tools;

function remember<T>(limit: number, make: (key: string) => T) {
  const known = new Map<string, T>();
  return (key: string): T => {
    if (known.has(key)) return known.get(key)!;
    if (known.size > limit) known.clear();
    const value = make(key);
    known.set(key, value);
    return value;
  };
}

const detect = remember(200, (code) => tools.detect(code));
const tokens = remember(100, (key) => { const at = key.indexOf("\n"); return tools.tokens(key.slice(at + 1), key.slice(0, at)); });

export const codeTools = {
  languages: tools.languages, names: tools.names,
  resolve: (info: string) => tools.resolve(info),
  detect,
  tokens: (code: string, language: string) => tokens(language + "\n" + code),
};

const KINDS: Record<string, string> = {
  keyword: "keyword", doctag: "keyword", "selector-tag": "keyword", "template-tag": "keyword", name: "keyword", tag: "keyword", deletion: "keyword",
  string: "string", regexp: "string", char: "string", addition: "string", quote: "string",
  number: "number", literal: "number", symbol: "number", bullet: "number", link: "number",
  comment: "comment", title: "title", section: "title", function: "title",
  built_in: "type", type: "type", class: "type", "selector-class": "type", "selector-id": "type",
  attr: "attr", attribute: "attr", variable: "attr", "template-variable": "attr", property: "attr", meta: "attr",
};
export const tokenClass = (kind: string) => (KINDS[kind] ? `cm-code-${KINDS[kind]}` : "");
