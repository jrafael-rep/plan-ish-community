// Partes comuns a todas as páginas da Comunidade.
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
import { SUPABASE_KEY, SUPABASE_URL } from './config.js';

// Implícito, não PKCE: o link do email abre muitas vezes noutro browser (o do
// Gmail, por exemplo), que não teria o segredo guardado por este.
export const sb = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, detectSessionInUrl: true, flowType: 'implicit' },
});

/** O elemento com este id. */
export const $ = (id) => document.getElementById(id);

/** Cria um elemento; o texto entra sempre como texto, nunca como HTML. */
export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export function show(node, visible) { node.classList.toggle('hidden', !visible); }

export function notice(container, text, kind = '') {
  container.replaceChildren(el('div', { class: `notice ${kind}`.trim(), role: kind === 'error' ? 'alert' : 'status' }, text));
}

/** Mensagens que a pessoa entende, para os erros que o servidor dá. */
export function explain(error) {
  const text = `${error?.message ?? ''} ${error?.hint ?? ''}`;
  if (/request_invalid/.test(text)) return 'Este pedido já foi usado ou expirou. Volta a carregar em "Ligar à Comunidade" na app.';
  if (/members_only/.test(text)) return 'Disponível para membros da Comunidade.';
  if (/name_taken/.test(text)) return 'Esse nome acabou de ser atribuído a outra pessoa. Escolhe entre os novos.';
  if (/name_not_offered/.test(text)) return 'Já escolheste o nome do próximo viajante.';
  if (/reply_invalid/.test(text)) return 'Só se responde a comentários deste itinerário.';
  if (/not_signed_in|JWT/.test(text)) return 'Entra na tua conta primeiro.';
  if (/Failed to fetch|NetworkError/.test(text)) return 'Sem ligação. Tenta outra vez daqui a pouco.';
  if (error?.hint) return error.hint;
  return 'Algo correu mal. Tenta outra vez.';
}

const MONTHS = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
/** "2026-09" → "setembro de 2026". */
export function monthLabel(ym) {
  const m = /^(\d{4})-(\d{2})$/.exec(ym ?? '');
  return m ? `${MONTHS[Number(m[2]) - 1]} de ${m[1]}` : '';
}

export function plural(n, one, many) { return `${n} ${n === 1 ? one : many}`; }

export async function currentSession() {
  const { data } = await sb.auth.getSession();
  return data.session ?? null;
}

/** Endereço desta página, para voltar a ela depois de entrar. */
export function here() {
  const url = new URL(location.href);
  return url.pathname.split('/').pop() + url.search;
}

export function signInLink(next = here()) {
  return `entrar.html?next=${encodeURIComponent(next)}`;
}

/* --------------------------------------------------------------- ícones */

// Desenhados aqui, com o mesmo traço, a partir de texto fixo: nunca entra
// nada escrito por alguém nestas strings.
const ICONS = {
  heart: '<path d="M12 20.5s-7.5-4.6-7.5-10.1A4.2 4.2 0 0 1 12 7.6a4.2 4.2 0 0 1 7.5 2.8c0 5.5-7.5 10.1-7.5 10.1Z"/>',
  chat: '<path d="M5 17.5 3.5 21l4-1.6A8.5 8.5 0 1 0 5 17.5Z"/>',
  reply: '<path d="M9.5 7 4 12l5.5 5"/><path d="M4.5 12H14a6 6 0 0 1 6 6v1"/>',
  pin: '<path d="M12 21s6.5-5.8 6.5-11.2a6.5 6.5 0 1 0-13 0C5.5 15.2 12 21 12 21Z"/><circle cx="12" cy="9.8" r="2.3"/>',
  calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
  route: '<circle cx="6" cy="18" r="2.2"/><circle cx="18" cy="6" r="2.2"/><path d="M8.2 18H15a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h6.8"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8"/>',
  flag: '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>',
  check: '<path d="m5 12.5 4.2 4.2L19 7"/>',
  map: '<path d="m9 4.5-5 2v13l5-2 6 2 5-2v-13l-5 2-6-2ZM9 4.5v13M15 6.5v13"/>',
  shield: '<path d="M12 3 5 6v5.5c0 4.3 3 7.9 7 9.5 4-1.6 7-5.2 7-9.5V6l-7-3Z"/><path d="m8.8 12 2.2 2.2 4.2-4.4"/>',
  share: '<path d="M12 15V4M7.5 8.5 12 4l4.5 4.5"/><path d="M5 13v5.5A1.5 1.5 0 0 0 6.5 20h11a1.5 1.5 0 0 0 1.5-1.5V13"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  left: '<path d="m15 5-7 7 7 7"/>',
  right: '<path d="m9 5 7 7-7 7"/>',
  wallet: '<rect x="3" y="6" width="18" height="13" rx="3"/><path d="M3 10h18M16 14.5h2"/>',
  users: '<circle cx="9" cy="8.5" r="3.2"/><path d="M3.5 19a5.5 5.5 0 0 1 11 0M16 5.6a3.2 3.2 0 0 1 0 6M17.5 14a5.5 5.5 0 0 1 3 5"/>',
};

