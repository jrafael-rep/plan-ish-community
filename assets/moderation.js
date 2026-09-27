// Moderação: só para quem está em private.admins. O servidor recusa tudo a
// quem não está (admin_reports, admin_set_hidden, admin_set_blocked…); esta
// página só não mostra o que não se pode usar.
import { $, el, explain, header, notice, relativeDay, sb, show, signInLink, who } from './app.js';

const session = await header('');
const status = $('status');
const KIND = { itinerary: 'Itinerário', review: 'Avaliação', comment: 'Comentário' };
const RESOLUTION = { hidden: 'escondido', shown: 'mantido', dismissed: 'ignorada', blocked: 'conta bloqueada' };

if (!session) location.replace(signInLink('moderacao.html'));
else {
  const { data: admin } = await sb.rpc('am_i_admin');
  if (admin !== true) notice(status, 'Esta página é só para quem modera a Comunidade.', 'error');
  else {
    show($('moderation'), true);
    $('resolved').addEventListener('change', () => void load());
    await load();
  }
}

async function load() {
  const { data, error } = await sb.rpc('admin_reports', { p_include_resolved: $('resolved').checked });
  const box = $('reports');
  if (error) { notice(box, explain(error), 'error'); return; }
  if (!data?.length) { box.replaceChildren(el('p', { class: 'muted' }, 'Nenhuma denúncia por resolver.')); return; }
  box.replaceChildren(...data.map(item));
}

function item(r) {
  const target = r.itinerary_id ? `itinerario.html?id=${encodeURIComponent(r.itinerary_id)}#${r.kind === 'itinerary' ? '' : 'avaliacoes'}` : null;
  const act = (label, run, kind = '') => el('button', { class: `btn ${kind}`.trim(), type: 'button', onclick: async (e) => {
    e.currentTarget.disabled = true;
    const { error } = await run();
    if (error) { notice(status, explain(error), 'error'); e.currentTarget.disabled = false; return; }
    await load();
  } }, label);
  return el('div', { class: `mod-item${r.resolved_at ? ' resolved' : ''}` },
    el('div', { class: 'row' },
      el('strong', {}, KIND[r.kind] ?? r.kind),
      r.itinerary_title ? (target ? el('a', { href: target }, r.itinerary_title) : el('span', {}, r.itinerary_title)) : null,
      el('span', { class: 'state' }, r.resolved_at ? `resolvida · ${RESOLUTION[r.resolution] ?? r.resolution}` : `aberta · ${relativeDay(r.reported_at)}`),
      r.target_hidden ? el('span', { class: 'state' }, 'escondido') : null,
      r.author_blocked ? el('span', { class: 'state' }, 'conta bloqueada') : null),
    el('p', { class: 'small' }, 'Motivo: ', el('strong', {}, r.reason)),
    r.excerpt ? el('p', { class: 'excerpt' }, r.excerpt) : null,
    el('p', { class: 'small row' }, 'Autor: ', r.author_id ? who(r.author_name, r.author_id) : '—'),
    el('p', { class: 'row' },
      r.target_hidden
        ? act('Voltar a mostrar', () => sb.rpc('admin_set_hidden', { p_kind: r.kind, p_id: r.target_id, p_hidden: false }))
        : act('Esconder', () => sb.rpc('admin_set_hidden', { p_kind: r.kind, p_id: r.target_id, p_hidden: true }), 'primary'),
      r.resolved_at ? null : act('Ignorar a denúncia', () => sb.rpc('admin_dismiss_report', { p_report_id: r.report_id })),
      !r.author_id ? null : r.author_blocked
        ? act('Desbloquear a conta', () => sb.rpc('admin_set_blocked', { p_user_id: r.author_id, p_blocked: false }))
        : act('Bloquear a conta', () => {
          if (!confirm(`Bloquear ${r.author_name ?? 'esta conta'}? Deixa de publicar, avaliar, comentar e gostar, e tudo o que publicou fica escondido.`)) {
            return Promise.resolve({ error: null });
          }
          return sb.rpc('admin_set_blocked', { p_user_id: r.author_id, p_blocked: true, p_reason: r.reason });
        }, 'danger')),
  );
}
