// The keys are the Simplified Chinese source strings, the same as the macOS app's; English comes from its String Catalogs.
let table: Record<string, string> | null = null;
export let isEnglish = false;

export function setStrings(strings: Record<string, string> | null | undefined, english: boolean) {
  table = strings ?? null;
  isEnglish = english;
}

const placeholder = /%(?:(\d+)\$)?((?:\.\d+)?(?:lld|ld|d|@|f|u|lu|llu))|%%/g;

export function t(key: string, ...args: unknown[]): string {
  const format = table?.[key] ?? key;
  let next = 0;
  return format.replace(placeholder, (m, index) => {
    if (m === "%%") return "%";
    if (args.length === 0) return m;
    const i = index ? Number(index) - 1 : next++;
    return i < args.length ? String(args[i]) : m;
  });
}

