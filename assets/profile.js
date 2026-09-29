import { $, avatar, badge, el, explain, header, notice, plural, photoUrl, sb, signInLink, who } from './app.js';
import { missingColumn, routeCover } from './card.js';
import { profileSkeleton } from './layout/shared/skeleton.js';

const session = await header('');
const status = $('status');
const id = new URLSearchParams(location.search).get('id') ?? '';
status.replaceChildren(profileSkeleton());

const TILE = 'id, title, destination, day_count, stop_count, evidence, photos, plan, like_count';
const BASIC_TILE = 'id, title, destination, day_count, stop_count, plan, like_count';

const valid = /^[0-9a-f-]{36}$/i.test(id);
let { data: person, error } = valid
  ? await sb.from('profiles').select('id, display_name, created_at, named_by, follower_count, following_count').eq('id', id).maybeSingle()
  : { data: null, error: null };
// Antes do esquema 2 não há "quem escolheu o nome".
if (valid && missingColumn(error)) {
  ({ data: person, error } = await sb.from('profiles').select('id, display_name, created_at').eq('id', id).maybeSingle());
}

if (error || !person) {
  notice(status, error ? explain(error) : 'Este viajante não existe ou apagou a conta.', 'error');
} else {
  await render(person);
}

async function render(p) {
  document.title = `${p.display_name} · Comunidade Plan-ish`;
  let [namer, named, published, done] = await Promise.all([
    p.named_by ? sb.from('profiles').select('id, display_name').eq('id', p.named_by).maybeSingle() : { data: null },
    sb.from('profiles').select('id, display_name').eq('named_by', p.id).limit(1).then((r) => (r.error ? { data: [] } : r)),
    sb.from('itineraries').select(TILE).eq('author_id', p.id).order('created_at', { ascending: false }).limit(60),
    sb.from('itinerary_completions').select(`evidence, completed_at, itinerary:itineraries(${TILE})`)
      .eq('user_id', p.id).order('completed_at', { ascending: false }).limit(60),
  ]);
  if (missingColumn(published.error)) {
    // Antes do esquema 3: sem prova, fotografias nem viagens feitas.
    published = await sb.from('itineraries').select(BASIC_TILE).eq('author_id', p.id).order('created_at', { ascending: false }).limit(60);
    done = { data: [] };
  }
  if (done.error) done = { data: [] };
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
      Number.isFinite(p.follower_count) ? el('p', { class: 'follow-line small' },
        el('span', { id: 'followers' }, plural(p.follower_count, 'seguidor', 'seguidores')), ' · ',
        el('span', {}, `segue ${p.following_count ?? 0}`)) : null,
      Number.isFinite(p.follower_count) && session?.user.id !== p.id ? followButton(p) : null,
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
    ? el('img', { src: photoUrl(it.photos[0]), alt: '', loading: 'lazy', decoding: 'async', width: 1280, height: 960 })
    : routeCover(it);
  return el('a', { class: 'tile', href: `itinerario.html?id=${encodeURIComponent(it.id)}` },
    cover,
    el('span', { class: 'tile-text' },
      el('strong', {}, it.title),
      el('span', {}, [it.destination, plural(it.day_count, 'dia', 'dias')].filter(Boolean).join(' · ')),
      // Só com rato (PC): o resto do que o cartão diria.
      el('span', { class: 'tile-more' }, [
        Number.isFinite(it.stop_count) ? plural(it.stop_count, 'paragem', 'paragens') : null,
        Number.isFinite(it.like_count) ? plural(it.like_count, 'gosto', 'gostos') : null,
      ].filter(Boolean).join(' · '))),
    el('span', { class: 'tile-badge' }, badge(doneAs ?? it.evidence)));
}

/** Seguir: o feed "A seguir" passa a mostrar o que esta pessoa publica. */
function followButton(p) {
  let on = false;
  let n = p.follower_count;
  const button = el('button', { class: 'btn follow', type: 'button' });
  const paint = () => {
    button.textContent = on ? 'A seguir' : 'Seguir';
    button.classList.toggle('primary', !on);
    button.setAttribute('aria-pressed', String(on));
    const f = document.getElementById('followers');
    if (f) f.textContent = plural(n, 'seguidor', 'seguidores');
  };
  paint();
  if (session) {
    void sb.from('follows').select('followee_id').eq('follower_id', session.user.id).eq('followee_id', p.id).maybeSingle()
      .then(({ data }) => { on = Boolean(data); paint(); });
  }
  button.addEventListener('click', async () => {
    if (!session) { location.href = signInLink(); return; }
    button.disabled = true;
    const { error } = on
      ? await sb.from('follows').delete().eq('follower_id', session.user.id).eq('followee_id', p.id)
      : await sb.from('follows').insert({ follower_id: session.user.id, followee_id: p.id });
    button.disabled = false;
    if (error && error.code !== '23505') { alert(explain(error)); return; }
    on = !on; n += on ? 1 : -1; paint();
  });
  return el('p', { class: 'row follow-row' }, button);
}
