import { $, el, explain, header, notice } from './app.js';
import { likedSet, tripCard } from './card.js';
import { DAY_LABEL, feedPage, feedUrl, MONTHS, PAGE, readFeedUrl, searchTerm } from './data/feed.js';
import { cardsLoading } from './layout/shared/skeleton.js';
import { mountExplore } from './layout/pc/explore.js';
import { mountMobileExplore } from './layout/mobile/explore.js';
import { feedKeys } from './layout/pc/keys.js';

const session = await header('feed');
const status = $('status');
const feed = $('feed');
// O que mudou, dito a quem usa leitor de ecrã (o feed muda sem recarregar).
const said = $('said');

const EMPTY = {
  '': 'Ainda não há viagens publicadas. A primeira pode ser a tua: no Plan-ish, abre uma viagem concluída e escolhe "Publicar na Comunidade".',
  original: 'Ainda não há viagens com GPS verificado. Aparecem quando o GPS do telemóvel confirma a maior parte das paragens.',
  done: 'Ainda não há viagens feitas com paragens marcadas à mão.',
  plan: 'Ainda não há roteiros publicados.',
};

const EMPTY_MINE = 'Ainda não tens nada aqui. Os itinerários que publicares e as viagens de que gostares aparecem neste separador.';

/** O estado do feed. Começa no URL: um link partilhado, recarregar ou voltar atrás mostram o mesmo. */
const state = fromUrl();
function fromUrl() {
  const s = readFeedUrl();
  if (s.view === 'mine' && !session) s.view = 'popular';
  return s;
}
let shown = [];
/** Only the newest request fills the feed: tabs switch faster than the network. */
let request = 0;
const more = el('button', { class: 'btn more-btn', type: 'button', hidden: true, onclick: () => void load(true) }, 'Ver mais viagens');
feed.after(more);

const tabs = [...document.querySelectorAll('.tab')];
const views = [...document.querySelectorAll('.view')];
const search = $('search');
const active = $('active-filters');

/** Os filtros de dias e de mês que vieram no URL, com um ✕ (o telemóvel ainda não tem o painel). */
function activeChips() {
  const chip = (text, clear) => el('button', { class: 'chip-clear', type: 'button', 'aria-label': `Tirar o filtro ${text}`, onclick: () => go(clear) },
    text, el('span', { 'aria-hidden': 'true' }, '✕'));
  const LEVEL_NAME = { original: 'GPS verificado', done: 'Feitas', plan: 'Roteiros' };
  active.replaceChildren(...[
    state.level ? chip(LEVEL_NAME[state.level], { level: '' }) : null,
    state.days ? chip(DAY_LABEL[state.days], { days: '' }) : null,
    state.month ? chip(MONTHS[state.month - 1], { month: null }) : null,
  ].filter(Boolean));
}

/** Os botões e a pesquisa a mostrar o estado atual. */
function paint() {
  for (const tab of tabs) tab.setAttribute('aria-pressed', String((tab.dataset.level ?? '') === state.level));
  for (const button of views) button.setAttribute('aria-pressed', String(button.dataset.view === state.view));
  if (searchTerm(search.value) !== state.words) search.value = state.words;
  activeChips();
  explore?.paint(state);
  mobile?.paint(state);
}

/** Muda o estado, guarda-o no URL e volta a carregar. */
function go(next, { push = true } = {}) {
  const wordsBefore = state.words;
  Object.assign(state, next);
  const url = feedUrl(state);
  if (push) history.pushState(null, '', url); else history.replaceState(null, '', url);
  paint();
  if (state.words !== wordsBefore) { explore?.facets(state); mobile?.facets(state); }
  void load(false);
}

for (const tab of tabs) tab.addEventListener('click', () => go({ level: tab.dataset.level ?? '' }));
for (const button of views) {
  // "Meus" só com sessão: os meus e os de que gostei.
  if (button.dataset.view === 'mine') button.hidden = !session;
  button.addEventListener('click', () => go({ view: button.dataset.view ?? 'popular' }));
}

