// O painel dos filtros do Explorar: prova, dias e época, cada opção com
// quantas viagens tem, e os destinos mais publicados. O mesmo painel serve a
// coluna da direita no PC e a folha "Filtros" no telemóvel.
import { el, icon } from '../../app.js';
import { DAY_LABEL, DAY_SPANS, feedFacets, MONTHS } from '../../data/feed.js';

export const LEVELS = [['', 'Tudo'], ['original', 'GPS verificado'], ['done', 'Feitas'], ['plan', 'Roteiros']];
const LEVEL_KEY = { '': 'all', original: 'original', done: 'done', plan: 'plan' };

/** Quantos filtros estão ligados (a prova, os dias e o mês; a procura não conta). */
export function activeCount(s) {
  return (s.level ? 1 : 0) + (s.days ? 1 : 0) + (s.month ? 1 : 0);
}

/**
 * @param {{ go: (next: object) => void, onPick?: () => void }} opts
 *   onPick corre depois de cada escolha (a folha do telemóvel não fecha: a
 *   pessoa pode escolher mais do que uma coisa).
 */
export function filterPanel({ go, onPick }) {
  let facts = null;
  let asked = 0;
  let last = null;
  const pick = (next) => { go(next); onPick?.(); };

  const count = (n) => el('span', { class: 'count' }, n === undefined || n === null ? '' : String(n));
  const option = (label, pressed, n, onclick) => el('button', {
    class: 'opt', type: 'button', 'aria-pressed': String(pressed), onclick,
  }, el('span', {}, label), count(n));

  const levelGroup = el('div', { class: 'opts', role: 'group', 'aria-labelledby': 'f-level' });
  const dayGroup = el('div', { class: 'opts', role: 'group', 'aria-labelledby': 'f-days' });
  const monthGroup = el('div', { class: 'opts months', role: 'group', 'aria-labelledby': 'f-month' });
  const monthTitle = el('h3', { id: 'f-month' }, 'Época');
  const places = el('ul', { class: 'places' });
  const clear = el('button', { class: 'btn quiet small-btn', type: 'button', hidden: true, onclick: () => pick({ level: '', days: '', month: null }) }, 'Limpar filtros');
  const node = el('div', { class: 'filter-panel' },
    el('h3', { id: 'f-level' }, 'Prova'), levelGroup,
    el('h3', { id: 'f-days' }, 'Dias'), dayGroup,
    monthTitle, monthGroup);

  function paint(s) {
    last = s;
    const lv = facts?.levels ?? {};
    levelGroup.replaceChildren(...LEVELS.map(([key, label]) =>
      option(label, s.level === key, lv[LEVEL_KEY[key]], () => pick({ level: key }))));
    const d = facts?.days ?? {};
    dayGroup.replaceChildren(
      option('Qualquer duração', !s.days, lv.all, () => pick({ days: '' })),
      ...DAY_SPANS.map((span) => option(DAY_LABEL[span], s.days === span, d[span], () => pick({ days: s.days === span ? '' : span }))));
    // Só os meses em que há viagens; o mês escolhido aparece sempre, para se poder tirar.
    const m = facts?.months ?? {};
    const months = [...new Set([...Object.keys(m).map(Number), ...(s.month ? [s.month] : [])])].sort((a, b) => a - b);
    monthGroup.replaceChildren(...months.map((n) =>
      option(MONTHS[n - 1], s.month === n, m[n] ?? 0, () => pick({ month: s.month === n ? null : n }))));
    monthTitle.hidden = !months.length;
    clear.hidden = !activeCount(s);
    const top = facts?.destinations ?? [];
    const same = (p) => s.words.toLowerCase() === String(p.name).toLowerCase();
    places.replaceChildren(...top.map((p) => el('li', {},
      el('button', { class: 'place', type: 'button', 'aria-pressed': String(same(p)), onclick: () => pick({ words: same(p) ? '' : p.name }) },
        icon('pin'), el('span', {}, p.name), count(p.n)))));
  }

  async function facets(s) {
    const mine = ++asked;
    const data = await feedFacets(s.words);
    if (mine !== asked) return;
    facts = data;
    paint(last ?? s);
  }

  return { node, places, clear, paint, facets, hasPlaces: () => Boolean(facts?.destinations?.length), destinations: () => facts?.destinations ?? [] };
}
