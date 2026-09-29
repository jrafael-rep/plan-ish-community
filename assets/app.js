// Partes comuns a todas as páginas da Comunidade.
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm';
import { SUPABASE_KEY, SUPABASE_URL } from './config.js';

// Implícito, não PKCE: o link do email abre muitas vezes noutro browser (o do
// Gmail, por exemplo), que não teria o segredo guardado por este.
export const sb = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, detectSessionInUrl: true, flowType: 'implicit' },
});

/* ------------------------------------------------------------ convites */

// Quem chega por um link de convite (?ref=CÓDIGO) fica com o código guardado
// neste browser até entrar na conta; aí diz-se ao servidor quem convidou.
const REF_KEY = 'planish.ref';
try {
  const ref = new URLSearchParams(location.search).get('ref');
  if (ref && /^[A-HJKMNP-Z2-9]{8}$/i.test(ref)) localStorage.setItem(REF_KEY, ref.toUpperCase());
} catch { /* sem armazenamento: o convite perde-se, nada mais */ }

/** O código de convite guardado neste browser, se houver. */
export function pendingRef() {
  try { return localStorage.getItem(REF_KEY); } catch { return null; }
}

async function claimPendingRef() {
  const ref = pendingRef();
  if (!ref) return;
  const { error } = await sb.rpc('claim_ref', { p_code: ref });
  // Sem rede, ou sem o esquema 10: fica para a próxima página.
  if (error && !/ref_|not_signed_in/.test(`${error.message ?? ''}`)) return;
  try { localStorage.removeItem(REF_KEY); } catch { /* fica, e o servidor volta a recusar */ }
}

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
  if (/not_in_plan/.test(text)) return 'Este plano não está partilhado contigo.';
  if (/invite_invalid/.test(text)) return 'Este convite expirou ou não existe. Pede um novo a quem te convidou.';
  if (/fields_invalid/.test(text)) return 'Uma alteração não foi aceite. Recarrega a página e tenta outra vez.';
  if (/terms_required/.test(text)) return 'Para publicar, comentar ou avaliar, aceita primeiro os termos de utilização.';
  if (/terms_outdated/.test(text)) return 'Os termos mudaram entretanto. Lê a versão nova e aceita outra vez.';
  if (/account_blocked/.test(text)) return 'Esta conta foi bloqueada na Comunidade por não cumprir os termos de utilização.';
  if (/review_empty/.test(text)) return 'Dá estrelas, escreve um comentário, ou as duas coisas.';
  if (/review_invalid/.test(text)) return 'As estrelas vão de 1 a 5, e o comentário tem no máximo 2000 caracteres.';
  if (/own_itinerary/.test(text)) return 'Este itinerário é teu: não se avalia o próprio itinerário.';
  if (/not_admin/.test(text)) return 'Só para quem modera a Comunidade.';
  if (/points_insufficient/.test(text)) return 'Ainda não tens pontos suficientes.';
  if (/gift_invalid/.test(text)) return 'Este código não existe, já foi usado ou expirou.';
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
  star: '<path d="m12 3.5 2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 16.9l-5.2 2.8 1-5.9-4.3-4.1 5.9-.8L12 3.5Z"/>',
  info: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5"/><circle cx="12" cy="8" r=".6" fill="currentColor"/>',
  block: '<circle cx="12" cy="12" r="8.5"/><path d="m6 6 12 12"/>',
  moon: '<path d="M19.5 14.2A7.8 7.8 0 1 1 9.8 4.5a6.3 6.3 0 0 0 9.7 9.7Z"/>',
  sun: '<circle cx="12" cy="12" r="3.8"/><path d="M12 3v2M12 19v2M5.6 5.6 7 7M17 17l1.4 1.4M3 12h2M19 12h2M5.6 18.4 7 17M17 7l1.4-1.4"/>',
  users: '<circle cx="9" cy="8.5" r="3.2"/><path d="M3.5 19a5.5 5.5 0 0 1 11 0M16 5.6a3.2 3.2 0 0 1 0 6M17.5 14a5.5 5.5 0 0 1 3 5"/>',
  search: '<circle cx="10.8" cy="10.8" r="6.3"/><path d="m15.5 15.5 4.5 4.5"/>',
  sliders: '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
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

/**
 * Claro ⇄ escuro. Claro por defeito; a escolha fica guardada e vale também na
 * página da app (assets/theme.js aplica-a antes de a página se desenhar).
 */
function modeButton() {
  const root = document.documentElement;
  const button = el('button', { class: 'mode', type: 'button', 'aria-label': 'Modo escuro', title: 'Modo escuro' });
  const show = () => {
    const dark = root.dataset.theme === 'dark';
    button.setAttribute('aria-pressed', String(dark));
    button.replaceChildren(icon(dark ? 'sun' : 'moon'));
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', dark ? '#0E1B26' : '#D5E7E6');
    document.querySelector('meta[name="color-scheme"]')?.setAttribute('content', dark ? 'dark' : 'light');
  };
  button.addEventListener('click', () => {
    if (root.dataset.theme === 'dark') delete root.dataset.theme; else root.dataset.theme = 'dark';
    try { localStorage.setItem('planish-theme', root.dataset.theme === 'dark' ? 'dark' : 'light'); } catch { /* fica só nesta página */ }
    show();
  });
  show();
  return button;
}

/** Apaga do Storage as fotos que o servidor pôs no lixo (só essas se deixam apagar). */
export async function removePhotos(paths) {
  if (!paths?.length) return;
  try { await sb.storage.from('itinerary-photos').remove(paths); } catch { /* ficam no lixo; a próxima limpeza leva-as */ }
}

