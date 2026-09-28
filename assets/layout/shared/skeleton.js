// Esqueletos: enquanto os dados chegam, a forma do que vem a seguir.
// São só para o olho; o leitor de ecrã ouve o "A carregar…" escondido.
import { el } from '../../app.js';

const bar = (cls = '') => el('span', { class: `sk ${cls}`.trim() });

/** Um cartão de viagem por preencher (feed, perfil). */
export function cardSkeleton() {
  return el('div', { class: 'trip skeleton', 'aria-hidden': 'true' },
    el('div', { class: 'trip-head' }, bar('sk-round avatar'), bar('sk-line short')),
    el('div', { class: 'media' }, bar()),
    el('div', { class: 'trip-body' }, bar('sk-line title'), bar('sk-line short'), bar('sk-line'), bar('sk-line')),
    el('div', { class: 'actions' }, bar('sk-pill')));
}

/** Um bloco que ocupa o sítio do que carrega, com o aviso escondido para leitores de ecrã. */
export function loading(...shapes) {
  return el('div', { class: 'loading-shape' },
    el('span', { class: 'sr-only', role: 'status' }, 'A carregar…'),
    ...shapes);
}

/** Cartões por preencher, tantos quantos cabem de uma vez. */
export function cardsLoading(n = 2) {
  return loading(...Array.from({ length: n }, cardSkeleton));
}

/** O topo de um perfil por preencher. */
export function profileSkeleton() {
  return loading(
    el('div', { class: 'profile-head skeleton', 'aria-hidden': 'true' },
      el('div', { class: 'profile' }, bar('sk-round avatar lg'),
        el('div', { class: 'grow' }, bar('sk-line title'), bar('sk-line short'))),
      el('div', { class: 'stats' }, ...Array.from({ length: 4 }, () => el('div', { class: 'stat' }, bar('sk-line'))))),
    el('div', { class: 'grid skeleton', 'aria-hidden': 'true' }, ...Array.from({ length: 6 }, () => el('div', { class: 'tile' }, bar()))));
}
