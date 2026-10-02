// Painel da Comunidade: só para quem está em private.admins. Uma chamada,
// admin_metrics(dias), traz tudo; esta página só desenha.
//
// Os gráficos são uma série cada (um número por dia), por isso não levam
// legenda: o título diz o que é. Barras finas na cor de destaque, com o
// valor ao passar o dedo ou o rato, e a tabela com os números por baixo.
import { $, el, explain, header, notice, sb, show, signInLink } from './app.js';
import { mountPublish } from './admin-publish.js';

const session = await header('');
const status = $('status');
let days = 30;

const TILES = [
  ['accounts', 'Contas', 'na Comunidade'],
  ['apps_linked', 'Apps ligadas', (t) => `${t.apps_active_30d} usadas nos últimos 30 dias`],
  ['itineraries', 'Itinerários publicados', (t) => `de ${t.authors} ${t.authors === 1 ? 'autor' : 'autores'}`],
  ['views', 'Itinerários vistos', 'na app e no site, desde que se conta'],
  ['copies', 'Cópias para planear', 'na app, desde que se conta'],
  ['completions', 'Viagens feitas', 'a partir de um itinerário'],
  ['likes', 'Gostos', ''],
  ['saves', 'Guardados', ''],
  ['follows', 'Pessoas a seguir', ''],
  ['reviews', 'Avaliações', ''],
  ['members', 'Membros', 'com a Comunidade ativa'],
  ['reports_open', 'Denúncias por resolver', ''],
];

// Um gráfico por série; as vistas da app e do site somam-se.
const CHARTS = [
  ['accounts', 'Contas novas'],
  ['published', 'Itinerários publicados'],
  [['app_open_feed', 'site_open_feed'], 'Feed aberto (app e site)'],
  [['app_view_itinerary', 'site_view_itinerary'], 'Itinerários vistos (app e site)'],
  ['app_copy', 'Cópias para planear'],
  ['completions', 'Viagens feitas'],
  ['likes', 'Gostos'],
  ['saves', 'Guardados'],
  ['apps_linked', 'Apps ligadas'],
];

const TOPS = [
  [(m) => merge(m.top.app_view_itinerary, m.top.site_view_itinerary), 'vistos'],
  [(m) => m.top.app_copy ?? [], 'copiados'],
  [(m) => m.top_liked, 'gostados'],
  [(m) => m.top_saved, 'guardados'],
];

const EVIDENCE = { original: 'GPS verificado', done: 'feitas', plan: 'roteiros' };
const fmt = new Intl.NumberFormat('pt-PT');
const dayFmt = new Intl.DateTimeFormat('pt-PT', { day: 'numeric', month: 'short' });

if (!session) location.replace(signInLink('painel.html'));
else {
  const { data: admin } = await sb.rpc('am_i_admin');
  if (admin !== true) notice(status, 'Esta página é só para quem gere a Comunidade.', 'error');
  else {
    for (const b of document.querySelectorAll('.admin-range [data-days]')) {
      b.addEventListener('click', () => {
        days = Number(b.dataset.days);
        for (const o of document.querySelectorAll('.admin-range [data-days]')) o.setAttribute('aria-pressed', String(o === b));
        void load();
      });
    }
    show($('publish'), true);
    mountPublish();
    await load();
  }
}

/** As contas da equipa (quem gere, a AI-ish) não entram nas contagens de pessoas. */
function team(n) {
  if (!Number.isFinite(n) || n === 0) return '';
  return n === 1 ? ' Sem 1 conta da equipa.' : ` Sem ${n} contas da equipa.`;
}

async function load() {
  const { data, error } = await sb.rpc('admin_metrics', { p_days: days });
  if (error) { notice(status, explain(error), 'error'); return; }
  status.replaceChildren();
  show($('panel'), true);
  const dates = datesFrom(data.since, data.days);
  $('span').textContent = `De ${dayFmt.format(dates[0])} a ${dayFmt.format(dates.at(-1))}.${team(data.totals.team_excluded)}`;
  $('tiles').replaceChildren(...TILES.map(([key, label, note]) => tile(data.totals, key, label, note)), evidenceTile(data.totals.by_evidence));
  $('charts').replaceChildren(...CHARTS.map(([keys, label]) => chart(label, sum(data.series, keys), dates)));
  $('funnel').replaceChildren(funnel(data.series));
  $('tops').replaceChildren(...TOPS.map(([pick, label]) => top(label, pick(data))));
}

function tile(totals, key, label, note) {
  const text = typeof note === 'function' ? note(totals) : note;
  const n = Number(totals[key] ?? 0);
  const link = key === 'reports_open' && n > 0 ? el('a', { href: 'moderacao.html' }, 'Ver') : null;
  return el('div', { class: 'adm-tile' },
    el('span', { class: 'adm-tile-label' }, label),
    el('strong', { class: 'adm-tile-value' }, fmt.format(n)),
    text || link ? el('span', { class: 'adm-tile-note' }, text ?? '', link ? ' ' : '', link) : null);
}

function evidenceTile(by) {
  const parts = Object.entries(EVIDENCE).map(([k, label]) => `${fmt.format(by?.[k] ?? 0)} ${label}`);
  return el('div', { class: 'adm-tile' },
    el('span', { class: 'adm-tile-label' }, 'Publicados por tipo'),
    el('span', { class: 'adm-tile-note' }, parts.join(' · ')));
}