// Procura depois de uma pausa na escrita, não a cada letra. A escrita não
// enche o histórico: cada letra substitui a anterior.
let typing = 0;
search.addEventListener('input', () => {
  clearTimeout(typing);
  typing = setTimeout(() => {
    const next = searchTerm(search.value);
    if (next !== state.words) go({ words: next }, { push: false });
  }, 400);
});

addEventListener('popstate', () => {
  const wordsBefore = state.words;
  const next = fromUrl();
  // Fechar uma folha (telemóvel) também volta atrás no histórico, sem mudar o feed.
  if (feedUrl(next) === feedUrl(state)) return;
  Object.assign(state, next);
  paint();
  if (state.words !== wordsBefore) { explore?.facets(state); mobile?.facets(state); }
  void load(false);
});

/*
  O PC e o tablet têm o painel dos filtros e a navegação ao lado; o telemóvel
  não os desenha (nem pede as contagens). Cruzar o limite monta ou desmonta.
*/
let explore = null;
let mobile = null;
let keys = null;
function arrange(layout) {
  const wide = layout === 'pc' || layout === 'tablet';
  // Nas folhas do telemóvel, cada escolha substitui a entrada da folha no
  // histórico: Voltar depois de fechar regressa ao feed de antes, de uma vez.
  if (layout === 'mobile' && !mobile) mobile = mountMobileExplore({ state, go: (next) => go(next, { push: false }) });
  else if (layout !== 'mobile' && mobile) { mobile.unmount(); mobile = null; }
  if (wide && !explore) {
    explore = mountExplore({ state, go, session });
    explore.facets(state);
  } else if (!wide && explore) {
    explore.unmount();
    explore = null;
  }
  if (layout === 'pc' && !keys) keys = feedKeys({ feed, search });
  else if (layout !== 'pc' && keys) { keys.stop(); keys = null; }
}
arrange(document.documentElement.dataset.layout);
addEventListener('planish:layout', (e) => arrange(e.detail));

paint();
await load(false);

async function load(append) {
  const mine = ++request;
  const from = append ? shown.length : 0;
  if (append) {
    more.disabled = true; more.textContent = 'A carregar…';
  } else {
    status.replaceChildren();
    more.hidden = true;
    feed.setAttribute('aria-busy', 'true');
    feed.replaceChildren(cardsLoading(2));
  }
  const { view, level, words, days, month } = state;
  const { data, error } = await feedPage({ view, level, words, days, month, from, userId: session?.user.id ?? null });
  if (mine !== request) return;
  feed.removeAttribute('aria-busy');
  more.disabled = false; more.textContent = 'Ver mais viagens';
  if (error) {
    if (!append) feed.replaceChildren();
    notice(status, explain(error), 'error');
    return;
  }
  if (!append && !data.length) {
    feed.replaceChildren();
    if (words || days || month) {
      const what = words && !days && !month ? `Nenhuma viagem com "${words}" no título ou no destino.` : 'Nenhuma viagem com estes filtros.';
      status.replaceChildren(el('div', { class: 'notice empty', role: 'status' },
        el('p', {}, what),
        el('button', { class: 'btn', type: 'button', onclick: () => go({ words: '', level: '', days: '', month: null }) },
          'Ver todas as viagens')));
    } else {
      notice(status, view === 'mine' && !level ? EMPTY_MINE : EMPTY[level] ?? EMPTY['']);
    }
    said.textContent = 'Nenhuma viagem.';
    return;
  }
  const liked = await likedSet(session, data.map((it) => it.id));
  if (mine !== request) return;
  status.replaceChildren();
  const seen = new Set(append ? shown.map((it) => it.id) : []);
  const fresh = data.filter((it) => !seen.has(it.id));
  shown = append ? [...shown, ...fresh] : fresh;
  const cards = fresh.map((it) => tripCard(it, { session, liked: liked.has(it.id) }));
  if (append) feed.append(...cards); else feed.replaceChildren(...cards);
  more.hidden = data.length < PAGE;
  said.textContent = append
    ? `Mais ${fresh.length === 1 ? '1 viagem' : `${fresh.length} viagens`}.`
    : `${shown.length === 1 ? '1 viagem' : `${shown.length} viagens`}${words ? ` com "${words}"` : ''}.`;
}
