// Aceitar um convite para um plano partilhado.
import { $, appScheme, el, explain, header, notice, plural, sb, show, signInLink } from './app.js';

const session = await header('');
const status = $('status');
const code = (new URLSearchParams(location.search).get('c') ?? '').trim().toLowerCase();

if (!/^[a-z0-9]{12}$/.test(code)) {
  notice(status, 'Este link de convite não está completo. Pede outro a quem te convidou.', 'error');
} else if (!session) {
  status.replaceChildren(el('div', { class: 'notice' },
    'Para entrar no plano, ', el('a', { href: signInLink() }, 'entra na tua conta da Comunidade'), '.'));
} else {
  await load();
}

async function load() {
  const { data, error } = await sb.rpc('plan_invite_info', { p_code: code });
  if (error) { notice(status, explain(error), 'error'); return; }
  const info = data?.[0];
  if (!info) { notice(status, 'Este convite expirou ou não existe. Pede um novo a quem te convidou.', 'error'); return; }
  if (info.already) { location.replace(`plano.html?id=${encodeURIComponent(info.plan_id)}`); return; }
  $('invite-title').textContent = info.title;
  $('invite-who').textContent = `${info.owner_name} convidou-te para o editar em conjunto. No plano: ${plural(info.member_count, 'pessoa', 'pessoas')}.`;
  $('in-app').href = `${appScheme()}://convite?c=${encodeURIComponent(code)}`;
  show($('invite'), true);
  $('accept').addEventListener('click', async () => {
    $('accept').disabled = true;
    const { data: planId, error: err } = await sb.rpc('accept_plan_invite', { p_code: code });
    $('accept').disabled = false;
    if (err) { notice(status, explain(err), 'error'); return; }
    location.href = `plano.html?id=${encodeURIComponent(planId)}`;
  });
}
