// O traçado de um itinerário, maior que a capa: um traço por dia, cada dia com
// a sua cor, e um ponto por paragem com coordenadas. Só usa as coordenadas que
// o itinerário já mostra (as paragens privadas nunca são publicadas).
//
// Cada ponto tem data-stop="dia-paragem", como a linha da paragem na lista
// (card.js, dayList): quem monta a página liga os dois.

export const DAY_COLORS = ['#0B7A84', '#2F6FD6', '#B4499A', '#C2571A', '#2E8B57', '#7B5CD6', '#A23B3B'];

const NS = 'http://www.w3.org/2000/svg';
const svgEl = (tag, attrs = {}) => {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  return node;
};

/** Os pontos com coordenadas, por dia. */
export function placedStops(plan) {
  const days = Array.isArray(plan?.days) ? plan.days : [];
  return days.map((day, i) => (Array.isArray(day.stops) ? day.stops : [])
    .map((s, j) => ({ day: i, key: `${i}-${j}`, name: s.name ?? '', lat: s.lat, lon: s.lon }))
    .filter((s) => Number.isFinite(s.lat) && Number.isFinite(s.lon)));
}

/**
 * O SVG do traçado, ou null se houver menos de dois pontos.
 * @returns {SVGSVGElement | null}
 */
export function routeMap(plan, { width = 560, height = 420 } = {}) {
  const byDay = placedStops(plan);
  const all = byDay.flat();
  if (all.length < 2) return null;
  const k = Math.cos((all.reduce((n, p) => n + p.lat, 0) / all.length) * Math.PI / 180);
  const xs = all.map((p) => p.lon * k);
  const ys = all.map((p) => -p.lat);
  const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const pad = 36;
  const scale = Math.min((width - 2 * pad) / Math.max(x1 - x0, 1e-6), (height - 2 * pad) / Math.max(y1 - y0, 1e-6));
  const cx = (x0 + x1) / 2;
  const cy = (y0 + y1) / 2;
  const at = (p) => [width / 2 + (p.lon * k - cx) * scale, height / 2 + (-p.lat - cy) * scale].map((v) => Number(v.toFixed(1)));

  const svg = svgEl('svg', { class: 'route-map', viewBox: `0 0 ${width} ${height}`, role: 'img' });
  const title = svgEl('title');
  title.textContent = `Traçado de ${plan.days.length === 1 ? '1 dia' : `${plan.days.length} dias`}, ${all.length} paragens com local`;
  svg.append(title);
  // O caminho entre dias (do fim de um ao início do seguinte), discreto.
  let last = null;
  for (const stops of byDay) {
    if (!stops.length) continue;
    if (last) {
      const [a, b] = [at(last), at(stops[0])];
      svg.append(svgEl('line', { class: 'hop', x1: a[0], y1: a[1], x2: b[0], y2: b[1] }));
    }
    last = stops[stops.length - 1];
  }
  byDay.forEach((stops, day) => {
    if (!stops.length) return;
    const color = DAY_COLORS[day % DAY_COLORS.length];
    const g = svgEl('g', { class: 'leg', 'data-day': day });
    // Pela CSSOM: a CSP do site não deixa atributos style.
    g.style.setProperty('--day', color);
    if (stops.length > 1) {
      g.append(svgEl('polyline', { points: stops.map((p) => at(p).join(',')).join(' ') }));
    }
    for (const p of stops) {
      const [x, y] = at(p);
      const dot = svgEl('circle', { cx: x, cy: y, r: 6, 'data-stop': p.key });
      const t = svgEl('title');
      t.textContent = `Dia ${day + 1}: ${p.name}`;
      dot.append(t);
      g.append(dot);
    }
    svg.append(g);
  });
  return svg;
}
