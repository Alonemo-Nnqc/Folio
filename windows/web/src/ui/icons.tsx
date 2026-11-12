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
