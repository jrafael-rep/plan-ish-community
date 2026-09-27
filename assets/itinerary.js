import {
  $, blockedSet, blockUser, el, explain, header, icon, notice, plural, relativeDay, sb, show, signInLink, starRow, starText,
  who, withTerms,
} from './app.js';
import { BASIC_COLUMNS, CARD_COLUMNS, likedSet, missingColumn, RATING_INFO, tripCard } from './card.js';

const session = await header('');
const me = session?.user.id ?? null;
// Quem a pessoa bloqueou: o que essas contas escrevem não aparece aqui.
const blocked = await blockedSet(session);
const status = $('status');
const id = new URLSearchParams(location.search).get('id') ?? '';
notice(status, 'A carregar…');

let { data: it, error } = await sb.from('itineraries').select(CARD_COLUMNS).eq('id', id).maybeSingle();
if (missingColumn(error)) ({ data: it, error } = await sb.from('itineraries').select(BASIC_COLUMNS).eq('id', id).maybeSingle());

async function loadDoneBy(it) {
  if (!it.done_count) return;
  const { data } = await sb.from('itinerary_completions')
    .select('user_id, evidence, completed_at, profile:profiles(display_name)')
    .eq('itinerary_id', it.id).order('completed_at', { ascending: false }).limit(24);
  if (!data?.length) return;
  const people = plural(it.done_count, 'pessoa', 'pessoas');
  $('done-title').textContent = it.original_done_count
    ? `Também feita por ${people}, ${it.original_done_count} com GPS`
    : `Também feita por ${people}`;
  $('people').replaceChildren(...data.map((c) => el('div', { class: `person${c.evidence === 'original' ? ' gps' : ''}` },
    who(c.profile?.display_name, c.user_id),
    el('span', { class: 'small' }, c.evidence === 'original' ? 'com GPS' : 'à mão'),
  )));
  show($('done-by'), true);
}

/** A conversa: comentários com um nível de respostas. */
class Thread {
  constructor(it) {
    this.it = it;
    this.replyTo = null;
    this.liked = new Set();
    this.form = $('comment-form');
    this.home = this.form.parentElement;
    this.setupForm();
  }

  async load() {
    const box = $('comments');
    const ask = (columns) => sb.from('comments').select(columns).eq('itinerary_id', this.it.id).order('created_at');
    let { data, error: err } = await ask('id, body, created_at, author_id, parent_id, like_count, author:profiles!comments_author_id_fkey(display_name)');
    // Sem o esquema 3, não há respostas nem gostos em comentários: mostra-se a conversa simples.
    if (missingColumn(err)) {
      ({ data, error: err } = await ask('id, body, created_at, author_id, author:profiles!comments_author_id_fkey(display_name)'));
      data = data?.map((c) => ({ ...c, parent_id: null, like_count: 0 }));
    }
    if (err) { notice(box, explain(err), 'error'); return; }
    data = data.filter((c) => !blocked.has(c.author_id));
    if (me && data.length) {
      const { data: mine } = await sb.from('comment_likes').select('comment_id').in('comment_id', data.map((c) => c.id));
      this.liked = new Set((mine ?? []).map((l) => l.comment_id));
    }
    $('comments-title').textContent = data.length ? `Conversa (${data.length})` : 'Conversa';
    // Uma resposta a um comentário que já não se vê fica como comentário solto.
    const ids = new Set(data.map((c) => c.id));
    const tops = data.filter((c) => !c.parent_id || !ids.has(c.parent_id));
    const repliesOf = (c) => data.filter((r) => r.parent_id === c.id);
    this.home.insertBefore(this.form, $('comment-signin'));
    box.replaceChildren(...(tops.length
      ? tops.map((c) => {
        const replies = repliesOf(c);
        return el('div', { class: 'thread', id: `c-${c.id}` },
          this.comment(c),
          el('div', { class: `replies${replies.length ? '' : ' empty'}`, id: `r-${c.id}` }, ...replies.map((r) => this.comment(r, c))));
      })
      : [el('p', { class: 'muted' }, 'Ainda ninguém disse nada. Já fizeste esta viagem, ou tens uma pergunta?')]));
    if (this.replyTo) this.placeForm(this.replyTo);
  }

