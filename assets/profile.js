import { $, avatar, badge, el, explain, header, notice, plural, photoUrl, sb, who } from './app.js';
import { routeCover } from './card.js';

const session = await header('');
const status = $('status');
const id = new URLSearchParams(location.search).get('id') ?? '';
notice(status, 'A carregar…');

const TILE = 'id, title, destination, day_count, evidence, photos, plan, like_count';

const { data: person, error } = /^[0-9a-f-]{36}$/i.test(id)
  ? await sb.from('profiles').select('id, display_name, created_at, named_by').eq('id', id).maybeSingle()
  : { data: null, error: null };

if (error || !person) {
  notice(status, error ? explain(error) : 'Este viajante não existe ou apagou a conta.', 'error');
} else {
  await render(person);
}

async function render(p) {
  document.title = `${p.display_name} · Comunidade Plan-ish`;
  const [namer, named, published, done] = await Promise.all([
    p.named_by ? sb.from('profiles').select('id, display_name').eq('id', p.named_by).maybeSingle() : { data: null },
    sb.from('profiles').select('id, display_name').eq('named_by', p.id).limit(1),
    sb.from('itineraries').select(TILE).eq('author_id', p.id).order('created_at', { ascending: false }).limit(60),
    sb.from('itinerary_completions').select(`evidence, completed_at, itinerary:itineraries(${TILE})`)
      .eq('user_id', p.id).order('completed_at', { ascending: false }).limit(60),
  ]);
  if (published.error) { notice(status, explain(published.error), 'error'); return; }
  status.replaceChildren();

  const mine = published.data ?? [];
  // Itinerários escondidos pela moderação vêm sem o itinerário.
  const others = (done.data ?? []).filter((c) => c.itinerary);
  const since = new Date(p.created_at).toLocaleDateString('pt-PT', { month: 'long', year: 'numeric' });

  $('who').replaceChildren(el('div', { class: 'profile' },
    avatar(p.display_name, 'lg'),
    el('div', {},
      el('h1', {}, p.display_name, session?.user.id === p.id ? el('span', { class: 'you' }, 'és tu') : null),
      el('p', { class: 'muted small' }, `Na Comunidade desde ${since}`),
      namer.data || named.data?.[0]
        ? el('p', { class: 'names small' },
          namer.data ? el('span', {}, 'Nome escolhido por ', who(namer.data.display_name, namer.data.id)) : null,
          named.data?.[0] ? el('span', {}, 'Deu o nome a ', who(named.data[0].display_name, named.data[0].id)) : null)
        : null)));

  const gps = mine.filter((it) => it.evidence === 'original').length + others.filter((c) => c.evidence === 'original').length;
  const likes = mine.reduce((n, it) => n + it.like_count, 0);
  const stat = (n, one, many) => el('div', { class: 'stat' }, el('b', {}, String(n)), el('span', {}, n === 1 ? one : many));
  $('stats').replaceChildren(
    stat(mine.length, 'publicada', 'publicadas'),
    stat(others.length, 'feita de outros', 'feitas de outros'),
    stat(gps, 'com GPS', 'com GPS'),
    stat(likes, 'gosto', 'gostos'),
  );

  $('published').replaceChildren(...(mine.length ? mine.map((it) => tile(it))
    : [el('p', { class: 'muted empty' }, 'Ainda não publicou nenhuma viagem.')]));
  $('done').replaceChildren(...(others.length ? others.map((c) => tile(c.itinerary, c.evidence))
    : [el('p', { class: 'muted empty' }, 'Ainda não registou nenhuma viagem da Comunidade como feita.')]));
  const TABS = [['tab-mine', 'published'], ['tab-done', 'done']];
  for (const [tab] of TABS) {
    $(tab).addEventListener('click', () => {
      for (const [t, panel] of TABS) {
        const on = t === tab;
        $(t).setAttribute('aria-selected', String(on));
        $(t).setAttribute('aria-pressed', String(on));
        $(panel).hidden = !on;
      }
    });
  }
  $('profile').classList.remove('hidden');
}

/** Um quadrado da grelha: a primeira fotografia, ou a capa do percurso. */
function tile(it, doneAs) {
  const cover = it.photos?.length
    ? el('img', { src: photoUrl(it.photos[0]), alt: '', loading: 'lazy', decoding: 'async' })
    : routeCover(it);
  return el('a', { class: 'tile', href: `itinerario.html?id=${encodeURIComponent(it.id)}` },
    cover,
    el('span', { class: 'tile-text' },
      el('strong', {}, it.title),
      el('span', {}, [it.destination, plural(it.day_count, 'dia', 'dias')].filter(Boolean).join(' · '))),
    el('span', { class: 'tile-badge' }, badge(doneAs ?? it.evidence)));
}
