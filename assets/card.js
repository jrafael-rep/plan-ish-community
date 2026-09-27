// O cartão de uma viagem: igual no feed, na página do itinerário e no perfil.
// A app desenha o mesmo cartão no separador Comunidade.
import {
  appScheme, badge, budgetText, el, explain, hue, icon, monthLabel, plural, photoUrl, relativeDay, sb, signInLink, who,
} from './app.js';

export const CARD_COLUMNS = 'id, title, destination, summary, day_count, stop_count, travelled_month, like_count, comment_count, '
  + 'created_at, evidence, visited_stops, gps_stops, done_count, original_done_count, budget_min, budget_max, photos, plan, '
  + 'author_id, author:profiles!itineraries_author_id_fkey(display_name)';

const KINDS = {
  activity: 'Atividade', food: 'Comida', lodging: 'Alojamento', transport: 'Transporte', shopping: 'Compras',
  pickup: 'Apanhar / deixar', sightseeing: 'Visita', nature: 'Natureza', event: 'Evento', flex: 'Tempo livre',
  other: 'Outro', drive: 'Deslocação', waterfall: 'Cascata', viewpoint: 'Miradouro', beach: 'Praia',
  meal: 'Refeição', break: 'Pausa', admin: 'Tratar de algo',
};

const VISITS = { gps: 'GPS', manual: 'marcada à mão', skipped: 'ficou de fora' };

const COVERS = [
  ['#0B5563', '#1FA2A8'], ['#1D3F8A', '#3C7BE0'], ['#6B2F7A', '#C0569E'],
  ['#8A3A12', '#E07A3C'], ['#1E5E3B', '#48A36B'], ['#3D2F8A', '#7B6BE0'],
];

function stopsOf(plan) {
  return (Array.isArray(plan?.days) ? plan.days : []).flatMap((d) => (Array.isArray(d.stops) ? d.stops : []));
}

/**
 * A capa de uma viagem sem fotografias: o traçado das paragens publicadas,
 * sobre a cor da viagem. Só usa coordenadas que o itinerário já mostra.
 */
export function routeCover(it) {
  // Vai para dentro de um id de SVG: só letras, números e hífenes.
  const gid = `g${String(it.id).replace(/[^\w-]/g, '')}`;
  const [from, to] = COVERS[hue(it.id) % COVERS.length];
  const points = stopsOf(it.plan).filter((s) => Number.isFinite(s.lat) && Number.isFinite(s.lon));
  let path = '';
  let dots = '';
  if (points.length >= 2) {
    const k = Math.cos((points.reduce((n, p) => n + p.lat, 0) / points.length) * Math.PI / 180);
    const xs = points.map((p) => p.lon * k);
    const ys = points.map((p) => -p.lat);
    const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
    const span = Math.max(x1 - x0, y1 - y0) || 1;
    const sx = (x) => 200 + ((x - (x0 + x1) / 2) / span) * 250;
    const sy = (y) => 140 + ((y - (y0 + y1) / 2) / span) * 170;
    const pts = points.map((_, i) => [sx(xs[i]).toFixed(1), sy(ys[i]).toFixed(1)]);
    path = `<path d="M${pts.map((p) => p.join(' ')).join(' L')}" fill="none" stroke="#fff" stroke-opacity=".85" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="1 7"/>`;
    dots = pts.map(([x, y], i) => `<circle cx="${x}" cy="${y}" r="${i === 0 || i === pts.length - 1 ? 7 : 4.5}" fill="#fff" fill-opacity="${i === 0 || i === pts.length - 1 ? 1 : 0.8}"/>`).join('');
  }
  const t = document.createElement('template');
  t.innerHTML = `<svg class="cover" viewBox="0 0 400 300" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
    <defs><linearGradient id="${gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${from}"/><stop offset="1" stop-color="${to}"/></linearGradient></defs>
    <rect width="400" height="300" fill="url(#${gid})"/>
    <g fill="none" stroke="#fff" stroke-opacity=".08" stroke-width="1.5">
      <path d="M-20 230c60-30 120 20 180-10s120-50 260-10"/><path d="M-20 260c60-30 120 20 180-10s120-50 260-10"/><path d="M-20 200c60-30 120 20 180-10s120-50 260-10"/>
    </g>${path}${dots}
  </svg>`;
  return t.content.firstElementChild;
}