  comment(c, parent = null) {
    const canDelete = me && (c.author_id === me || this.it.author_id === me);
    const like = el('button', {
      class: 'btn quiet like', type: 'button', onclick: () => void this.toggleLike(c, like),
    });
    this.paintLike(c, like);
    return el('div', { class: 'comment' },
      el('div', { class: 'head' },
        who(c.author?.display_name, c.author_id),
        c.author_id === this.it.author_id ? el('span', { class: 'chip' }, 'autor') : null,
        el('time', { class: 'when', datetime: c.created_at, title: new Date(c.created_at).toLocaleString('pt-PT') }, relativeDay(c.created_at)),
      ),
      el('p', { class: 'body' }, c.body),
      el('div', { class: 'tools' },
        like,
        el('button', { class: 'btn quiet', type: 'button', onclick: () => this.reply(parent ?? c, c) }, icon('reply'), 'Responder'),
        canDelete ? el('button', { class: 'btn quiet', type: 'button', onclick: () => void this.remove(c) }, 'Apagar') : null,
        c.author_id !== me
          ? el('button', {
            class: 'btn quiet', type: 'button', 'aria-label': 'Denunciar comentário', title: 'Denunciar comentário',
            onclick: () => void report({ comment_id: c.id }, 'este comentário'),
          }, icon('flag'))
          : null,
        me && c.author_id !== me
          ? el('button', {
            class: 'btn quiet', type: 'button', 'aria-label': `Bloquear ${c.author?.display_name ?? 'esta pessoa'}`, title: 'Bloquear esta pessoa',
            onclick: () => void block(c.author_id, c.author?.display_name ?? 'esta pessoa'),
          }, icon('block'))
          : null,
      ),
    );
  }

  paintLike(c, button) {
    const liked = this.liked.has(c.id);
    button.setAttribute('aria-pressed', String(liked));
    button.setAttribute('aria-label', `${liked ? 'Já gostas' : 'Gostar'} deste comentário. ${plural(c.like_count, 'gosto', 'gostos')}`);
    button.replaceChildren(icon('heart'), String(c.like_count));
  }

  async toggleLike(c, button) {
    if (!me) { location.href = signInLink(); return; }
    const liked = this.liked.has(c.id);
    button.disabled = true;
    const { error: err } = liked
      ? await sb.from('comment_likes').delete().eq('comment_id', c.id).eq('user_id', me)
      : await sb.from('comment_likes').insert({ comment_id: c.id, user_id: me });
    button.disabled = false;
    if (err) { alert(explain(err)); return; }
    if (liked) this.liked.delete(c.id); else this.liked.add(c.id);
    c.like_count += liked ? -1 : 1;
    this.paintLike(c, button);
  }

  /** Responde no fio do comentário de cima; a resposta a uma resposta fica no mesmo fio. */
  reply(top, target) {
    if (!me) { location.href = signInLink(); return; }
    this.replyTo = { top, name: target.author?.display_name ?? 'Viajante' };
    this.placeForm(this.replyTo);
    $('comment-body').focus();
  }

  placeForm({ top, name }) {
    const replies = document.getElementById(`r-${top.id}`);
    if (!replies) { this.cancelReply(); return; }
    replies.classList.remove('empty');
    replies.append(this.form);
    $('replying').replaceChildren(icon('reply'), el('span', {}, 'A responder a ', el('strong', {}, name)),
      el('button', { class: 'btn quiet', type: 'button', onclick: () => this.cancelReply() }, 'Cancelar'));
    show($('replying'), true);
    $('comment-label').textContent = 'A tua resposta';
    $('comment-send').textContent = 'Responder';
  }

  cancelReply() {
    const from = this.form.parentElement;
    this.replyTo = null;
    show($('replying'), false);
    $('comment-label').textContent = 'Comentar';
    $('comment-send').textContent = 'Publicar';
    this.home.insertBefore(this.form, $('comment-signin'));
    if (from?.classList.contains('replies') && !from.children.length) from.classList.add('empty');
  }

  async remove(c) {
    if (!confirm('Apagar este comentário? As respostas a ele também desaparecem.')) return;
    const { error: err } = await sb.from('comments').delete().eq('id', c.id);
    if (err) { alert(explain(err)); return; }
    if (this.replyTo?.top.id === c.id) this.cancelReply();
    await this.load();
  }

  setupForm() {
    if (!me) {
      const hint = $('comment-signin');
      hint.replaceChildren(el('a', { href: signInLink() }, 'Entra na tua conta'), ' para comentar, responder e gostar de comentários.');
      show(hint, true);
      return;
    }
    show(this.form, true);
    this.form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const body = $('comment-body').value.trim();
      if (!body) return;
      const send = $('comment-send');
      send.disabled = true;
      const row = { itinerary_id: this.it.id, author_id: me, body };
      if (this.replyTo) row.parent_id = this.replyTo.top.id;
      const result = await withTerms(() => sb.from('comments').insert(row));
      send.disabled = false;
      if (result.cancelled) return;
      if (result.error) { alert(explain(result.error)); return; }
      $('comment-body').value = '';
      this.cancelReply();
      await this.load();
    });
  }
}

