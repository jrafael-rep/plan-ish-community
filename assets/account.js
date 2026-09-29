import {
  $, acceptCurrentTerms, avatar, badge, el, explain, header, monthLabel, notice, plural, relativeDay, removePhotos, sb, show,
  signInLink, starText, withdrawItinerary, WITHDRAW_WARNING,
} from './app.js';

const session = await header('conta');

/** O que cada movimento de pontos quer dizer (my_points devolve só a razão). */
const POINT_REASONS = {
  trip_done: 'Alguém fez um itinerário teu, com GPS',
  review_from_doer: 'Avaliação de quem fez um itinerário teu',
  comment: 'Comentário',
  likes: 'Gostos num itinerário teu',
  invite: 'Alguém que convidaste juntou-se',
  redeem_month: 'Trocados por 1 mês de membro',
  gift_code: 'Código de oferta criado',
};

const status = $('status');
if (!session) location.replace(signInLink('conta.html'));
else await load();

async function load() {
  $('email').textContent = `Entraste como ${session.user.email}`;
  const { data: profile } = await sb.from('profiles').select('display_name').eq('id', session.user.id).maybeSingle();
  $('name').replaceChildren(avatar(profile?.display_name, 'lg'), el('span', {}, profile?.display_name ?? ''));
  $('public-profile').href = `viajante.html?id=${encodeURIComponent(session.user.id)}`;
  await loadNextName();
  await loadMembership();
  await loadMine();
  await loadPoints();
  // Fotos de algo retirado antes, que não chegaram a sair do Storage.
  sb.rpc('my_photo_trash').then(({ data }) => removePhotos(data), () => {});
  await loadShared();
  await loadTerms();
  await loadBlocks();
  const { data: admin } = await sb.rpc('am_i_admin');
  show($('moderation-link'), admin === true);
  await loadLinks();
  show($('account'), true);
  // No telemóvel, uma lista de secções (layout/mobile/account.js).
  let mobile = null;
  const arrange = async (layout) => {
    if (layout === 'mobile' && !mobile) {
      const { mountMobileAccount } = await import('./layout/mobile/account.js');
      mobile = mountMobileAccount();
    } else if (layout !== 'mobile' && mobile) { mobile.unmount(); mobile = null; }
  };
  await arrange(document.documentElement.dataset.layout);
  addEventListener('planish:layout', (e) => void arrange(e.detail));
  if (!mobile) {
    if (location.hash === '#planos') $('planos').scrollIntoView();
    if (location.hash === '#meus') $('meus').scrollIntoView();
    if (location.hash === '#pontos') $('pontos').scrollIntoView();
  }
}

function dateText(iso) {
  return new Date(iso).toLocaleDateString('pt-PT', { day: 'numeric', month: 'long', year: 'numeric' });
}

async function loadMembership() {
  const { data: membership } = await sb.from('memberships').select('tier, valid_until').maybeSingle();
  const active = membership && (!membership.valid_until || new Date(membership.valid_until) > new Date());
  $('membership').textContent = !active ? 'Conta da Comunidade.'
    : membership.valid_until ? `Membro da Comunidade até ${dateText(membership.valid_until)}.` : 'Membro da Comunidade.';
}

/* ------------------------------------------------------------- pontos */

function moveLabel(m) {
  if (m.reason === 'revoked') return `${POINT_REASONS[m.about] ?? 'Pontos'} (retirado)`;
  return POINT_REASONS[m.reason] ?? 'Acerto';
}

async function copyText(text, input, box) {
  try { await navigator.clipboard.writeText(text); notice(box, 'Copiado.'); } catch { input?.select(); }
}

