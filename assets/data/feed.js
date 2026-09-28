// Os dados do feed, sem nada de DOM: quem desenha (PC ou telemóvel) pede uma
// página e recebe { data, error }.
import { sb } from '../app.js';
import { BASIC_COLUMNS, CARD_COLUMNS, missingColumn } from '../card.js';

export const PAGE = 20;

/** Sem o esquema 11 não há feed_page: o feed lê a tabela, como antes. */
let viaServer = true;

/**
 * Uma página do feed.
 * @param {{ view: string, level: string, words: string, from: number, userId?: string | null }} q
 */
export async function feedPage({ view, level, words, from, userId = null }) {
  // O servidor ordena cada separador e tira o escondido e quem bloqueei; as
  // colunas e o autor pedem-se como numa leitura da tabela.
  const server = () => sb.rpc('feed_page', {
    p_tab: view, p_level: level || null, p_search: words || null, p_offset: from, p_limit: PAGE,
  }).select(CARD_COLUMNS);
  // Antes do esquema 11. O id desempata: uma página nunca repete nem salta viagens publicadas no mesmo instante.
  const table = (columns, basic) => {
    let query = sb.from('itineraries').select(columns);
    if (view === 'popular') query = query.order('like_count', { ascending: false });
    if (view === 'mine') query = query.eq('author_id', userId ?? '');
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
  return { data, error };
}

function missingFunction(error) {
  return error?.code === 'PGRST202' || error?.code === '42883';
}

/** Letras, números, espaços, hífenes e apóstrofos: vírgulas e parênteses mudariam o filtro. */
export function searchTerm(text) {
  return text.replace(/[^\p{L}\p{N} '-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
}

/* ------------------------------------------------ o estado no URL
   ?vista=recentes&tipo=gps&q=gerês — voltar atrás, recarregar e partilhar
   mostram o mesmo. Os valores por defeito não aparecem no URL. */

const VIEWS = { popular: '', recent: 'recentes', mine: 'meus' };
const LEVELS = { '': '', original: 'gps', done: 'feitas', plan: 'roteiros' };
const invert = (map) => Object.fromEntries(Object.entries(map).map(([k, v]) => [v, k]));
const VIEW_OF = invert(VIEWS);
const LEVEL_OF = invert(LEVELS);

/** O que o URL pede. Valores desconhecidos voltam ao defeito. */
export function readFeedUrl(search = location.search) {
  const p = new URLSearchParams(search);
  return {
    view: VIEW_OF[p.get('vista') ?? ''] ?? 'popular',
    level: LEVEL_OF[p.get('tipo') ?? ''] ?? '',
    words: searchTerm(p.get('q') ?? ''),
  };
}

/** O URL para este estado, a partir do atual (mantém o resto, como ?ref=). */
export function feedUrl({ view, level, words }, href = location.href) {
  const url = new URL(href);
  const set = (key, value) => { if (value) url.searchParams.set(key, value); else url.searchParams.delete(key); };
  set('vista', VIEWS[view] ?? '');
  set('tipo', LEVELS[level] ?? '');
  set('q', words);
  return url.pathname + url.search + url.hash;
}