export function icon(name, label) {
  const t = document.createElement('template');
  t.innerHTML = `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" ${label ? `role="img" aria-label="${label}"` : 'aria-hidden="true"'}>${ICONS[name] ?? ''}</svg>`;
  return t.content.firstElementChild;
}

/* ------------------------------------------------------ prova e dados */

const BADGES = {
  original: { label: 'GPS verificado', icon: 'shield' },
  done: { label: 'Viagem feita', icon: 'check' },
  plan: { label: 'Roteiro', icon: 'route' },
};

/** O selo de quanto a viagem foi mesmo feita. */
export function badge(level) {
  const b = BADGES[level] ?? BADGES.plan;
  return el('span', { class: `badge ${BADGES[level] ? level : 'plan'}` }, icon(b.icon), b.label);
}

/** "entre 250 e 400 €", só quando há margem. */
export function budgetText(min, max) {
  if (!Number.isFinite(min) || !Number.isFinite(max)) return '';
  const f = (n) => n.toLocaleString('pt-PT');
  return min === max ? `${f(min)} € por pessoa` : `${f(min)}–${f(max)} € por pessoa`;
}

export function photoUrl(path) {
  return `${SUPABASE_URL}/storage/v1/object/public/itinerary-photos/${path.split('/').map(encodeURIComponent).join('/')}`;
}

/* ------------------------------------------------------------- avatares */

const AVATAR_COLORS = ['#0B7A84', '#2F6FD6', '#B4499A', '#C2571A', '#2E8B57', '#7B5CD6'];

export function hue(text) {
  let h = 0;
  for (const ch of text ?? '') h = (h * 31 + ch.codePointAt(0)) >>> 0;
  return h;
}

/** Um círculo com as iniciais; a cor vem do nome. */
export function avatar(name, size = '') {
  const clean = (name ?? 'Viajante').trim();
  const initials = clean.split(/\s+/).slice(0, 2).map((w) => w.charAt(0)).join('').toUpperCase();
  const node = el('span', { class: `avatar ${size}`.trim(), 'aria-hidden': 'true' }, initials);
  node.style.setProperty('--c', AVATAR_COLORS[hue(clean) % AVATAR_COLORS.length]);
  return node;
}

/** Nome com avatar, a ligar ao perfil. */
export function who(name, id) {
  return el('a', { class: 'who', href: id ? `viajante.html?id=${encodeURIComponent(id)}` : undefined }, avatar(name), el('span', {}, name ?? 'Viajante'));
}

/* ------------------------------------------------------------- a app */

/**
 * O esquema da app para onde os botões "Abrir no Plan-ish" levam.
 *
 * A app da Play responde a planish://; a versão de teste a planishdev://.
 * Quem ligou a versão de teste fica com ela lembrada neste browser.
 */
export function appScheme() {
  try {
    const s = localStorage.getItem('planish.appScheme');
    return s === 'planish' || s === 'planishdev' ? s : 'planish';
  } catch { return 'planish'; }
}

export function rememberAppScheme(scheme) {
  try { if (scheme === 'planish' || scheme === 'planishdev') localStorage.setItem('planish.appScheme', scheme); } catch { /* sem armazenamento */ }
}

export function relativeDay(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const days = Math.floor((Date.now() - d.getTime()) / 86_400_000);
  if (days <= 0) return 'hoje';
  if (days === 1) return 'ontem';
  if (days < 7) return `há ${days} dias`;
  return d.toLocaleDateString('pt-PT', { day: 'numeric', month: 'short' });
}

const MARK = `<svg class="mark" viewBox="0 0 32 32" aria-hidden="true">
  <rect width="32" height="32" rx="9" fill="var(--accent)"/>
  <circle cx="10" cy="22" r="3" fill="var(--accent-ink)"/><circle cx="22" cy="10" r="3" fill="var(--accent-ink)"/>
  <path d="M12.5 21.5h5a3.5 3.5 0 0 0 0-7h-3a3.5 3.5 0 0 1 0-7h5" fill="none" stroke="var(--accent-ink)" stroke-width="2.2" stroke-linecap="round"/>
</svg>`;

/** O cabeçalho igual em todas as páginas. */
export async function header(current) {
  const session = await currentSession();
  const link = (href, label, id) => el('a', { href, 'aria-current': current === id ? 'page' : undefined }, label);
  const t = document.createElement('template');
  t.innerHTML = MARK;
  const top = el('header', { class: 'top' },
    el('div', { class: 'wrap' },
      el('a', { class: 'brand', href: './', 'aria-label': 'Comunidade Plan-ish, início' },
        t.content.firstElementChild, el('b', {}, 'Plan-ish'), el('span', {}, 'Comunidade')),
      el('nav', { 'aria-label': 'Principal' },
        link('./', 'Explorar', 'feed'),
        session ? link('conta.html', 'Conta', 'conta') : link(signInLink(), 'Entrar', 'entrar'),
      ),
    ),
  );
  document.body.prepend(top);
  document.body.append(el('footer', {}, el('div', { class: 'wrap' },
    'Viagens de quem viajou com o Plan-ish. ',
    el('strong', {}, 'GPS verificado'), ' quer dizer que o GPS do telemóvel confirmou a maior parte das paragens. ',
    el('a', { href: 'https://jrafael-rep.github.io/plan-ish-releases/' }, 'Sobre a app'),
  )));
  return session;
}
