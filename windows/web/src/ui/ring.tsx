import { call } from "../rpc";
import { t } from "../i18n";
import { getState, useStore, type Item } from "../store";

/** Where a paper stands, as one small ring: empty (未读), filled as far as it has been read (在读), a check (已读). The sidebar,
 *  the list and the inspector draw the same one (READ-01, as the Mac's ReadingRing.swift). */
export function ReadingRing({ status, fraction = 0.62, size = 16 }: { status: number; fraction?: number; size?: number }) {
  const line = Math.max(size * 0.115, 1.5), r = size / 2 - line / 2 - 0.75, c = size / 2, length = 2 * Math.PI * r;
  if (status === 2) return (
    <svg className="ring" width={size} height={size} aria-hidden>
      <circle cx={c} cy={c} r={size / 2 - 0.75} fill="var(--ring-read)" />
      <path d={`M${size * 0.3} ${size * 0.51}L${size * 0.44} ${size * 0.65}L${size * 0.71} ${size * 0.35}`} fill="none" stroke="#fff" strokeWidth={Math.max(size * 0.11, 1.4)} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
  return (
    <svg className="ring" width={size} height={size} aria-hidden>
      <circle cx={c} cy={c} r={r} fill="none" stroke={status === 1 ? "var(--ring-track)" : "var(--tertiary)"} strokeWidth={status === 1 ? line : Math.max(line * 0.8, 1.2)} />
      {status === 1 && <circle cx={c} cy={c} r={r} fill="none" stroke="var(--accent)" strokeWidth={line * 1.25} strokeLinecap="round"
        strokeDasharray={`${length * Math.min(Math.max(fraction, 0.06), 1)} ${length}`} transform={`rotate(-90 ${c} ${c})`} />}
    </svg>
  );
}

export const percent = (fraction: number) => `${Math.round(Math.min(Math.max(fraction, 0), 1) * 100)}%`;

export const statusName = (status: number) => getState().statics.statuses.find((s) => s.raw === status)?.name ?? "";

/** The ring in a row of the list: a click moves the paper to the next status without selecting the row. */
export function ReadingRingButton({ item }: { item: Item }) {
  const fraction = useStore((s) => s.reading[item.id]?.fraction ?? 0);
  const next = (item.readStatus + 1) % 3;
  const state = item.readStatus === 1 && fraction > 0 ? t("在读 · 读到 %@", percent(fraction)) : statusName(item.readStatus);
  return (
    <button className="ring-button" title={t("%@，点按标为%@", state, statusName(next))} aria-label={t("阅读状态：%@", state)}
      onMouseDown={(e) => e.stopPropagation()} onMouseUp={(e) => e.stopPropagation()} onDoubleClick={(e) => e.stopPropagation()}
      onClick={(e) => { e.stopPropagation(); call("items.update", { ids: [item.id], patch: { readStatus: next } }); }}>
      <ReadingRing status={item.readStatus} fraction={fraction} />
    </button>
  );
}
