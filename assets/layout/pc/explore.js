// Explorar no PC e no tablet: a navegação à esquerda (só PC) e o painel dos
// filtros à direita, com quantas viagens há em cada opção e os destinos que
// mais aparecem. O feed ao centro é o mesmo de sempre (assets/feed.js).
import { el, icon } from '../../app.js';
import { DAY_LABEL, DAY_SPANS, feedFacets, MONTHS } from '../../data/feed.js';

const LEVELS = [['', 'Tudo'], ['original', 'GPS verificado'], ['done', 'Feitas'], ['plan', 'Roteiros']];
const LEVEL_KEY = { '': 'all', original: 'original', done: 'done', plan: 'plan' };

/**
 * Monta as colunas laterais à volta do feed.
 * @param {{ state: object, go: (next: object) => void, session: object | null }} opts
 */
export function mountExplore({ state, go, session }) {
  const shell = document.querySelector('.explore');
  let facts = null;
  let asked = 0;

  const count = (n) => el('span', { class: 'count' }, n === undefined || n === null ? '' : String(n));
  const option = (label, pressed, n, onclick) => el('button', {
    class: 'opt', type: 'button', 'aria-pressed': String(pressed), onclick,
  }, el('span', {}, label), count(n));

  const levelGroup = el('div', { class: 'opts', role: 'group', 'aria-labelledby': 'f-level' });
  const dayGroup = el('div', { class: 'opts', role: 'group', 'aria-labelledby': 'f-days' });
  const monthGroup = el('div', { class: 'opts months', role: 'group', 'aria-labelledby': 'f-month' });
  const places = el('ul', { class: 'places' });
  const clear = el('button', { class: 'btn quiet small-btn', type: 'button', hidden: true, onclick: () => go({ level: '', days: '', month: null }) }, 'Limpar filtros');

  const rail = el('aside', { class: 'explore-rail', 'aria-label': 'Filtros' },
    el('div', { class: 'rail-card' },
      el('div', { class: 'rail-head' }, el('h2', {}, 'Filtrar'), clear),
      el('h3', { id: 'f-level' }, 'Prova'), levelGroup,
      el('h3', { id: 'f-days' }, 'Dias'), dayGroup,
      el('h3', { id: 'f-month', class: 'month-title' }, 'Época'), monthGroup),
    el('div', { class: 'rail-card places-card', hidden: true },
      el('h2', {}, 'Destinos mais publicados'), places),
    el('div', { class: 'rail-card note' },
      el('h2', {}, icon('shield'), 'GPS verificado'),
      el('p', {}, 'O GPS do telemóvel confirmou a maior parte das paragens: a viagem foi mesmo feita assim. "Feitas" foram marcadas à mão; "Roteiros" são planos.')));

  const me = session?.user.id;
  const navLink = (href, label, iconName, current) => el('a', { href, class: 'nav-item', 'aria-current': current ? 'page' : undefined }, icon(iconName), label);
  const nav = el('nav', { class: 'explore-nav', 'aria-label': 'Comunidade' },
    navLink('./', 'Explorar', 'map', true),
    me ? navLink(`viajante.html?id=${encodeURIComponent(me)}`, 'O meu perfil', 'users') : null,
    me ? navLink('conta.html', 'Conta', 'wallet') : null,
    el('hr'),
    el('p', { class: 'nav-note' }, 'O plano e a viagem vivem no telemóvel, na app Plan-ish.'),
    el('a', { class: 'nav-item', href: 'https://jrafael-rep.github.io/plan-ish-releases/' }, icon('route'), 'Conhecer a app'),
    el('button', { class: 'nav-item', type: 'button', 'data-keys-help': '', 'aria-keyshortcuts': 'Shift+?' }, icon('info'), 'Atalhos de teclado'));

  shell.prepend(nav);
  shell.append(rail);
  shell.classList.add('wide');

  function paint(s) {
    const lv = facts?.levels ?? {};
    levelGroup.replaceChildren(...LEVELS.map(([key, label]) =>
      option(label, s.level === key, lv[LEVEL_KEY[key]], () => go({ level: key }))));
    const d = facts?.days ?? {};
    dayGroup.replaceChildren(
      option('Qualquer duração', !s.days, lv.all, () => go({ days: '' })),
      ...DAY_SPANS.map((span) => option(DAY_LABEL[span], s.days === span, d[span], () => go({ days: s.days === span ? '' : span }))));
    // Só os meses em que há viagens; o mês escolhido aparece sempre, para se poder tirar.
    const m = facts?.months ?? {};
    const months = [...new Set([...Object.keys(m).map(Number), ...(s.month ? [s.month] : [])])].sort((a, b) => a - b);
    monthGroup.replaceChildren(...months.map((n) =>
      option(MONTHS[n - 1], s.month === n, m[n] ?? 0, () => go({ month: s.month === n ? null : n }))));
    rail.querySelector('.month-title').hidden = !months.length;
    clear.hidden = !(s.level || s.days || s.month);
    const top = facts?.destinations ?? [];
    places.replaceChildren(...top.map((p) => el('li', {},
      el('button', { class: 'place', type: 'button', 'aria-pressed': String(s.words.toLowerCase() === String(p.name).toLowerCase()), onclick: () => go({ words: s.words.toLowerCase() === String(p.name).toLowerCase() ? '' : p.name }) },
        icon('pin'), el('span', {}, p.name), count(p.n)))));
    places.closest('.rail-card').hidden = !top.length;
  }

  async function facets(s) {
    const mine = ++asked;
    const data = await feedFacets(s.words);
    if (mine !== asked || !rail.isConnected) return;
    facts = data;
    paint(s);
  }

  paint(state);
  return {
    paint,
    facets,
    unmount() { nav.remove(); rail.remove(); shell.classList.remove('wide'); },
  };
}
