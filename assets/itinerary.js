import {
  $, el, explain, header, icon, notice, plural, relativeDay, sb, show, signInLink, who,
} from './app.js';
import { CARD_COLUMNS, likedSet, tripCard } from './card.js';

const session = await header('');
const me = session?.user.id ?? null;
const status = $('status');
const id = new URLSearchParams(location.search).get('id') ?? '';
notice(status, 'A carregar…');

const { data: it, error } = await sb.from('itineraries').select(CARD_COLUMNS).eq('id', id).maybeSingle();

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
    const { data, error: err } = await sb.from('comments')
      .select('id, body, created_at, author_id, parent_id, like_count, author:profiles!comments_author_id_fkey(display_name)')
      .eq('itinerary_id', this.it.id).order('created_at');
    if (err) { notice(box, explain(err), 'error'); return; }
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
        me && c.author_id !== me
          ? el('button', {
            class: 'btn quiet', type: 'button', 'aria-label': 'Denunciar comentário', title: 'Denunciar comentário',
            onclick: () => void report({ comment_id: c.id }, 'este comentário'),
          }, icon('flag'))
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
      const { error: err } = await sb.from('comments').insert(row);
      send.disabled = false;
      if (err) { alert(explain(err)); return; }
      $('comment-body').value = '';
      this.cancelReply();
      await this.load();
    });
  }
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
  await new Thread(it).load();
  if (location.hash === '#conversa') $('conversa').scrollIntoView();
}