/**
 * As avaliações: estrelas, comentário, ou os dois, uma por conta. As de quem
 * fez este itinerário com o GPS a confirmar vêm primeiro e contam para a
 * estrela em destaque; as outras vêm a seguir.
 */
class Reviews {
  constructor(it) {
    this.it = it;
    this.mine = null;
    this.stars = null;
    this.setupForm();
  }

  async load() {
    const { data, error: err } = await sb.from('reviews')
      .select('id, stars, body, verified, hidden, updated_at, author_id, author:profiles!reviews_author_id_fkey(display_name)')
      .eq('itinerary_id', this.it.id).order('verified', { ascending: false }).order('updated_at', { ascending: false });
    if (err) {
      // Sem o esquema 7 não há avaliações: a secção fica de fora.
      if (missingColumn(err) || /reviews/.test(err.message ?? '')) show($('avaliacoes'), false);
      else notice($('score'), explain(err), 'error');
      return;
    }
    this.mine = me ? data.find((r) => r.author_id === me) ?? null : null;
    const visible = data.filter((r) => !r.hidden && !blocked.has(r.author_id));
    this.paintScore(visible);
    this.paintGroup($('reviews-made'), visible.filter((r) => r.verified), 'De quem fez este percurso', 'shield');
    this.paintGroup($('reviews-other'), visible.filter((r) => !r.verified), 'Outras avaliações', null);
    this.paintForm();
  }

  paintScore(list) {
    const rated = (l) => l.filter((r) => r.stars);
    const avg = (l) => l.reduce((n, r) => n + r.stars, 0) / l.length;
    const made = rated(list.filter((r) => r.verified));
    const all = rated(list);
    const box = $('score');
    if (!all.length) {
      box.replaceChildren(el('p', { class: 'muted' }, list.length
        ? 'Ainda sem estrelas.'
        : 'Ainda ninguém avaliou. Fizeste esta viagem? Conta como correu.'));
      return;
    }
    box.replaceChildren(el('div', { class: 'score' },
      made.length
        ? el('span', { class: 'big', 'aria-label': `${starText(avg(made))} estrelas` }, icon('star'), starText(avg(made)))
        : null,
      made.length ? el('span', { class: 'who' }, `de ${plural(made.length, 'pessoa que fez', 'pessoas que fizeram')} com GPS`) : null,
      el('span', { class: 'rating-all' },
        made.length ? `(${starText(avg(all))} · ${plural(all.length, 'avaliação', 'avaliações')})` : `★ ${starText(avg(all))} · ${plural(all.length, 'avaliação', 'avaliações')}`,
        el('button', { class: 'info', type: 'button', title: RATING_INFO, 'aria-label': RATING_INFO, onclick: () => alert(RATING_INFO) }, icon('info'))),
    ));
  }

  paintGroup(box, list, title, badgeIcon) {
    show(box, list.length > 0);
    if (!list.length) return;
    box.replaceChildren(
      el('h3', {}, badgeIcon ? icon(badgeIcon) : null, `${title} (${list.length})`),
      ...list.map((r) => this.review(r)));
  }

  review(r) {
    return el('div', { class: `review${r.verified ? ' verified' : ''}` },
      el('div', { class: 'head' },
        who(r.author?.display_name, r.author_id),
        r.verified ? el('span', { class: 'chip made' }, icon('shield'), 'Fez este percurso') : null,
        r.stars ? starRow(r.stars) : null,
        el('time', { class: 'when', datetime: r.updated_at, title: new Date(r.updated_at).toLocaleString('pt-PT') }, relativeDay(r.updated_at)),
      ),
      r.body ? el('p', { class: 'body' }, r.body) : null,
      r.author_id !== me
        ? el('div', { class: 'tools' },
          el('button', {
            class: 'btn quiet', type: 'button', 'aria-label': 'Denunciar avaliação', title: 'Denunciar avaliação',
            onclick: () => void report({ review_id: r.id }, 'esta avaliação'),
          }, icon('flag')),
          me ? el('button', {
            class: 'btn quiet', type: 'button', 'aria-label': `Bloquear ${r.author?.display_name ?? 'esta pessoa'}`, title: 'Bloquear esta pessoa',
            onclick: () => void block(r.author_id, r.author?.display_name ?? 'esta pessoa'),
          }, icon('block')) : null)
        : null,
    );
  }

