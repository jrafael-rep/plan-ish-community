import { $, explain, header, notice, sb } from './app.js';
import { CARD_COLUMNS, likedSet, tripCard } from './card.js';

const session = await header('feed');
const status = $('status');
const feed = $('feed');

const EMPTY = {
  '': 'Ainda não há viagens publicadas. A primeira pode ser a tua: no Plan-ish, abre uma viagem concluída e escolhe "Publicar na Comunidade".',
  original: 'Ainda não há viagens com GPS verificado. Aparecem quando o GPS do telemóvel confirma a maior parte das paragens.',
  done: 'Ainda não há viagens feitas com paragens marcadas à mão.',
  plan: 'Ainda não há roteiros publicados.',
};

for (const tab of document.querySelectorAll('.tab')) {
  tab.addEventListener('click', () => {
    for (const other of document.querySelectorAll('.tab')) other.setAttribute('aria-pressed', String(other === tab));
    void load(tab.dataset.level ?? '');
  });
}
await load('');

async function load(level) {
  notice(status, 'A carregar…');
  let query = sb.from('itineraries').select(CARD_COLUMNS).order('created_at', { ascending: false }).limit(30);
  if (level) query = query.eq('evidence', level);
  const { data, error } = await query;
  if (error) { feed.replaceChildren(); notice(status, explain(error), 'error'); return; }
  if (!data.length) { feed.replaceChildren(); notice(status, EMPTY[level] ?? EMPTY['']); return; }
  const liked = await likedSet(session, data.map((it) => it.id));
  status.replaceChildren();
  feed.replaceChildren(...data.map((it) => tripCard(it, { session, liked: liked.has(it.id) })));
}
