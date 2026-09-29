// Uma folha que sobe de baixo, para o telemóvel. É um <dialog> (foco preso lá
// dentro, Esc fecha), puxa-se para baixo pela pega para fechar, e o Voltar do
// Android fecha a folha antes de sair da página (uma entrada no histórico).
import { el } from '../../app.js';

/**
 * @param {{ title: string, content: Node, full?: boolean, onClose?: () => void }} opts
 * @returns {{ close: () => void, dialog: HTMLDialogElement }}
 */
export function openSheet({ title, content, full = false, onClose }) {
  const titleId = `sheet-${Math.random().toString(36).slice(2, 8)}`;
  const handle = el('div', { class: 'sheet-handle', 'aria-hidden': 'true' }, el('i'));
  const closeBtn = el('button', { class: 'sheet-close', type: 'button', 'aria-label': 'Fechar' }, '✕');
  const dialog = el('dialog', { class: `sheet${full ? ' full' : ''}`, 'aria-labelledby': titleId },
    handle,
    el('div', { class: 'sheet-head' }, el('h2', { id: titleId }, title), closeBtn),
    el('div', { class: 'sheet-body' }, content));

  let closed = false;
  const finish = () => {
    if (closed) return;
    closed = true;
    removeEventListener('popstate', onPop);
    dialog.remove();
    onClose?.();
  };
  // Voltar do Android: a folha tem a sua entrada no histórico.
  history.pushState({ sheet: titleId }, '');
  const onPop = () => { if (dialog.open) dialog.close(); };
  addEventListener('popstate', onPop);
  const close = () => {
    if (closed) return;
    if (history.state?.sheet === titleId) history.back(); // o popstate fecha
    else dialog.close();
  };
  dialog.addEventListener('close', finish);
  dialog.addEventListener('cancel', (e) => { e.preventDefault(); close(); });
  closeBtn.addEventListener('click', close);
  // Tocar fora (no fundo escurecido) fecha.
  dialog.addEventListener('click', (e) => { if (e.target === dialog) close(); });

  // Puxar pela pega ou pelo título para fechar.
  let startY = null;
  let dy = 0;
  const grab = [handle, dialog.querySelector('.sheet-head')];
  for (const g of grab) {
    g.addEventListener('pointerdown', (e) => { if (e.target.closest('button')) return; startY = e.clientY; dy = 0; g.setPointerCapture(e.pointerId); dialog.classList.add('dragging'); });
    g.addEventListener('pointermove', (e) => {
      if (startY === null) return;
      dy = Math.max(0, e.clientY - startY);
      dialog.style.setProperty('--drag', `${dy}px`);
    });
    const end = () => {
      if (startY === null) return;
      startY = null;
      dialog.classList.remove('dragging');
      if (dy > 90) close(); else dialog.style.setProperty('--drag', '0px');
    };
    g.addEventListener('pointerup', end);
    g.addEventListener('pointercancel', end);
  }

  document.body.append(dialog);
  dialog.showModal();
  return { close, dialog };
}
