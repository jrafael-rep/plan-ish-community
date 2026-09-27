import { $, avatar, badge, el, explain, header, monthLabel, notice, relativeDay, sb, show, signInLink } from './app.js';

const session = await header('conta');
const status = $('status');
if (!session) location.replace(signInLink('conta.html'));
else await load();

async function load() {
  $('email').textContent = `Entraste como ${session.user.email}`;
  const [{ data: profile }, { data: membership }, { data: mine }] = await Promise.all([
    sb.from('profiles').select('display_name').eq('id', session.user.id).maybeSingle(),
    sb.from('memberships').select('tier, valid_until').maybeSingle(),
    sb.from('itineraries').select('id, title, travelled_month, hidden, evidence').eq('author_id', session.user.id).order('created_at', { ascending: false }),
  ]);
  $('name').replaceChildren(avatar(profile?.display_name, 'lg'), el('span', {}, profile?.display_name ?? ''));
  $('public-profile').href = `viajante.html?id=${encodeURIComponent(session.user.id)}`;
  await loadNextName();
  const active = membership && (!membership.valid_until || new Date(membership.valid_until) > new Date());
  $('membership').textContent = active ? 'Membro da Comunidade.' : 'Conta da Comunidade.';
  $('mine').replaceChildren(...(mine?.length ? mine.map((it) => el('a', { class: 'card mini', href: `itinerario.html?id=${encodeURIComponent(it.id)}` },
    el('span', {}, el('strong', {}, it.title), it.hidden ? el('span', { class: 'muted small' }, ' · escondido pela moderação') : null,
      it.travelled_month ? el('span', { class: 'muted small block' }, monthLabel(it.travelled_month)) : null),
    badge(it.evidence ?? 'plan'),
  )) : [el('p', { class: 'muted' }, 'Ainda não publicaste nenhum. Publica-se a partir da app, numa viagem concluída.')]));
  await loadShared();
  await loadLinks();
  show($('account'), true);
  if (location.hash === '#planos') $('planos').scrollIntoView();
}

async function loadShared() {
  const { data, error } = await sb.from('shared_plan_members')
    .select('role, plan:shared_plans(id, title, updated_at)')
    .eq('user_id', session.user.id);
  const box = $('shared');
  // Sem o esquema 5, a secção simplesmente não aparece.
  if (error) { show($('planos'), false); show(box, false); return; }
  const plans = (data ?? []).filter((m) => m.plan).sort((a, b) => (a.plan.updated_at < b.plan.updated_at ? 1 : -1));
  box.replaceChildren(...(plans.length ? plans.map((m) => el('a', { class: 'card mini', href: `plano.html?id=${encodeURIComponent(m.plan.id)}` },
    el('span', {}, el('strong', {}, m.plan.title),
      el('span', { class: 'muted small block' }, `${m.role === 'owner' ? 'Teu' : 'Partilhado contigo'} · mudado ${relativeDay(m.plan.updated_at)}`)),
    el('span', { class: 'muted small' }, 'Editar'),
  )) : [el('p', { class: 'muted' }, 'Nenhum. Na app, num plano: Ações › Editar em conjunto.')]));
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

async function loadNextName() {
  const { data, error } = await sb.rpc('my_name_choices');
  const row = data?.[0];
  const box = $('next-name');
  if (error) { notice(box, explain(error), 'error'); return; }
  if (!row) { box.replaceChildren(el('p', { class: 'muted' }, 'Não há nomes livres por agora.')); return; }
  $('named-by').textContent = row.named_by ? `Escolhido por ${row.named_by}.` : '';
  if (row.chosen) {
    box.replaceChildren(el('p', {}, 'Escolheste ', el('strong', {}, row.chosen), ' para a próxima pessoa que se juntar à Comunidade.'));
    return;
  }
  if (!row.names?.length) { box.replaceChildren(el('p', { class: 'muted' }, 'Não há nomes livres por agora.')); return; }
  box.replaceChildren(
    el('p', { class: 'muted' }, 'Escolhe o nome que a próxima pessoa vai receber. Só escolhes uma vez.'),
    el('div', { class: 'choices' }, ...row.names.map((name) => el('button', {
      class: 'btn chip-btn', type: 'button',
      onclick: async () => {
        if (!confirm(`Dar o nome "${name}" à próxima pessoa? Não dá para mudar depois.`)) return;
        const { error: err } = await sb.rpc('give_next_name', { p_name: name });
        if (err) notice(status, explain(err), 'error');
        await loadNextName();
      },
    }, name))),
  );
}

$('signout').addEventListener('click', async () => { await sb.auth.signOut(); location.href = './'; });
$('delete').addEventListener('click', async () => {
  if (!confirm('Apagar a conta, os itinerários publicados, os comentários e os gostos? Isto não se desfaz.')) return;
  const { error } = await sb.rpc('delete_my_account');
  if (error) { notice(status, explain(error), 'error'); return; }
  await sb.auth.signOut();
  location.href = './';
});
