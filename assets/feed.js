import { $, el, explain, header, notice } from './app.js';
import { likedSet, tripCard } from './card.js';
import { feedPage, feedUrl, PAGE, readFeedUrl, searchTerm } from './data/feed.js';
import { cardsLoading } from './layout/shared/skeleton.js';

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

// O estado começa no URL: um link partilhado, recarregar ou voltar atrás mostram o mesmo.
let { view, level, words } = readFeedUrl();
if (view === 'mine' && !session) view = 'popular';
let shown = [];
/** Only the newest request fills the feed: tabs switch faster than the network. */
let request = 0;
const more = el('button', { class: 'btn more-btn', type: 'button', hidden: true, onclick: () => void load(true) }, 'Ver mais viagens');
feed.after(more);

const tabs = [...document.querySelectorAll('.tab')];
const views = [...document.querySelectorAll('.view')];
const search = $('search');

/** Os botões e a pesquisa a mostrar o estado atual. */
function paint() {
  for (const tab of tabs) tab.setAttribute('aria-pressed', String((tab.dataset.level ?? '') === level));
  for (const button of views) button.setAttribute('aria-pressed', String(button.dataset.view === view));
  if (searchTerm(search.value) !== words) search.value = words;
}

/** Muda o estado, guarda-o no URL e volta a carregar. */
function go(next, { push = true } = {}) {
  ({ view, level, words } = { view, level, words, ...next });
  const url = feedUrl({ view, level, words });
  if (push) history.pushState(null, '', url); else history.replaceState(null, '', url);
  paint();
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
    if (next !== words) go({ words: next }, { push: false });
  }, 400);
});

addEventListener('popstate', () => {
  ({ view, level, words } = readFeedUrl());
  if (view === 'mine' && !session) view = 'popular';
  paint();
  void load(false);
});

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
  const { data, error } = await feedPage({ view, level, words, from, userId: session?.user.id ?? null });
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
    notice(status, words ? `Nenhuma viagem com "${words}" no título ou no destino.`
      : view === 'mine' && !level ? EMPTY_MINE : EMPTY[level] ?? EMPTY['']);
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
