import { $, el, explain, header, monthLabel, notice, sb, show, signInLink } from './app.js';

const session = await header('conta');
const status = $('status');
if (!session) location.replace(signInLink('conta.html'));
else await load();

async function load() {
  $('email').textContent = `Entraste como ${session.user.email}`;
  const [{ data: profile }, { data: membership }, { data: mine }] = await Promise.all([
    sb.from('profiles').select('display_name').eq('id', session.user.id).maybeSingle(),
    sb.from('memberships').select('tier, valid_until').maybeSingle(),
    sb.from('itineraries').select('id, title, travelled_month, hidden').eq('author_id', session.user.id).order('created_at', { ascending: false }),
  ]);
  $('name').value = profile?.display_name ?? '';
  const active = membership && (!membership.valid_until || new Date(membership.valid_until) > new Date());
  $('membership').textContent = active ? 'Membro da Comunidade.' : 'Conta da Comunidade.';
  $('mine').replaceChildren(...(mine?.length ? mine.map((it) => el('a', { class: 'card', href: `itinerario.html?id=${it.id}` },
    el('strong', {}, it.title), it.hidden ? el('span', { class: 'muted small' }, ' · escondido pela moderação') : null,
    it.travelled_month ? el('div', { class: 'muted small' }, monthLabel(it.travelled_month)) : null,
  )) : [el('p', { class: 'muted' }, 'Ainda não publicaste nenhum. Publica-se a partir da app, numa viagem concluída.')]));
  await loadLinks();
  show($('account'), true);
}

async function loadLinks() {
  const { data } = await sb.from('app_links').select('id, device_label, created_at, last_used_at').order('created_at');
  $('links').replaceChildren(...(data?.length ? data.map((link) => el('div', { class: 'card' },
    el('strong', {}, link.device_label),
    el('div', { class: 'muted small' }, `Ligado a ${new Date(link.created_at).toLocaleDateString('pt-PT')} · usado a ${new Date(link.last_used_at).toLocaleDateString('pt-PT')}`),
    el('p', { class: 'row' }, el('button', { class: 'btn', type: 'button', onclick: async () => {
      await sb.from('app_links').delete().eq('id', link.id); await loadLinks();
    } }, 'Desligar')),
  )) : [el('p', { class: 'muted' }, 'Nenhum. Na app: Comunidade › Ligar à Comunidade.')]));
}

$('name-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const { error } = await sb.from('profiles').update({ display_name: $('name').value.trim() }).eq('id', session.user.id);
  notice(status, error ? explain(error) : 'Nome guardado.', error ? 'error' : '');
});
$('signout').addEventListener('click', async () => { await sb.auth.signOut(); location.href = './'; });
$('delete').addEventListener('click', async () => {
  if (!confirm('Apagar a conta, os itinerários publicados, os comentários e os likes? Isto não se desfaz.')) return;
  const { error } = await sb.rpc('delete_my_account');
  if (error) { notice(status, explain(error), 'error'); return; }
  await sb.auth.signOut();
  location.href = './';
});
