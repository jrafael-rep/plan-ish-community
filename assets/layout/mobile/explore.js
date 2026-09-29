// Explorar no telemóvel: os filtros numa folha ("Filtros · 2") em vez de uma
// fila de fichas cortada, e Procurar como ecrã próprio, com as pesquisas
// recentes (guardadas só neste telemóvel) e os destinos mais publicados.
import { el, icon } from '../../app.js';
import { searchTerm } from '../../data/feed.js';
import { activeCount, filterPanel } from '../shared/filters.js';
import { openSheet } from './sheet.js';

const RECENT_KEY = 'planish.recentSearches';

function recentSearches() {
  try { return JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]').filter((w) => typeof w === 'string').slice(0, 6); } catch { return []; }
}
function rememberSearch(words) {
  if (!words) return;
  try {
    const list = [words, ...recentSearches().filter((w) => w.toLowerCase() !== words.toLowerCase())].slice(0, 6);
    localStorage.setItem(RECENT_KEY, JSON.stringify(list));
  } catch { /* sem armazenamento: não se lembra */ }
}

export function mountMobileExplore({ state, go }) {
  const top = document.querySelector('.feed-top');
  const panel = filterPanel({ go });
  let last = state;
  let sheet = null;

  const badgeCount = el('span', { class: 'filter-count' });
  const filtersBtn = el('button', { class: 'btn filters-btn', type: 'button', 'aria-haspopup': 'dialog', onclick: () => openFilters() },
    icon('sliders'), el('span', {}, 'Filtros'), badgeCount);
  const searchBtn = el('button', { class: 'btn search-btn', type: 'button', 'aria-haspopup': 'dialog', onclick: () => openSearch() },
    icon('search'), el('span', { class: 'search-label' }, 'Procurar destino ou título'));
  const bar = el('div', { class: 'm-explore-bar' }, searchBtn, filtersBtn);
  top.querySelector('.views').after(bar);

  function openFilters() {
    const shown = el('div', { class: 'sheet-foot' },
      el('button', { class: 'btn primary', type: 'button', onclick: () => sheet?.close() }, 'Ver viagens'));
    sheet = openSheet({
      title: 'Filtros',
      content: el('div', {}, panel.node, el('div', { class: 'row end' }, panel.clear), shown),
      onClose: () => { sheet = null; },
    });
    panel.paint(last);
    void panel.facets(last);
  }

  function openSearch() {
    const input = el('input', {
      type: 'search', class: 'search', placeholder: 'Destino ou título…', autocomplete: 'off', enterkeyhint: 'search',
      'aria-label': 'Procurar viagens por destino ou título', value: last.words,
    });
    const recent = el('div', { class: 'search-group' });
    const places = el('div', { class: 'search-group' });
    const choose = (words) => {
      const w = searchTerm(words);
      rememberSearch(w);
      go({ words: w });
      s.close();
    };
    const form = el('form', { class: 'search-form', role: 'search', onsubmit: (e) => { e.preventDefault(); choose(input.value); } }, input);
    const fill = () => {
      const r = recentSearches();
      recent.replaceChildren(...(r.length ? [el('h3', {}, 'Pesquisas recentes'), el('ul', { class: 'places' }, ...r.map((w) =>
        el('li', {}, el('button', { class: 'place', type: 'button', onclick: () => choose(w) }, icon('search'), el('span', {}, w)))))] : []));
      const top = panel.destinations();
      places.replaceChildren(...(top.length ? [el('h3', {}, 'Destinos mais publicados'), el('ul', { class: 'places' }, ...top.map((p) =>
        el('li', {}, el('button', { class: 'place', type: 'button', onclick: () => choose(p.name) }, icon('pin'), el('span', {}, p.name), el('span', { class: 'count' }, String(p.n))))))] : []));
    };
    const s = openSheet({ title: 'Procurar', full: true, content: el('div', {}, form, recent, places) });
    fill();
    void panel.facets(last).then(fill);
    input.focus();
  }

  const onSearch = () => openSearch();
  addEventListener('planish:search', onSearch);
  // Um link de "Procurar" noutra página traz ?procurar=1: abre já a pesquisa.
  const url = new URL(location.href);
  if (url.searchParams.has('procurar')) {
    url.searchParams.delete('procurar');
    history.replaceState(null, '', url.pathname + url.search + url.hash);
    queueMicrotask(openSearch);
  }

  function paint(s) {
    last = s;
    const n = activeCount(s);
    badgeCount.textContent = n ? String(n) : '';
    filtersBtn.setAttribute('aria-label', n ? `Filtros, ${n} ligados` : 'Filtros');
    filtersBtn.classList.toggle('on', n > 0);
    searchBtn.querySelector('.search-label').textContent = s.words || 'Procurar destino ou título';
    searchBtn.classList.toggle('on', Boolean(s.words));
    if (sheet) panel.paint(s);
  }
  paint(state);

  return {
    paint,
    facets: (s) => (sheet ? panel.facets(s) : Promise.resolve()),
    unmount() { bar.remove(); removeEventListener('planish:search', onSearch); sheet?.close(); },
  };
}
