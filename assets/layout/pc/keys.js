// Atalhos de teclado no Explorar, só no PC. Tudo o que fazem também tem um
// botão à vista; "?" mostra a lista.
//   /        procurar
//   j / k    próxima / anterior viagem
//   l        gostar da viagem escolhida
//   Enter    abrir a viagem escolhida (é o link do título)
//   Esc      sair da procura
import { el } from '../../app.js';

const HELP = [['/', 'Procurar'], ['j', 'Viagem seguinte'], ['k', 'Viagem anterior'], ['l', 'Gostar da viagem escolhida'], ['Enter', 'Abrir a viagem escolhida'], ['?', 'Esta lista']];

export function feedKeys({ feed, search }) {
  let dialog = null;
  const cards = () => [...feed.querySelectorAll('article.trip:not(.skeleton)')];
  const current = () => document.activeElement?.closest?.('article.trip');

  function move(step) {
    const list = cards();
    if (!list.length) return;
    const at = list.indexOf(current());
    const next = list[Math.max(0, Math.min(list.length - 1, at < 0 ? 0 : at + step))];
    const target = next.querySelector('.trip-title a') ?? next;
    target.focus({ preventScroll: true });
    next.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }

  function help() {
    if (dialog?.open) { dialog.close(); return; }
    dialog = el('dialog', { class: 'terms-dialog keys-dialog', 'aria-labelledby': 'keys-title' },
      el('h2', { id: 'keys-title' }, 'Atalhos de teclado'),
      el('dl', { class: 'keys' }, ...HELP.flatMap(([k, what]) => [el('dt', {}, el('kbd', {}, k)), el('dd', {}, what)])),
      el('form', { method: 'dialog', class: 'row end' }, el('button', { class: 'btn primary' }, 'Fechar')));
    dialog.addEventListener('close', () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
  }

  function onKey(e) {
    if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return;
    const typing = e.target.closest?.('input, textarea, select, [contenteditable="true"]');
    if (typing) {
      if (e.key === 'Escape' && e.target === search) search.blur();
      return;
    }
    if (document.querySelector('dialog[open]') && e.key !== '?') return;
    if (e.key === '/') { e.preventDefault(); search.focus(); search.select(); }
    else if (e.key === 'j') { e.preventDefault(); move(1); }
    else if (e.key === 'k') { e.preventDefault(); move(-1); }
    else if (e.key === 'l') { current()?.querySelector('.act.like')?.click(); }
    else if (e.key === '?') { e.preventDefault(); help(); }
  }
  const onClick = (e) => { if (e.target.closest?.('[data-keys-help]')) help(); };
  document.addEventListener('keydown', onKey);
  document.addEventListener('click', onClick);
  search.setAttribute('aria-keyshortcuts', '/');
  return {
    stop() {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('click', onClick);
      search.removeAttribute('aria-keyshortcuts');
    },
  };
}