/** Fotografias a deslizar; sem fotografias, a capa do percurso. */
function media(it, photos = Array.isArray(it.photos) ? it.photos.slice(0, 6) : []) {
  const facts = el('span', { class: 'media-facts' },
    icon('route'), `${plural(it.day_count, 'dia', 'dias')} · ${plural(it.stop_count, 'paragem', 'paragens')}`);
  if (!photos.length) {
    return el('div', { class: 'media' }, routeCover(it), el('span', { class: 'media-badge' }, badge(it.evidence)),
      it.destination ? el('span', { class: 'media-place' }, it.destination) : null, facts);
  }
  const track = el('div', { class: 'slides', tabindex: '0', 'aria-label': `Fotografias de ${it.title}` },
    ...photos.map((p, i) => el('img', {
      src: photoUrl(p), alt: `Fotografia ${i + 1} de ${photos.length}`, loading: i ? 'lazy' : 'eager', decoding: 'async',
      // Uma fotografia que não abre sai; sem nenhuma, fica a capa do percurso.
      onerror: () => box.replaceWith(media(it, photos.filter((x) => x !== p))),
    })));
  const box = el('div', { class: 'media' }, track, el('span', { class: 'media-badge' }, badge(it.evidence)), facts);
  if (photos.length > 1) {
    const dots = el('div', { class: 'dots', 'aria-hidden': 'true' }, ...photos.map((_, i) => el('i', { class: i ? '' : 'on' })));
    const go = (d) => track.scrollBy({ left: d * track.clientWidth, behavior: 'smooth' });
    box.append(dots,
      el('button', { class: 'nav prev', type: 'button', 'aria-label': 'Fotografia anterior', onclick: () => go(-1) }, icon('left')),
      el('button', { class: 'nav next', type: 'button', 'aria-label': 'Fotografia seguinte', onclick: () => go(1) }, icon('right')));
    track.addEventListener('scroll', () => {
      const n = Math.round(track.scrollLeft / Math.max(1, track.clientWidth));
      [...dots.children].forEach((d, i) => d.classList.toggle('on', i === n));
    }, { passive: true });
  }
  return box;
}

/** O dia a dia, compacto. */
export function dayList(plan) {
  const days = Array.isArray(plan?.days) ? plan.days : [];
  if (!days.length) return el('p', { class: 'muted' }, 'Este itinerário não tem paragens publicadas.');
  return el('ol', { class: 'days' }, ...days.map((day, i) => el('li', { class: 'day' },
    el('div', { class: 'day-head' }, el('span', { class: 'day-n' }, `Dia ${i + 1}`), day.title ? el('strong', {}, day.title) : null),
    day.summary ? el('p', { class: 'day-summary' }, day.summary) : null,
    el('ul', { class: 'stops' }, ...(Array.isArray(day.stops) ? day.stops : []).map((stop) => {
      const visit = VISITS[stop.visit] ? stop.visit : '';
      const hasPlace = Number.isFinite(stop.lat) && Number.isFinite(stop.lon);
      return el('li', { class: `stop${visit ? ` v-${visit}` : ''}` },
        el('div', { class: 'stop-line' },
          el('span', { class: 'stop-name' }, stop.name ?? ''),
          visit === 'gps' ? el('span', { class: 'gps', title: 'Chegada confirmada pelo GPS' }, icon('shield'), 'GPS') : null),
        el('div', { class: 'stop-meta' },
          ...[stop.type && KINDS[stop.type], stop.at ? `às ${stop.at}` : null,
            stop.duration ? (typeof stop.duration === 'number' ? `${stop.duration} min` : String(stop.duration)) : null,
            visit && visit !== 'gps' ? VISITS[visit] : null].filter(Boolean).map((t) => el('span', {}, t)),
          hasPlace ? el('a', { href: `https://www.google.com/maps/search/?api=1&query=${stop.lat},${stop.lon}`, rel: 'noopener' }, 'Mapa') : null),
        stop.description ? el('p', { class: 'stop-desc' }, stop.description) : null);
    })),
  )));
}

function evidenceNote(it) {
  if (it.evidence === 'original') return `O GPS confirmou ${it.gps_stops} de ${plural(it.visited_stops, 'paragem visitada', 'paragens visitadas')}.`;
  if (it.evidence === 'done') return `${plural(it.visited_stops, 'paragem visitada', 'paragens visitadas')}, marcadas sobretudo à mão.`;
  return 'Um plano: a viagem não foi registada pelo telemóvel.';
}

/** O botão de gostar, que funciona com sessão no site. */
export function likeButton(it, session, liked, hint) {
  let on = liked;
  let count = it.like_count;
  const button = el('button', { class: 'act like', type: 'button' });
  const paint = () => {
    button.replaceChildren(icon('heart'), el('span', {}, String(count)));
    button.setAttribute('aria-pressed', String(on));
    button.setAttribute('aria-label', `${on ? 'Já gostas' : 'Gostar'}. ${plural(count, 'gosto', 'gostos')}`);
  };
  paint();
  button.addEventListener('click', async () => {
    if (!session) { location.href = signInLink(); return; }
    button.disabled = true;
    const { error } = on
      ? await sb.from('likes').delete().eq('itinerary_id', it.id).eq('user_id', session.user.id)
      : await sb.from('likes').insert({ itinerary_id: it.id, user_id: session.user.id });
    button.disabled = false;
    if (error) { if (hint) hint.textContent = explain(error); return; }
    on = !on; count += on ? 1 : -1; paint();
  });
  return button;
}

