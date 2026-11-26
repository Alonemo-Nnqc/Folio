// The languages of code blocks, and what language a block without one is in. The same file is used by the macOS app
// (JavaScriptCore) and the Windows app (windows/web/src/notes/code-languages.js); it needs highlight.js as `hljs`.
(function (root) {
  var languages = [
    ["plaintext", "Plain Text"], ["bash", "Bash"], ["c", "C"], ["cpp", "C++"], ["csharp", "C#"], ["cmake", "CMake"], ["css", "CSS"],
    ["dart", "Dart"], ["diff", "Diff"], ["dockerfile", "Dockerfile"], ["fortran", "Fortran"], ["go", "Go"], ["graphql", "GraphQL"],
    ["haskell", "Haskell"], ["xml", "HTML / XML"], ["ini", "INI / TOML"], ["java", "Java"], ["javascript", "JavaScript"], ["json", "JSON"],
    ["julia", "Julia"], ["kotlin", "Kotlin"], ["latex", "LaTeX"], ["lua", "Lua"], ["makefile", "Makefile"], ["markdown", "Markdown"],
    ["matlab", "MATLAB"], ["objectivec", "Objective-C"], ["perl", "Perl"], ["php", "PHP"], ["powershell", "PowerShell"], ["python", "Python"],
    ["r", "R"], ["ruby", "Ruby"], ["rust", "Rust"], ["scala", "Scala"], ["scss", "SCSS"], ["sql", "SQL"], ["swift", "Swift"],
    ["typescript", "TypeScript"], ["yaml", "YAML"]
  ];
  var names = {};
  languages.forEach(function (l) { names[l[0]] = l[1]; });

  /** The language an info string names ("py" → python); null: none we know. */
  function resolve(info) {
    var word = String(info || "").trim().split(/[\s{,:]/)[0].toLowerCase();
    if (!word) return null;
    if (word === "text" || word === "txt" || word === "plain" || word === "plaintext") return "plaintext";
    if (names[word]) return word;
    var found = root.hljs.getLanguage(word);
    if (!found) return null;
    var same = languages.filter(function (l) { return root.hljs.getLanguage(l[0]) === found; })[0];
    if (same) return same[0];
    return root.hljs.listLanguages().filter(function (l) { return root.hljs.getLanguage(l) === found; })[0] || null;
  }

  // What gives a language away even in a line or two, where counting keywords does not.
  var signs = [
    ["bash", /^#!.*\b(ba|z|k)?sh\b/], ["python", /^#!.*\bpython/], ["javascript", /^#!.*\bnode/],
    ["xml", /^\s*(<!doctype html|<\?xml|<html[\s>])/i], ["php", /^\s*<\?php/],
    ["latex", /\\(documentclass|begin\{|usepackage|section\{|frac\{|cite\{|textbf\{)/],
    ["diff", /^(diff --git |@@ -\d+,?\d* \+\d+|--- a\/)/m],
    ["dockerfile", /^\s*FROM [\w.\/:-]+[\s\S]*^\s*(RUN|CMD|COPY|WORKDIR|ENTRYPOINT) /m],
    ["objectivec", /^\s*(#import\s*<|@interface |@implementation )/m],
    ["cpp", /#include\s*<(iostream|vector|string|memory|map|algorithm|cmath)>|\bstd::|\bcout\s*<<|\btemplate\s*</],
    ["c", /#include\s*[<"][\w\/.]+\.h[>"]/],
    ["csharp", /^\s*using System(\.|;)|\bConsole\.(Write|Read)|\bnamespace [\w.]+\s*[{;]/m],
    ["java", /\bpublic (static )?(final )?(class|interface|void|enum)\b|\bSystem\.out\.|^import java/m],
    ["kotlin", /\bfun \w+\([^)]*\)\s*(:\s*\w+\s*)?[{=]|\bval \w+\s*(:\s*\w+)?\s*=/],
    ["rust", /\bfn \w+\s*(<[^>]*>)?\([^)]*\)|\blet mut |\bprintln!|^use (std|crate)::/m],
    ["go", /^package \w+\s*$|\bfunc (\(\w+ \*?\w+\) )?\w+\([^)]*\)[^{]*\{|\bfmt\.Print/m],
    ["swift", /^import (SwiftUI|Foundation|UIKit|AppKit)\b|\bfunc \w+\([^)]*\)\s*(async )?(throws )?(->\s*[\w\[\]?<>]+\s*)?\{|\bguard let /m],
    ["typescript", /\binterface \w+\s*(extends \w+\s*)?\{|\btype \w+\s*=|:\s*(string|number|boolean|void|any)(\[\])?\s*[;,)=]/],
    ["javascript", /\bconsole\.log\(|\b(const|let) [\w{[][^=\n]*=\s*|=>\s*[{(\w]|\bfunction\s*\w*\(|\brequire\(['"]|^export (default|const|function)/m],
    ["python", /^\s*(def \w+\(.*\).*:|class \w+.*:|import \w+( as \w+)?\s*$|import \w+(\.\w+)+( as \w+)?|from [\w.]+ import |if __name__|elif .*:|(for|while|if|with) .*:\s*$)|\bprint\(|\bself\.\w+/m],
    ["sql", /\b(select\b[\s\S]+\bfrom\b|insert into\b|create (table|index|view)\b|update\b[\s\S]+\bset\b|delete from\b|alter table\b)/i],
    ["r", /<-\s*(function\s*\(|c\(|data\.frame|read\.)|\blibrary\(\w+\)|%>%/],
    ["julia", /^\s*using [A-Z]\w+|\bfunction \w+\([^)]*\)[\s\S]*\bend\b/m],
    ["matlab", /^\s*function\s+(\[[^\]]*\]|\w+)\s*=\s*\w+\(|^\s*%[^%\n]+$[\s\S]*;\s*$|\b(zeros|ones|linspace|figure|plot)\(.*\);/m],
    ["powershell", /\b(Get|Set|New|Remove|Write|Invoke|Start|Stop)-[A-Z]\w+|\$env:\w+/],
    ["bash", /^\s*(\$ )?(sudo|cd|ls|apt(-get)?|brew|pip3?|conda|npm|pnpm|yarn|git|curl|wget|mkdir|chmod|export|echo|python3?|docker|ssh|scp|rm|cp|mv|cat|grep|make|source)\s+[\w.\-\/"'$~@:]/m],
    ["css", /^\s*[.#]?[\w-]+(\s*[,>+~]?\s*[.#:]?[\w-]+)*\s*\{\s*[\w-]+\s*:[^;{}]+;/m],
    ["xml", /^\s*<([a-z][\w-]*)(\s[^>]*)?>[\s\S]*<\/\1>/i],
    ["ini", /^\s*\[[\w.\- "]+\]\s*$[\s\S]*^\s*[\w.-]+\s*=/m],
    ["makefile", /^[\w.-]+:.*\n\t/m],
    ["yaml", /^(---\s*\n)?[\w-]+:(\s+\S.*)?\n(\s*(- |[\w-]+:).*\n?)+/]
  ];
  var candidates = ["python", "javascript", "typescript", "java", "c", "cpp", "csharp", "go", "rust", "swift", "kotlin", "ruby", "php", "r", "sql", "bash",
    "json", "yaml", "xml", "css", "latex", "matlab", "julia", "lua", "perl", "scala", "haskell", "fortran", "ini"];

  function detect(code) {
    var text = code.trim();
    if (text.length < 4) return null;
    if (/^[\[{]/.test(text) && /["\]}\d]\s*[\]}]$|^(\[\]|\{\})$/.test(text)) { try { JSON.parse(text); return "json"; } catch (e) { /* not JSON */ } }
    for (var i = 0; i < signs.length; i++) if (signs[i][1].test(text)) return signs[i][0];
    var found = root.hljs.highlightAuto(text.slice(0, 4000), candidates);
    return found.relevance >= 7 ? found.language : null;
  }

  var entities = { amp: "&", lt: "<", gt: ">", quot: '"', "#x27": "'" };

  /** [start, end, kind, …] of the coloured parts of the code. */
  function tokens(code, language) {
    if (!language || language === "plaintext" || code.length > 60000 || !root.hljs.getLanguage(language)) return [];
    var html = root.hljs.highlight(code, { language: language, ignoreIllegals: true }).value;
    var out = [], stack = [], at = 0, part, re = /<span class="([^"]*)">|<\/span>|&(amp|lt|gt|quot|#x27);|[^<&]+/g;
    function text(length) {
      var kind = "";
      for (var i = stack.length - 1; i >= 0 && !kind; i--) if (stack[i] !== "subst" && stack[i] !== "params") kind = stack[i];
      if (kind) {
        var n = out.length;
        if (n && out[n - 2] === at && out[n - 1] === kind) out[n - 2] = at + length; else out.push(at, at + length, kind);
      }
      at += length;
    }
    while ((part = re.exec(html))) {
      if (part[1] !== undefined) stack.push(part[1].replace(/hljs-/g, "").split(" ")[0]);
      else if (part[0] === "</span>") stack.pop();
      else if (part[2]) text(entities[part[2]].length);
      else text(part[0].length);
    }
    return out;
  }

  root.folioCode = { languages: languages, names: names, resolve: resolve, detect: detect, tokens: tokens };
})(typeof globalThis !== "undefined" ? globalThis : this);
