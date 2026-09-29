// As notificações: quem gostou, comentou, avaliou ou fez uma viagem tua, e
// quem te começou a seguir. Abrir a página marca-as como lidas.
import { $, avatar, el, explain, header, notice, relativeDay, sb, signInLink } from './app.js';
import { loading } from './layout/shared/skeleton.js';

const session = await header('avisos');
const status = $('status');
const list = $('notifications');

const WHAT = {
  like: 'gostou de',
  comment: 'comentou',
  review: 'avaliou',
  done: 'fez a tua viagem',
  follow: 'começou a seguir-te',
};

if (!session) {
  location.replace(signInLink('notificacoes.html'));
} else {
  status.replaceChildren(loading(el('div', { class: 'sk sk-line' }), el('div', { class: 'sk sk-line short' })));
  const { data, error } = await sb.from('notifications')
    .select('id, kind, created_at, read_at, actor_id, actor:profiles!notifications_actor_id_fkey(display_name), itinerary:itineraries(id, title)')
    .order('created_at', { ascending: false }).limit(100);
  if (error) {
    notice(status, explain(error), 'error');
  } else if (!data.length) {
    notice(status, 'Ainda não há nada. Quando alguém gostar, comentar, avaliar ou fizer uma viagem tua, ou te começar a seguir, aparece aqui.');
  } else {
    status.replaceChildren();
    list.replaceChildren(...data.map((n) => {
      const name = n.actor?.display_name ?? 'Um viajante';
      const trip = n.itinerary?.title;
      const href = n.kind === 'follow'
        ? `viajante.html?id=${encodeURIComponent(n.actor_id)}`
        : n.itinerary ? `itinerario.html?id=${encodeURIComponent(n.itinerary.id)}${n.kind === 'comment' || n.kind === 'review' ? '#avaliacoes' : ''}` : undefined;
      const text = n.kind === 'follow' || n.kind === 'done'
        ? [el('strong', {}, name), ` ${WHAT[n.kind]}`, n.kind === 'done' && trip ? [' ', el('em', {}, trip)] : null]
        : [el('strong', {}, name), ` ${WHAT[n.kind]} `, trip ? el('em', {}, trip) : 'um itinerário teu'];
      return el('li', { class: `note${n.read_at ? '' : ' unread'}` },
        el(href ? 'a' : 'div', { class: 'note-link', href },
          avatar(name),
          el('span', { class: 'note-text' }, ...text.flat().filter(Boolean)),
          el('span', { class: 'when' }, relativeDay(n.created_at))));
    }));
    // Vistas: o sino volta a zero.
    const { error: err } = await sb.rpc('mark_notifications_read');
    if (!err) document.querySelector('.bell .bell-count')?.remove();
  }
}
