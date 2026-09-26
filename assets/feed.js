import { $, el, explain, header, monthLabel, notice, plural, sb } from './app.js';

await header('feed');
const status = $('status');
notice(status, 'A carregar…');

const { data, error } = await sb.from('itineraries')
  .select('id, title, destination, summary, day_count, stop_count, travelled_month, like_count, comment_count, author:profiles(display_name)')
  .order('created_at', { ascending: false })
  .limit(60);

if (error) {
  notice(status, explain(error), 'error');
} else if (!data.length) {
  notice(status, 'Ainda não há itinerários publicados. O primeiro pode ser o teu: no Plan-ish, abre uma viagem concluída e escolhe "Publicar na Comunidade".');
} else {
  status.replaceChildren();
  $('feed').replaceChildren(...data.map((it) => el('a', { class: 'card', href: `itinerario.html?id=${encodeURIComponent(it.id)}` },
    el('h3', {}, it.title),
    it.summary ? el('p', { class: 'muted', style: undefined }, it.summary.length > 180 ? `${it.summary.slice(0, 180)}…` : it.summary) : null,
    el('div', { class: 'meta' },
      it.destination ? el('span', {}, it.destination) : null,
      el('span', {}, plural(it.day_count, 'dia', 'dias')),
      el('span', {}, plural(it.stop_count, 'paragem', 'paragens')),
      it.travelled_month ? el('span', {}, monthLabel(it.travelled_month)) : null,
      el('span', {}, `♥ ${it.like_count}`),
      el('span', {}, `💬 ${it.comment_count}`),
      el('span', {}, `por ${it.author?.display_name ?? 'Viajante'}`),
    ),
  )));
}
