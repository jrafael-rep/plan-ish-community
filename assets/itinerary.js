import { $, el, explain, header, monthLabel, notice, plural, sb, show, signInLink } from './app.js';
import { APP_SCHEME } from './config.js';

const session = await header('');
const status = $('status');
const id = new URLSearchParams(location.search).get('id') ?? '';
notice(status, 'A carregar…');

const KINDS = {
  activity: 'Atividade',
  food: 'Comida / restaurante',
  lodging: 'Alojamento',
  transport: 'Transporte',
  shopping: 'Compras',
  pickup: 'Apanhar / deixar',
  sightseeing: 'Visita',
  nature: 'Natureza',
  event: 'Evento',
  flex: 'Tempo livre',
  other: 'Outro',
  drive: 'Deslocação',
  waterfall: 'Cascata',
  viewpoint: 'Miradouro',
  beach: 'Praia',
  meal: 'Refeição',
  break: 'Pausa',
  admin: 'Tratar de algo',
  home: 'Casa',
};

const { data: it, error } = await sb.from('itineraries')
  .select('id, title, destination, summary, day_count, stop_count, travelled_month, like_count, comment_count, plan, author:profiles!itineraries_author_id_fkey(display_name)')
  .eq('id', id).maybeSingle();

if (error || !it) {
  notice(status, error ? explain(error) : 'Este itinerário não existe ou já não está publicado.', 'error');
} else {
  status.replaceChildren();
  document.title = `${it.title} · Comunidade Plan-ish`;
  $('title').textContent = it.title;
  $('meta').replaceChildren(
    ...[it.destination, plural(it.day_count, 'dia', 'dias'), plural(it.stop_count, 'paragem', 'paragens'),
      it.travelled_month ? `feito em ${monthLabel(it.travelled_month)}` : null, `por ${it.author?.display_name ?? 'Viajante'}`]
      .filter(Boolean).map((t) => el('span', {}, t)),
  );
  $('summary').textContent = it.summary ?? '';
  $('open-app').href = `${APP_SCHEME}://itinerary/${encodeURIComponent(it.id)}`;
  renderDays(it.plan);
  show($('itinerary'), true);
  await setupLike(it);
  await loadComments(it.id);
  setupCommentForm(it.id);
  $('report').addEventListener('click', (e) => { e.preventDefault(); void report(it.id); });
}

function renderDays(plan) {
  const days = Array.isArray(plan?.days) ? plan.days : [];
  $('days').replaceChildren(...days.map((day, i) => el('section', { class: 'day' },
    el('h2', {}, `Dia ${i + 1}${day.title ? ` · ${day.title}` : ''}`),
    day.summary ? el('p', { class: 'muted' }, day.summary) : null,
    ...(Array.isArray(day.stops) ? day.stops : []).map((stop) => el('div', { class: 'stop' },
      el('strong', {}, stop.name ?? ''),
      el('div', { class: 'meta' },
        stop.type && KINDS[stop.type] ? el('span', {}, KINDS[stop.type]) : null,
        stop.at ? el('span', {}, `às ${stop.at}`) : null,
        stop.duration ? el('span', {}, typeof stop.duration === 'number' ? `${stop.duration} min` : String(stop.duration)) : null,
        Number.isFinite(stop.lat) && Number.isFinite(stop.lon)
          ? el('a', { href: `https://www.google.com/maps/search/?api=1&query=${stop.lat},${stop.lon}`, rel: 'noopener' }, 'Ver no mapa')
          : null,
      ),
      stop.description ? el('p', { class: 'small' }, stop.description) : null,
    )),
  )));
}

async function setupLike(it) {
  const button = $('like');
  let count = it.like_count;
  let liked = false;
  const paint = () => { button.textContent = `${liked ? '♥' : '♡'} ${count}`; button.setAttribute('aria-pressed', String(liked)); };
  if (session) {
    const { data } = await sb.from('likes').select('itinerary_id').eq('itinerary_id', it.id);
    liked = Boolean(data?.length);
  }
  paint();
  button.addEventListener('click', async () => {
    if (!session) { $('like-hint').replaceChildren(el('a', { href: signInLink() }, 'Entra'), ' para gostar deste itinerário.'); return; }
    button.disabled = true;
    const { error } = liked
      ? await sb.from('likes').delete().eq('itinerary_id', it.id).eq('user_id', session.user.id)
      : await sb.from('likes').insert({ itinerary_id: it.id, user_id: session.user.id });
    button.disabled = false;
    if (error) { $('like-hint').textContent = explain(error); return; }
    liked = !liked; count += liked ? 1 : -1; paint();
  });
}

async function loadComments(itineraryId) {
  const { data, error } = await sb.from('comments')
    .select('id, body, created_at, author_id, author:profiles!comments_author_id_fkey(display_name)')
    .eq('itinerary_id', itineraryId).order('created_at');
  const box = $('comments');
  if (error) { notice(box, explain(error), 'error'); return; }
  $('comments-title').textContent = data.length ? `Comentários (${data.length})` : 'Comentários';
  box.replaceChildren(...(data.length ? data.map((c) => el('div', { class: 'comment' },
    el('div', { class: 'who' }, c.author?.display_name ?? 'Viajante',
      el('span', { class: 'muted small' }, ` · ${new Date(c.created_at).toLocaleDateString('pt-PT')}`)),
    el('div', {}, c.body),
    session && c.author_id === session.user.id
      ? el('button', { class: 'btn small', type: 'button', onclick: async () => {
        await sb.from('comments').delete().eq('id', c.id); await loadComments(itineraryId);
      } }, 'Apagar')
      : null,
  )) : [el('p', { class: 'muted' }, 'Ainda sem comentários.')]));
}

function setupCommentForm(itineraryId) {
  if (!session) {
    const hint = $('comment-signin');
    hint.replaceChildren(el('a', { href: signInLink() }, 'Entra'), ' para comentar.');
    show(hint, true);
    return;
  }
  const form = $('comment-form');
  show(form, true);
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const body = $('comment-body').value.trim();
    if (!body) return;
    const { error } = await sb.from('comments').insert({ itinerary_id: itineraryId, author_id: session.user.id, body });
    if (error) { notice($('comments'), explain(error), 'error'); return; }
    $('comment-body').value = '';
    await loadComments(itineraryId);
  });
}

async function report(itineraryId) {
  const reason = prompt('O que se passa com este itinerário? (conteúdo ofensivo, spam, dados pessoais de alguém…)');
  if (!reason || !reason.trim()) return;
  const { error } = await sb.from('reports').insert({ itinerary_id: itineraryId, reason: reason.trim().slice(0, 500) });
  alert(error ? explain(error) : 'Obrigado. Vamos ver o que se passa.');
}
