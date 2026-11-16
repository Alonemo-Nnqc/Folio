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

/** 翻译全文's mark: a page with "文" on it and an "A" tile over its corner. It reads as translation like 划词翻译's
 *  mark without being the same (that one is two tiles). The Mac app draws the same shape (TranslationIcon.swift). */
export function FullTextTranslateGlyph({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden="true" className="translate-glyph">
      <path d="M9.5 18.25H4A1.5 1.5 0 0 1 2.5 16.75V3.25A1.5 1.5 0 0 1 4 1.75H11L15.5 6.25V9M11 1.75V6.25H15.5" fill="none"
        stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" strokeLinecap="round" />
      <text x="7.6" y="12.3" textAnchor="middle" fontSize="9.2" fontWeight="800" fill="currentColor"
        fontFamily='"Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", sans-serif'>文</text>
      <rect x="10" y="10" width="9" height="9" rx="2.4" fill="currentColor" stroke="var(--glyph-knockout, #fff)" strokeWidth="1.1" />
      <text x="14.5" y="17.2" textAnchor="middle" fontSize="7.6" fontWeight="800" fill="var(--glyph-knockout, #fff)"
        fontFamily='"Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif'>A</text>
    </svg>
  );
}

/** 翻译全文's mark where an icon component is expected (toolbar buttons, menus). */
export function FullTextTranslateIcon({ size = 17 }: { size?: number; strokeWidth?: number }) {
  return <FullTextTranslateGlyph size={size + 1} />;
}

/** The same mark where an icon component is expected (toolbar buttons): lucide's props, size only used. */
export function TranslateIcon({ size = 17 }: { size?: number; strokeWidth?: number }) {
  return <TranslateGlyph size={size + 1} />;
}

/** The 便签 tool's mark, like the Mac's note symbol: an upright card with its corner turned and two lines of writing,
 *  drawn as Lucide draws (a 24-unit box, round joins) so it sits with the other tools. */
export function NoteToolIcon({ size = 16, strokeWidth = 1.8 }: { size?: number; strokeWidth?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M7.5 2.5h9a2.5 2.5 0 0 1 2.5 2.5v10.5l-6 6H7.5A2.5 2.5 0 0 1 5 19V5a2.5 2.5 0 0 1 2.5-2.5Z" />
      <path d="M19 15.5h-4a2 2 0 0 0-2 2v4" />
      <path d="M8.5 8h7M8.5 11.5h4.5" />
    </svg>
  );
}
