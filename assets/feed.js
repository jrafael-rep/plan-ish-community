import { $, el, explain, header, notice, sb } from './app.js';
import { BASIC_COLUMNS, CARD_COLUMNS, likedSet, missingColumn, tripCard } from './card.js';

const session = await header('feed');
const status = $('status');
const feed = $('feed');

const EMPTY = {
  '': 'Ainda não há viagens publicadas. A primeira pode ser a tua: no Plan-ish, abre uma viagem concluída e escolhe "Publicar na Comunidade".',
  original: 'Ainda não há viagens com GPS verificado. Aparecem quando o GPS do telemóvel confirma a maior parte das paragens.',
  done: 'Ainda não há viagens feitas com paragens marcadas à mão.',
  plan: 'Ainda não há roteiros publicados.',
};

const EMPTY_MINE = 'Ainda não tens nada aqui. Os itinerários que publicares e as viagens de que gostares aparecem neste separador.';

const PAGE = 20;
let view = 'popular';
let level = '';
let words = '';
/** Sem o esquema 11 não há feed_page: o feed lê a tabela, como antes. */
let viaServer = true;
let shown = [];
/** Only the newest request fills the feed: tabs switch faster than the network. */
let request = 0;
const more = el('button', { class: 'btn more-btn', type: 'button', hidden: true, onclick: () => void load(true) }, 'Ver mais viagens');
feed.after(more);

for (const tab of document.querySelectorAll('.tab')) {
  tab.addEventListener('click', () => {
    for (const other of document.querySelectorAll('.tab')) other.setAttribute('aria-pressed', String(other === tab));
    level = tab.dataset.level ?? '';
    void load(false);
  });
}
for (const button of document.querySelectorAll('.view')) {
  // "Meus" só com sessão: os meus e os de que gostei.
  if (button.dataset.view === 'mine') button.hidden = !session;
  button.addEventListener('click', () => {
    for (const other of document.querySelectorAll('.view')) other.setAttribute('aria-pressed', String(other === button));
    view = button.dataset.view ?? 'popular';
    void load(false);
  });
}

// Procura depois de uma pausa na escrita, não a cada letra.
let typing = 0;
$('search').addEventListener('input', () => {
  clearTimeout(typing);
  typing = setTimeout(() => {
    const next = searchTerm($('search').value);
    if (next === words) return;
    words = next;
    void load(false);
  }, 400);
});

/** Letras, números, espaços, hífenes e apóstrofos: vírgulas e parênteses mudariam o filtro. */
function searchTerm(text) {
  return text.replace(/[^\p{L}\p{N} '-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
}

await load(false);

async function load(append) {
  const mine = ++request;
  const from = append ? shown.length : 0;
  if (append) { more.disabled = true; more.textContent = 'A carregar…'; } else { notice(status, 'A carregar…'); more.hidden = true; }
  // O servidor ordena cada separador e tira o escondido e quem bloqueei; as
  // colunas e o autor pedem-se como numa leitura da tabela.
  const server = () => sb.rpc('feed_page', {
    p_tab: view, p_level: level || null, p_search: words || null, p_offset: from, p_limit: PAGE,
  }).select(CARD_COLUMNS);
  // Antes do esquema 11. O id desempata: uma página nunca repete nem salta viagens publicadas no mesmo instante.
  const table = (columns, basic) => {
    let query = sb.from('itineraries').select(columns);
    if (view === 'popular') query = query.order('like_count', { ascending: false });
    if (view === 'mine') query = query.eq('author_id', session?.user.id ?? '');
    query = query.order('created_at', { ascending: false }).order('id', { ascending: false })
      .range(from, from + PAGE - 1);
    if (level && !basic) query = query.eq('evidence', level);
    if (words) query = query.or(`title.ilike.*${words}*,destination.ilike.*${words}*`);
    return query;
  };
  let data;
  let error;
  if (viaServer) {
    ({ data, error } = await server());
    if (missingFunction(error)) viaServer = false;
  }
  if (!viaServer) {
    ({ data, error } = await table(CARD_COLUMNS, false));
    if (missingColumn(error)) ({ data, error } = await table(BASIC_COLUMNS, true));
  }
  if (mine !== request) return;
  more.disabled = false; more.textContent = 'Ver mais viagens';
  if (error) {
    if (append) { notice(status, explain(error), 'error'); return; }
    feed.replaceChildren(); notice(status, explain(error), 'error'); return;
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
}

function missingFunction(error) {
  return error?.code === 'PGRST202' || error?.code === '42883';
}
