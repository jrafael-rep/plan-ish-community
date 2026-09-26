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

/** O cabeçalho igual em todas as páginas. */
export async function header(current) {
  const session = await currentSession();
  const link = (href, label, id) => el('a', { href, 'aria-current': current === id ? 'page' : undefined }, label);
  const top = el('header', { class: 'top' },
    el('div', { class: 'wrap' },
      el('a', { class: 'brand', href: './' }, 'Plan-ish ', el('span', {}, 'Comunidade')),
      el('nav', {},
        link('./', 'Itinerários', 'feed'),
        session ? link('conta.html', 'Conta', 'conta') : link(signInLink(), 'Entrar', 'entrar'),
      ),
    ),
  );
  document.body.prepend(top);
  document.body.append(el('footer', {}, el('div', { class: 'wrap' },
    'Itinerários partilhados por quem viajou com o Plan-ish. ',
    el('a', { href: 'https://jrafael-rep.github.io/plan-ish-releases/' }, 'Sobre a app'),
  )));
  return session;
}