  setupForm() {
    if (!me) {
      const hint = $('review-signin');
      hint.replaceChildren(el('a', { href: signInLink() }, 'Entra na tua conta'), ' para avaliar ou comentar esta viagem.');
      show(hint, true);
      return;
    }
    if (this.it.author_id === me) return;
    const fieldset = $('star-input');
    this.starLabels = [1, 2, 3, 4, 5].map((n) => {
      const input = el('input', { type: 'radio', name: 'stars', value: String(n), 'aria-label': plural(n, 'estrela', 'estrelas') });
      input.addEventListener('click', () => {
        // Tocar outra vez na estrela escolhida tira as estrelas: um comentário sozinho também vale.
        this.stars = this.stars === n ? null : n;
        if (this.stars === null) input.checked = false;
        this.paintStars();
      });
      return el('label', {}, input, icon('star'));
    });
    fieldset.append(...this.starLabels);
    $('review-delete').addEventListener('click', () => void this.remove());
    $('my-review').addEventListener('submit', (e) => { e.preventDefault(); void this.save(); });
    show($('my-review'), true);
  }

  paintStars() {
    this.starLabels?.forEach((label, i) => label.classList.toggle('on', this.stars !== null && i < this.stars));
  }

  paintForm() {
    if (!me || this.it.author_id === me) return;
    const r = this.mine;
    this.stars = r?.stars ?? null;
    this.paintStars();
    this.starLabels?.forEach((label, i) => { label.querySelector('input').checked = this.stars === i + 1; });
    $('review-body').value = r?.body ?? '';
    $('my-review-title').textContent = r ? 'A tua avaliação' : 'Avaliar ou comentar';
    $('review-send').textContent = r ? 'Guardar alterações' : 'Publicar';
    show($('review-delete'), Boolean(r));
    $('review-note').textContent = r?.hidden
      ? 'A moderação da Comunidade escondeu esta avaliação.'
      : r?.verified
        ? 'Fizeste esta viagem com o GPS a confirmar: a tua avaliação conta em destaque.'
        : 'Se fizeres esta viagem com a app e o GPS a confirmar, a tua avaliação passa a contar em destaque.';
  }

  async save() {
    const body = $('review-body').value.trim();
    if (this.stars === null && !body) { alert('Dá estrelas, escreve um comentário, ou as duas coisas.'); return; }
    const send = $('review-send');
    send.disabled = true;
    const result = await withTerms(() => sb.rpc('review_itinerary', {
      p_itinerary_id: this.it.id, p_stars: this.stars, p_body: body || null,
    }));
    send.disabled = false;
    if (result.cancelled) return;
    if (result.error) { alert(explain(result.error)); return; }
    await this.load();
    await refreshCard();
  }

  async remove() {
    if (!confirm('Apagar a tua avaliação? Deixa de contar nas estrelas.')) return;
    const { error: err } = await sb.rpc('delete_my_review', { p_itinerary_id: this.it.id });
    if (err) { alert(explain(err)); return; }
    await this.load();
    await refreshCard();
  }
}

/** O cartão de cima volta a ler as estrelas e as contagens depois de uma avaliação. */
async function refreshCard() {
  const { data } = await sb.from('itineraries').select(CARD_COLUMNS).eq('id', id).maybeSingle();
  if (!data) return;
  const liked = await likedSet(session, [data.id]);
  $('card').replaceChildren(tripCard(data, { session, liked: liked.has(data.id), open: true, page: true }));
}

async function block(userId, name) {
  if (!me || !userId) return;
  if (await blockUser(session, userId, name)) location.reload();
}

async function report(target, what) {
  const reason = prompt(`O que se passa com ${what}? (conteúdo ofensivo, spam, dados pessoais de alguém…)`);
  if (!reason || !reason.trim()) return;
  const { error: err } = await sb.from('reports').insert({ ...target, reason: reason.trim().slice(0, 500) });
  alert(err ? explain(err) : 'Obrigado. Vamos ver o que se passa.');
}

// Depois das definições: uma classe não existe antes da sua linha.
if (error || !it) {
  notice(status, error ? explain(error) : 'Este itinerário não existe ou já não está publicado.', 'error');
} else {
  status.replaceChildren();
  document.title = `${it.title} · Comunidade Plan-ish`;
  const liked = await likedSet(session, [it.id]);
  $('card').replaceChildren(tripCard(it, { session, liked: liked.has(it.id), open: true, page: true }));
  show($('itinerary'), true);
  $('report').replaceChildren(icon('flag'), 'Denunciar este itinerário');
  $('report').addEventListener('click', () => void report({ itinerary_id: it.id }, 'este itinerário'));
  await loadDoneBy(it);
  await new Reviews(it).load();
  await new Thread(it).load();
  if (location.hash === '#conversa') $('conversa').scrollIntoView();
  if (location.hash === '#avaliacoes') $('avaliacoes').scrollIntoView();
}