/** Saldo, trocar, códigos de oferta, convite e movimentos. Só no site. */
async function loadPoints() {
  const box = $('points');
  const { data, error } = await sb.rpc('my_points');
  // Sem o esquema 10, a secção não aparece.
  if (error) { show($('pontos'), false); show(box, false); return; }
  const p = data?.[0] ?? { balance: 0, month_cost: 500, gift_cost: 500, movements: [] };
  const act = async (button, run) => {
    button.disabled = true;
    const text = await run();
    await loadPoints();
    if (text) notice($('points-msg'), text.message, text.kind);
  };

  const month = el('button', { class: 'btn primary', type: 'button', disabled: p.balance < p.month_cost }, 'Trocar por 1 mês de membro');
  month.addEventListener('click', () => {
    if (!confirm(`Trocar ${p.month_cost} pontos por 1 mês de membro da Comunidade?`)) return;
    void act(month, async () => {
      const { data: r, error: err } = await sb.rpc('redeem_points_for_month');
      if (err) return { message: explain(err), kind: 'error' };
      await loadMembership();
      const row = r?.[0];
      return row?.outcome === 'no_end'
        ? { message: 'Já és membro sem data de fim, por isso não usámos pontos.' }
        : { message: `Feito. És membro até ${dateText(row.member_until)}.` };
    });
  });

  const gift = el('button', { class: 'btn', type: 'button', disabled: p.balance < p.gift_cost }, 'Criar código de oferta');
  gift.addEventListener('click', () => {
    if (!confirm(`Usar ${p.gift_cost} pontos num código de oferta? Quem o usar fica com 1 mês de membro. O código vale 90 dias.`)) return;
    void act(gift, async () => {
      const { data: code, error: err } = await sb.rpc('create_gift_code');
      if (err) return { message: explain(err), kind: 'error' };
      return { message: `Código criado: ${code}. Está na lista abaixo, para o copiares.` };
    });
  });

  const lowest = Math.min(p.month_cost, p.gift_cost);
  const codeInput = el('input', {
    id: 'gift-code', type: 'text', placeholder: 'PLAN-XXXX-XXXX', autocomplete: 'off', spellcheck: 'false',
    autocapitalize: 'characters', maxlength: 20, class: 'code',
  });
  const redeem = el('form', { class: 'inline-form' }, codeInput, el('button', { class: 'btn', type: 'submit' }, 'Usar código'));
  redeem.addEventListener('submit', (e) => {
    e.preventDefault();
    const code = codeInput.value.trim();
    if (!code) { codeInput.focus(); return; }
    void act(e.submitter ?? redeem.querySelector('button'), async () => {
      const { data: r, error: err } = await sb.rpc('redeem_gift_code', { p_code: code });
      if (err) return { message: explain(err), kind: 'error' };
      await loadMembership();
      const row = r?.[0];
      return row?.outcome === 'no_end'
        ? { message: 'Já és membro sem data de fim. O código continua por usar: podes dá-lo a outra pessoa.' }
        : { message: `Código aceite. És membro até ${dateText(row.member_until)}.` };
    });
  });

  const [invite, codes] = await Promise.all([inviteBlock(), giftCodesBlock()]);
  const moves = p.movements ?? [];
  box.replaceChildren(el('div', { class: 'points' },
    el('p', { class: 'points-balance' }, el('b', {}, String(p.balance)), el('span', {}, p.balance === 1 ? 'ponto' : 'pontos')),
    el('p', { class: 'muted small' }, 'Ganhas pontos quando alguém faz um itinerário teu com o GPS a confirmar, quando quem o fez o avalia, quando comentas e quando os teus itinerários juntam gostos.'),
    el('div', { class: 'row' }, month, gift),
    el('p', { class: 'muted small' }, p.balance < lowest
      ? `Cada troca usa ${lowest} pontos. Faltam ${lowest - p.balance}.`
      : `Cada troca usa ${lowest} pontos.`),
    el('div', { id: 'points-msg', role: 'status' }),
    el('h3', {}, el('label', { for: 'gift-code' }, 'Tenho um código')),
    redeem,
    invite,
    codes,
    el('h3', {}, 'Movimentos recentes'),
    moves.length
      ? el('ul', { class: 'moves' }, ...moves.map((m) => el('li', {},
        el('span', {}, moveLabel(m), el('span', { class: 'muted small block' }, relativeDay(m.created_at))),
        el('span', { class: `delta ${m.delta > 0 ? 'up' : 'down'}` }, m.delta > 0 ? `+${m.delta}` : `−${Math.abs(m.delta)}`))))
      : el('p', { class: 'muted' }, 'Ainda nenhum.'),
    el('p', { class: 'muted small' }, 'Os pontos não valem dinheiro. Ver os ', el('a', { href: 'termos.html#pontos' }, 'termos'), '.'),
  ));
}

async function inviteBlock() {
  const { data: code, error } = await sb.rpc('my_ref_code');
  if (error || !code) return null;
  const url = new URL(`./?ref=${encodeURIComponent(code)}`, location.href).href;
  const input = el('input', { id: 'invite-link', type: 'text', readonly: true, value: url });
  const hint = el('div', { role: 'status' });
  return el('div', {},
    el('h3', {}, el('label', { for: 'invite-link' }, 'O teu link de convite')),
    el('div', { class: 'inline-form' }, input,
      el('button', { class: 'btn', type: 'button', onclick: () => void copyText(url, input, hint) }, 'Copiar')),
    el('p', { class: 'muted small' }, 'Quem entrar na Comunidade por este link e depois fizer uma viagem com GPS confirmado, ou se tornar membro, dá-te 100 pontos.'),
    hint);
}

async function giftCodesBlock() {
  const { data, error } = await sb.rpc('my_gift_codes');
  if (error || !data?.length) return null;
  const now = new Date();
  const hint = el('div', { role: 'status' });
  return el('div', {},
    el('h3', {}, 'Os teus códigos de oferta'),
    el('div', {}, ...data.map((g) => {
      const expired = !g.redeemed && new Date(g.expires_at) <= now;
      const state = g.redeemed ? 'Já foi usado' : expired ? 'Expirou' : `Por usar, vale até ${dateText(g.expires_at)}`;
      return el('div', { class: 'gift-row' },
        el('span', {}, el('span', { class: 'code' }, g.code), el('span', { class: 'muted small block' }, state)),
        g.redeemed || expired ? null
          : el('button', { class: 'btn quiet', type: 'button', onclick: () => void copyText(g.code, null, hint) }, 'Copiar'));
    })),
    hint);
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

/* No PC, a secção à vista acende-se na navegação da esquerda. */
{
  const links = [...document.querySelectorAll('.account-nav a')];
  const targets = links.map((a) => document.getElementById(a.hash.slice(1))).filter(Boolean);
  if (links.length && 'IntersectionObserver' in window) {
    const seen = new IntersectionObserver((entries) => {
      const top = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
      if (!top) return;
      for (const a of links) a.setAttribute('aria-current', String(a.hash === `#${top.target.id}`));
    }, { rootMargin: '-15% 0px -70% 0px' });
    for (const t of targets) seen.observe(t);
  }
}
