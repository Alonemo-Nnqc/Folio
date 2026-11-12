import { AlertTriangle, BookOpen, Check, CheckCircle2, Copy, Download, FileText, Folder, HelpCircle, Info, Languages, RefreshCw, Search, Share, StickyNote, Trash2, Upload, X, Quote, KeyRound } from "lucide-react";
import type { ReactElement } from "react";

/** The icons the app names in its toasts. */
export function namedIcon(name: string, size = 15): ReactElement {
  const p = { size };
  switch (name) {
    case "warning": return <AlertTriangle {...p} color="var(--orange)" />;
    case "question": return <HelpCircle {...p} />;
    case "delete": return <Trash2 {...p} />;
    case "copy": return <Copy {...p} />;
    case "export": return <Share {...p} />;
    case "download": return <Download {...p} />;
    case "upload": return <Upload {...p} />;
    case "folder": return <Folder {...p} />;
    case "translate": return <Languages {...p} />;
    case "check": return <Check {...p} />;
    case "checkmark": return <CheckCircle2 {...p} color="var(--green)" />;
    case "search": return <Search {...p} />;
    case "close": return <X {...p} />;
    case "note": return <StickyNote {...p} />;
    case "cite": return <Quote {...p} />;
    case "reader": return <BookOpen {...p} />;
    case "refresh": return <RefreshCw {...p} />;
    case "key": return <KeyRound {...p} />;
    case "document": return <FileText {...p} />;
    default: return <Info {...p} />;
  }
}

/** 划词翻译's mark, like the Mac's translate symbol: "文" over "A", the "A" on a tile of its own. Drawn in currentColor. */
export function TranslateGlyph({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden="true" className="translate-glyph">
      <rect x="1" y="1" width="12" height="12" rx="2.8" fill="currentColor" opacity=".2" />
      <text x="7" y="11.1" textAnchor="middle" fontSize="10.4" fontWeight="700" fill="currentColor"
        fontFamily='"Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", sans-serif'>文</text>
      <rect x="8.5" y="8.5" width="10.5" height="10.5" rx="2.6" fill="currentColor" stroke="var(--glyph-knockout, #fff)" strokeWidth="1.2" />
      <text x="13.75" y="17.1" textAnchor="middle" fontSize="8.6" fontWeight="700" fill="var(--glyph-knockout, #fff)"
        fontFamily='"Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif'>A</text>
    </svg>
  );
}

/** The same mark where an icon component is expected (toolbar buttons): lucide's props, size only used. */
export function TranslateIcon({ size = 17 }: { size?: number; strokeWidth?: number }) {
  return <TranslateGlyph size={size + 1} />;
}