/** Que itinerários desta lista a pessoa com sessão já gostou. */
export async function likedSet(session, ids) {
  if (!session || !ids.length) return new Set();
  const { data } = await sb.from('likes').select('itinerary_id').in('itinerary_id', ids);
  return new Set((data ?? []).map((l) => l.itinerary_id));
}

/**
 * O cartão. `open` mostra já o dia a dia (na página do itinerário); no feed
 * abre e fecha no sítio.
 */
export function tripCard(it, { session = null, liked = false, open = false, page = false } = {}) {
  const href = `itinerario.html?id=${encodeURIComponent(it.id)}`;
  const hint = el('p', { class: 'hint', role: 'status' });
  const budget = budgetText(it.budget_min, it.budget_max);
  const more = el('div', { class: 'more', id: `more-${it.id}`, hidden: !open },
    el('p', { class: `evidence-note ${it.evidence}` }, badge(it.evidence), evidenceNote(it)),
    dayList(it.plan),
    el('div', { class: 'more-actions' },
      el('a', { class: 'btn primary', href: `${appScheme()}://itinerary/${encodeURIComponent(it.id)}` }, 'Abrir no Plan-ish'),
      page ? null : el('a', { class: 'btn', href: `${href}#conversa` }, icon('chat'), it.comment_count ? `Conversa (${it.comment_count})` : 'Conversa')),
    page ? el('p', { class: 'small muted' }, 'Abre a app no telemóvel, onde podes copiar este itinerário para o teu planeamento. Ainda não a tens? ',
      el('a', { href: 'https://jrafael-rep.github.io/plan-ish-releases/' }, 'Conhece o Plan-ish'), '.') : null,
  );
  const toggle = el('button', {
    class: 'act toggle', type: 'button', 'aria-expanded': String(open), 'aria-controls': more.id,
    onclick: () => {
      const willOpen = more.hidden;
      more.hidden = !willOpen;
      toggle.setAttribute('aria-expanded', String(willOpen));
      toggle.querySelector('span').textContent = willOpen ? 'Fechar' : 'Ver roteiro';
    },
  }, el('span', {}, open ? 'Fechar' : 'Ver roteiro'), icon('chevron'));

  const TitleTag = page ? 'h1' : 'h2';
  return el('article', { class: 'trip', 'aria-labelledby': `t-${it.id}` },
    el('header', { class: 'trip-head' },
      who(it.author?.display_name, it.author_id),
      it.created_at ? el('span', { class: 'when' }, relativeDay(it.created_at)) : null),
    media(it),
    el('div', { class: 'trip-body' },
      el(TitleTag, { class: 'trip-title', id: `t-${it.id}` }, page ? it.title : el('a', { href }, it.title)),
      el('p', { class: 'trip-meta' },
        ...[it.destination ? el('span', { class: 'i' }, icon('pin'), it.destination) : null,
          it.travelled_month ? el('span', { class: 'i' }, icon('calendar'), monthLabel(it.travelled_month)) : null].filter(Boolean)),
      budget || it.done_count
        ? el('div', { class: 'facts' },
          budget ? el('span', { class: 'fact' }, icon('wallet'), budget) : null,
          it.done_count ? el('span', { class: `fact${it.original_done_count ? ' gps' : ''}` }, icon('users'),
            it.original_done_count
              ? `${plural(it.done_count, 'pessoa fez', 'pessoas fizeram')}, ${it.original_done_count} com GPS`
              : plural(it.done_count, 'pessoa também fez', 'pessoas também fizeram')) : null)
        : null,
      it.summary ? el('p', { class: `summary${page ? '' : ' clamp'}` }, it.summary) : null),
    el('div', { class: 'actions' },
      likeButton(it, session, liked, hint),
      el('a', { class: 'act', href: page ? '#conversa' : `${href}#conversa`, 'aria-label': `Conversa, ${plural(it.comment_count, 'comentário', 'comentários')}` },
        icon('chat'), el('span', {}, String(it.comment_count))),
      el('button', { class: 'act', type: 'button', 'aria-label': 'Partilhar', onclick: () => void share(it, hint) }, icon('share')),
      page ? null : toggle),
    hint,
    more,
  );
}

async function share(it, hint) {
  const url = new URL(`itinerario.html?id=${encodeURIComponent(it.id)}`, location.href).href;
  try {
    if (navigator.share) { await navigator.share({ title: it.title, url }); return; }
    await navigator.clipboard.writeText(url);
    hint.textContent = 'Link copiado.';
  } catch { /* a pessoa cancelou */ }
}

