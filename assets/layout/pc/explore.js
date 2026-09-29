// Explorar no PC e no tablet: a navegação à esquerda (só PC) e o painel dos
// filtros à direita, com quantas viagens há em cada opção e os destinos que
// mais aparecem. O feed ao centro é o mesmo de sempre (assets/feed.js).
// No telemóvel, o mesmo painel vive numa folha (layout/mobile/explore.js).
import { el, icon } from '../../app.js';
import { filterPanel } from '../shared/filters.js';


/**
 * Monta as colunas laterais à volta do feed.
 * @param {{ state: object, go: (next: object) => void, session: object | null }} opts
 */
export function mountExplore({ state, go, session }) {
  const shell = document.querySelector('.explore');
  const panel = filterPanel({ go });

  const rail = el('aside', { class: 'explore-rail', 'aria-label': 'Filtros' },
    el('div', { class: 'rail-card' },
      el('div', { class: 'rail-head' }, el('h2', {}, 'Filtrar'), panel.clear),
      panel.node),
    el('div', { class: 'rail-card places-card', hidden: true },
      el('h2', {}, 'Destinos mais publicados'), panel.places),
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

  const paint = (s) => {
    panel.paint(s);
    panel.places.closest('.rail-card').hidden = !panel.hasPlaces();
  };
  paint(state);
  return {
    paint,
    async facets(s) { await panel.facets(s); if (rail.isConnected) paint(s); },
    unmount() { nav.remove(); rail.remove(); shell.classList.remove('wide'); },
  };
}
