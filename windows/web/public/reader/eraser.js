// The eraser's geometry for the reader page's live preview (READER-30): the same algorithm as Folio.Core's InkEraser
// (and FolioCore's on the Mac), which writes the result into the file. Strokes and tracks are flat lists x y x y … in
// page coordinates.
//
// The eraser's track is a chain of capsules (each segment of the track widened by the radius). For each segment of a
// stroke the stretch inside any capsule is computed exactly (a capsule is convex, so it meets a line in one interval)
// and removed; the stroke is cut where it enters and leaves, and pieces shorter than `minimumLength` are dropped.

const EPSILON = 1e-9;

/** The strokes after erasing along `path`, or null when the eraser touched none of them ([] = everything erased). */
export function eraseStrokes(strokes, path, radius, minimumLength = 1) {
  const track = points(path);
  if (!track.length || radius <= 0) return null;
  const capsules = track.length === 1 ? [[track[0], track[0]]] : track.slice(1).map((p, i) => [track[i], p]);
  let [l, b, r, t] = bounds(track);
  l -= radius; b -= radius; r += radius; t += radius;
  const result = [];
  let changed = false;
  for (const flat of strokes) {
    const stroke = points(flat);
    if (!stroke.length) { result.push(flat); continue; }
    const [sl, sb, sr, st] = bounds(stroke);
    const pieces = sr < l || sl > r || st < b || sb > t ? null : cut(stroke, capsules, radius, minimumLength);
    if (!pieces) { result.push(flat); continue; }
    changed = true;
    for (const piece of pieces) result.push(piece.flat());
  }
  return changed ? result : null;
}

function cut(stroke, capsules, radius, minimumLength) {
  if (stroke.length === 1) return capsules.some(([c, d]) => distance(stroke[0], c, d) <= radius) ? [] : null;
  const pieces = [];
  let current = [];
  let touched = false;
  const flush = () => { if (current.length > 1) pieces.push(current); current = []; };
  for (let i = 0; i + 1 < stroke.length; i++) {
    const a = stroke[i], b = stroke[i + 1];
    const removed = merge(capsules.map(([c, d]) => interval(a, b, c, d, radius)).filter(Boolean));
    if (!removed.length) {
      if (!current.length) current.push(a);
      current.push(b);
      continue;
    }
    touched = true;
    const segment = Math.hypot(b[0] - a[0], b[1] - a[1]);
    const kept = complement(removed).filter(([low, high]) => (high - low) * segment > 1e-6);
    const startsAtA = kept.length > 0 && kept[0][0] <= EPSILON;
    if (!startsAtA) flush();
    kept.forEach(([low, high], k) => {
      const start = low <= EPSILON ? a : lerp(a, b, low);
      const end = high >= 1 - EPSILON ? b : lerp(a, b, high);
      if (k === 0 && startsAtA && current.length) current.push(end);
      else { flush(); current = [start, end]; }
      if (high < 1 - EPSILON) flush();
    });
  }
  flush();
  if (!touched) return null;
  return pieces.filter((p) => length(p) >= minimumLength);
}

function length(stroke) {
  let total = 0;
  for (let i = 0; i + 1 < stroke.length; i++) total += Math.hypot(stroke[i + 1][0] - stroke[i][0], stroke[i + 1][1] - stroke[i][1]);
  return total;
}

const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];

function merge(intervals) {
  const result = [];
  for (const next of intervals.sort((x, y) => x[0] - y[0])) {
    const last = result[result.length - 1];
    if (last && next[0] <= last[1]) last[1] = Math.max(last[1], next[1]);
    else result.push([...next]);
  }
  return result;
}

function complement(removed) {
  const result = [];
  let start = 0;
  for (const [low, high] of removed) {
    if (low > start) result.push([start, low]);
    start = Math.max(start, high);
  }
  if (start < 1) result.push([start, 1]);
  return result;
}

/** The part (parameters 0…1 of a→b) of the segment a→b within r of the segment c→d, or null. */
function interval(a, b, c, d, r) {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  if (dx * dx + dy * dy < 1e-18) return distance(a, c, d) <= r ? [0, 1] : null;
  let low = Infinity, high = -Infinity;
  for (const centre of [c, d]) {
    const disc = discSpan(a, dx, dy, centre, r);
    if (disc) { low = Math.min(low, disc[0]); high = Math.max(high, disc[1]); }
  }
  const band = bandSpan(a, dx, dy, c, d, r);
  if (band) { low = Math.min(low, band[0]); high = Math.max(high, band[1]); }
  const lower = Math.max(low, 0), upper = Math.min(high, 1);
  return lower <= upper ? [lower, upper] : null;
}

function discSpan(a, dx, dy, centre, r) {
  const fx = a[0] - centre[0], fy = a[1] - centre[1];
  const qa = dx * dx + dy * dy, qb = 2 * (fx * dx + fy * dy), qc = fx * fx + fy * fy - r * r;
  const discriminant = qb * qb - 4 * qa * qc;
  if (discriminant < 0) return null;
  const root = Math.sqrt(discriminant);
  return [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)];
}

function bandSpan(a, dx, dy, c, d, r) {
  const ex = d[0] - c[0], ey = d[1] - c[1];
  const len = Math.hypot(ex, ey);
  if (len <= 1e-9) return null;
  const ux = ex / len, uy = ey / len;
  const fx = a[0] - c[0], fy = a[1] - c[1];
  const along = linear(fx * ux + fy * uy, dx * ux + dy * uy, 0, len);
  const across = linear(fx * uy - fy * ux, dx * uy - dy * ux, -r, r);
  if (!along || !across) return null;
  const lower = Math.max(along[0], across[0]), upper = Math.min(along[1], across[1]);
  return lower <= upper ? [lower, upper] : null;
}

function linear(v0, v1, low, high) {
  if (Math.abs(v1) < 1e-12) return v0 >= low && v0 <= high ? [-1e12, 1e12] : null;
  const t1 = (low - v0) / v1, t2 = (high - v0) / v1;
  return [Math.min(t1, t2), Math.max(t1, t2)];
}

function distance(p, c, d) {
  const ex = d[0] - c[0], ey = d[1] - c[1];
  const lengthSquared = ex * ex + ey * ey;
  const t = lengthSquared > 0 ? Math.min(1, Math.max(0, ((p[0] - c[0]) * ex + (p[1] - c[1]) * ey) / lengthSquared)) : 0;
  return Math.hypot(p[0] - (c[0] + t * ex), p[1] - (c[1] + t * ey));
}

function points(flat) {
  const list = [];
  for (let i = 0; i + 1 < flat.length; i += 2) list.push([flat[i], flat[i + 1]]);
  return list;
}

function bounds(list) {
  let l = Infinity, b = Infinity, r = -Infinity, t = -Infinity;
  for (const [x, y] of list) { l = Math.min(l, x); r = Math.max(r, x); b = Math.min(b, y); t = Math.max(t, y); }
  return [l, b, r, t];
}