function chart(label, values, dates) {
  const total = values.reduce((a, b) => a + b, 0);
  const W = 320, H = 120, top = 14, bottom = 18;
  const max = Math.max(1, ...values);
  const step = W / values.length;
  const bar = Math.max(1, step - 2);                       // 2px de intervalo entre barras
  const y = (v) => top + (H - top - bottom) * (1 - v / max);
  const base = H - bottom;
  const svg = svgEl('svg', { viewBox: `0 0 ${W} ${H}`, class: 'adm-bars', role: 'img', 'aria-label': `${label}: ${fmt.format(total)} no período` });
  svg.append(svgEl('line', { x1: 0, x2: W, y1: top, y2: top, class: 'adm-grid' }));
  svg.append(svgEl('text', { x: 0, y: top - 4, class: 'adm-axis' }, fmt.format(max)));
  const tip = el('div', { class: 'adm-bar-tip hidden', role: 'status' });
  values.forEach((v, i) => {
    const x = i * step + 1;
    if (v > 0) {
      const h = base - y(v);
      const r = Math.min(4, bar / 2, h);                     // ponta arredondada, base direita
      svg.append(svgEl('path', {
        class: 'adm-bar',
        d: `M${x},${base} v${-(h - r)} q0,${-r} ${r},${-r} h${bar - 2 * r} q${r},0 ${r},${r} v${h - r} z`,
      }));
    }
    // Zona de toque maior do que a barra: a coluna inteira.
    const hit = svgEl('rect', { x: i * step, y: 0, width: step, height: H, class: 'adm-hit', tabindex: -1 });
    const say = () => {
      tip.textContent = `${dayFmt.format(dates[i])}: ${fmt.format(v)}`;
      tip.style.left = `${((i + 0.5) / values.length) * 100}%`;
      show(tip, true);
    };
    hit.addEventListener('pointerenter', say);
    hit.addEventListener('pointerdown', say);
    svg.append(hit);
  });
  svg.append(svgEl('line', { x1: 0, x2: W, y1: base, y2: base, class: 'adm-baseline' }));
  svg.append(svgEl('text', { x: 0, y: H - 4, class: 'adm-axis' }, dayFmt.format(dates[0])));
  svg.append(svgEl('text', { x: W, y: H - 4, class: 'adm-axis end' }, dayFmt.format(dates.at(-1))));
  const frame = el('div', { class: 'adm-bars-frame' }, svg, tip);
  frame.addEventListener('pointerleave', () => show(tip, false));
  const rows = values.map((v, i) => el('tr', {}, el('td', {}, dayFmt.format(dates[i])), el('td', {}, fmt.format(v)))).reverse();
  return el('figure', { class: 'adm-chart' },
    el('figcaption', {}, el('span', {}, label), el('strong', {}, fmt.format(total))),
    frame,
    el('details', {}, el('summary', {}, 'Ver os números'),
      el('table', {}, el('thead', {}, el('tr', {}, el('th', {}, 'Dia'), el('th', {}, 'Número'))), el('tbody', {}, ...rows))));
}

function funnel(series) {
  const total = (keys) => sum(series, keys).reduce((a, b) => a + b, 0);
  const steps = [
    ['Itinerários vistos', total(['app_view_itinerary', 'site_view_itinerary'])],
    ['Copiados para planear', total('app_copy')],
    ['Viagens feitas', total('completions')],
    ['Publicados', total('published')],
  ];
  const first = steps[0][1];
  return el('ol', { class: 'adm-funnel' }, ...steps.map(([label, n], i) => el('li', {},
    el('span', {}, label),
    el('strong', {}, fmt.format(n)),
    i > 0 && first > 0 ? el('span', { class: 'muted small' }, `${Math.round((n / first) * 100)}% das vistas`) : null)));
}

function top(label, items) {
  const list = items ?? [];
  return el('div', { class: 'adm-top-list' },
    el('h3', {}, label[0].toUpperCase() + label.slice(1)),
    list.length
      ? el('ol', {}, ...list.slice(0, 5).map((it) => el('li', {},
        el('a', { href: `itinerario.html?id=${encodeURIComponent(it.id)}` }, it.title),
        el('span', { class: 'muted small' }, ` ${fmt.format(it.n)}`))))
      : el('p', { class: 'muted small' }, 'Ainda nada.'));
}

function sum(series, keys) {
  const list = (Array.isArray(keys) ? keys : [keys]).map((k) => series[k] ?? []);
  const len = Math.max(0, ...list.map((s) => s.length));
  return Array.from({ length: len }, (_, i) => list.reduce((a, s) => a + Number(s[i] ?? 0), 0));
}

function merge(...lists) {
  const byId = new Map();
  for (const it of lists.flat().filter(Boolean)) {
    const was = byId.get(it.id);
    byId.set(it.id, { ...it, n: (was?.n ?? 0) + it.n });
  }
  return [...byId.values()].sort((a, b) => b.n - a.n);
}

function datesFrom(since, n) {
  const [y, m, d] = since.split('-').map(Number);
  return Array.from({ length: n }, (_, i) => new Date(y, m - 1, d + i));
}

function svgEl(tag, attrs = {}, text) {
  const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  if (text != null) node.textContent = text;
  return node;
}