/** Retira da Comunidade um itinerário meu, com as fotos. Devolve o erro, se houver. */
export async function withdrawItinerary(id) {
  const { data, error } = await sb.rpc('withdraw_itinerary', { p_itinerary_id: id });
  if (error) return error;
  await removePhotos(data);
  return null;
}

export const WITHDRAW_WARNING = 'O itinerário, as fotografias, os gostos, as avaliações e os comentários são apagados. A viagem na app fica no telemóvel.';

/** O cabeçalho igual em todas as páginas. */
export async function header(current, { detail = false } = {}) {
  const session = await currentSession();
  if (session) void claimPendingRef();
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
        modeButton(),
      ),
    ),
  );
  document.body.prepend(top);
  document.body.append(el('footer', {}, el('div', { class: 'wrap' },
    'Viagens de quem viajou com o Plan-ish. ',
    el('strong', {}, 'GPS verificado'), ' quer dizer que o GPS do telemóvel confirmou a maior parte das paragens. ',
    el('a', { href: 'https://jrafael-rep.github.io/plan-ish-releases/' }, 'Sobre a app'), ' · ',
    el('a', { href: 'privacidade.html' }, 'Privacidade'), ' · ',
    el('a', { href: 'termos.html' }, 'Termos'),
  )));
  // No telemóvel, separadores em baixo e topo que se esconde (layout/mobile/shell.js).
  let shell = null;
  const arrange = async (layout) => {
    if (layout === 'mobile' && !shell) {
      const { mountMobileShell } = await import('./layout/mobile/shell.js');
      if (document.documentElement.dataset.layout === 'mobile' && !shell) shell = mountMobileShell({ current, session, detail });
    } else if (layout !== 'mobile' && shell) { shell.unmount(); shell = null; }
  };
  void arrange(document.documentElement.dataset.layout);
  addEventListener('planish:layout', (e) => void arrange(e.detail));
  return session;
}

/* --------------------------------------------------------------- termos */

function isTermsError(error) {
  return /terms_required|terms_outdated/.test(`${error?.message ?? ''} ${error?.hint ?? ''}`);
}

/** Pergunta, num diálogo, se a pessoa aceita os termos em vigor. */
function askTerms() {
  return new Promise((resolve) => {
    const dialog = el('dialog', { class: 'terms-dialog', 'aria-labelledby': 'terms-dialog-title' },
      el('h2', { id: 'terms-dialog-title' }, 'Termos de utilização'),
      el('p', {}, 'Antes de publicar, comentar ou avaliar, aceita os termos da Comunidade: o que se pode publicar e o que acontece a quem não os cumpre.'),
      el('p', {}, el('a', { href: 'termos.html', target: '_blank', rel: 'noopener' }, 'Ler os termos de utilização')),
      el('form', { method: 'dialog', class: 'row end' },
        el('button', { class: 'btn quiet', value: 'cancel' }, 'Cancelar'),
        el('button', { class: 'btn primary', value: 'accept' }, 'Aceito')));
    dialog.addEventListener('close', () => { resolve(dialog.returnValue === 'accept'); dialog.remove(); });
    document.body.append(dialog);
    dialog.showModal();
  });
}

/** Aceita a versão em vigor dos termos. Devolve o erro, se houver. */
export async function acceptCurrentTerms() {
  const { data, error } = await sb.rpc('my_terms');
  if (error) return error;
  const version = data?.[0]?.version;
  if (!version) return null;
  const { error: err } = await sb.rpc('accept_terms', { p_version: version });
  return err ?? null;
}

/**
 * Corre `action` (uma chamada ao Supabase que devolve { data, error }). Se o
 * servidor pedir os termos, mostra-os e, se a pessoa aceitar, tenta outra vez.
 * Sem aceitação, devolve { cancelled: true }.
 */
export async function withTerms(action) {
  const first = await action();
  if (!isTermsError(first.error)) return first;
  if (!(await askTerms())) return { cancelled: true };
  const err = await acceptCurrentTerms();
  if (err) return { error: err };
  return action();
}

/* ------------------------------------------------------------- bloqueios */

/** As contas que a pessoa com sessão bloqueou: deixa de ver o que escrevem. */
export async function blockedSet(session) {
  if (!session) return new Set();
  const { data } = await sb.from('user_blocks').select('blocked_id');
  return new Set((data ?? []).map((b) => b.blocked_id));
}

export async function blockUser(session, userId, name) {
  if (!confirm(`Bloquear ${name}? Deixas de ver as avaliações, os comentários e os itinerários desta pessoa. Podes desbloquear na tua conta.`)) return false;
  const { error } = await sb.from('user_blocks').insert({ blocker_id: session.user.id, blocked_id: userId });
  if (error && error.code !== '23505') { alert(explain(error)); return false; }
  return true;
}

/* -------------------------------------------------------------- estrelas */

/** "4,6": uma casa decimal, com vírgula. */
export function starText(n) {
  return Number(n).toFixed(1).replace('.', ',');
}

/** Cinco estrelas, cheias até `n`, só para ver (o leitor de ecrã lê o rótulo). */
export function starRow(n, label = `${n} de 5 estrelas`) {
  return el('span', { class: 'stars', role: 'img', 'aria-label': label },
    ...[1, 2, 3, 4, 5].map((i) => {
      const s = icon('star');
      s.classList.toggle('on', i <= n);
      return s;
    }));
}
