import {
  $, acceptCurrentTerms, avatar, badge, el, explain, header, monthLabel, notice, plural, relativeDay, removePhotos, sb, show,
  signInLink, starText, withdrawItinerary, WITHDRAW_WARNING,
} from './app.js';

const session = await header('conta');
const status = $('status');
if (!session) location.replace(signInLink('conta.html'));
else await load();

async function load() {
  $('email').textContent = `Entraste como ${session.user.email}`;
  const [{ data: profile }, { data: membership }] = await Promise.all([
    sb.from('profiles').select('display_name').eq('id', session.user.id).maybeSingle(),
    sb.from('memberships').select('tier, valid_until').maybeSingle(),
  ]);
  $('name').replaceChildren(avatar(profile?.display_name, 'lg'), el('span', {}, profile?.display_name ?? ''));
  $('public-profile').href = `viajante.html?id=${encodeURIComponent(session.user.id)}`;
  await loadNextName();
  const active = membership && (!membership.valid_until || new Date(membership.valid_until) > new Date());
  $('membership').textContent = active ? 'Membro da Comunidade.' : 'Conta da Comunidade.';
  await loadMine();
  // Fotos de algo retirado antes, que não chegaram a sair do Storage.
  sb.rpc('my_photo_trash').then(({ data }) => removePhotos(data), () => {});
  await loadShared();
  await loadTerms();
  await loadBlocks();
  const { data: admin } = await sb.rpc('am_i_admin');
  show($('moderation-link'), admin === true);
  await loadLinks();
  show($('account'), true);
  if (location.hash === '#planos') $('planos').scrollIntoView();
  if (location.hash === '#meus') $('meus').scrollIntoView();
}

/** Os meus itinerários: o que têm, se a moderação os escondeu, e retirar. */
async function loadMine() {
  let { data: mine, error } = await sb.rpc('my_published');
  // Sem o esquema 8, a lista simples de antes.
  if (error) {
    ({ data: mine } = await sb.from('itineraries').select('id, title, travelled_month, hidden, evidence')
      .eq('author_id', session.user.id).order('created_at', { ascending: false }));
  }
  const box = $('mine');
  if (!mine?.length) {
    box.replaceChildren(el('p', { class: 'muted' }, 'Ainda não publicaste nenhum. Publica-se a partir da app, numa viagem concluída.'));
    return;
  }
  box.replaceChildren(...mine.map((it) => {
    const facts = [
      plural(it.like_count ?? 0, 'gosto', 'gostos'),
      plural(it.comment_count ?? 0, 'comentário', 'comentários'),
      it.rating_count ? `★ ${starText(it.verified_rating_count ? it.verified_rating_avg : it.rating_avg)} (${it.rating_count})` : null,
      it.updated_at ? `mudado ${relativeDay(it.updated_at)}` : null,
    ].filter(Boolean).join(' · ');
    const withdraw = el('button', { class: 'btn quiet danger', type: 'button' }, 'Retirar');
    withdraw.addEventListener('click', async () => {
      if (!confirm(`Retirar “${it.title}” da Comunidade? ${WITHDRAW_WARNING}`)) return;
      withdraw.disabled = true;
      const err = await withdrawItinerary(it.id);
      if (err) { withdraw.disabled = false; notice(status, explain(err), 'error'); return; }
      await loadMine();
    });
    return el('div', { class: 'card mini mine-row' },
      el('a', { href: `itinerario.html?id=${encodeURIComponent(it.id)}` },
        el('strong', {}, it.title),
        it.hidden ? el('span', { class: 'chip warn' }, 'Escondido pela moderação') : null,
        el('span', { class: 'muted small block' }, facts || (it.travelled_month ? monthLabel(it.travelled_month) : ''))),
      withdraw);
  }));
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

async function loadTerms() {
  const box = $('terms');
  const { data, error } = await sb.rpc('my_terms');
  // Sem o esquema 7 ainda não há termos para aceitar.
  if (error) { show($('termos'), false); show(box, false); return; }
  const row = data?.[0];
  if (!row?.version) { box.replaceChildren(el('p', { class: 'muted' }, 'Não há termos a aceitar.')); return; }
  if (row.accepted) {
    box.replaceChildren(el('p', { class: 'muted' }, 'Aceitaste a versão em vigor dos ', el('a', { href: 'termos.html' }, 'termos de utilização'), '.'));
    return;
  }
  box.replaceChildren(
    el('p', {}, 'Para publicar, avaliar ou comentar, aceita os ', el('a', { href: 'termos.html' }, 'termos de utilização'), '.'),
    el('p', { class: 'row' }, el('button', {
      class: 'btn primary', type: 'button',
      onclick: async () => {
        const err = await acceptCurrentTerms();
        if (err) { notice(status, explain(err), 'error'); return; }
        await loadTerms();
      },
    }, 'Li e aceito')));
}

async function loadBlocks() {
  const box = $('blocks');
  const { data, error } = await sb.from('user_blocks')
    .select('blocked_id, created_at, who:profiles!user_blocks_blocked_id_fkey(display_name)').order('created_at');
  if (error) { box.replaceChildren(el('p', { class: 'muted' }, 'Ninguém.')); return; }
  box.replaceChildren(...(data?.length ? data.map((b) => el('div', { class: 'card' },
    el('strong', {}, b.who?.display_name ?? 'Viajante'),
    el('p', { class: 'row' }, el('button', { class: 'btn', type: 'button', onclick: async () => {
      await sb.from('user_blocks').delete().eq('blocker_id', session.user.id).eq('blocked_id', b.blocked_id);
      await loadBlocks();
    } }, 'Desbloquear')),
  )) : [el('p', { class: 'muted' }, 'Ninguém. Numa avaliação ou comentário, o botão ⊘ bloqueia quem o escreveu.')]));
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
  if (!confirm('Apagar a conta, os itinerários publicados, as avaliações, os comentários e os gostos? Isto não se desfaz.')) return;
  // Primeiro os itinerários, para as fotos saírem do Storage enquanto há sessão.
  const { data: photos, error: withdrawError } = await sb.rpc('withdraw_all_mine');
  if (!withdrawError) await removePhotos(photos);
  const { error } = await sb.rpc('delete_my_account');
  if (error) { notice(status, explain(error), 'error'); return; }
  await sb.auth.signOut();
  location.href = './';
});
