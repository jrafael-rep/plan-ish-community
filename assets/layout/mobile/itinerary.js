// O itinerário no telemóvel: os dias um a um, a deslizar para o lado (como na
// app), e as avaliações e a conversa numa folha que sobe de baixo.
import { el } from '../../app.js';
import { openSheet } from './sheet.js';

/**
 * Os dias da lista passam a páginas que se deslizam, com os separadores
 * "Dia N" por cima. A altura acompanha o dia que se vê, para um dia curto não
 * deixar um buraco por baixo.
 */
export function mountDayPager(root) {
  const list = root.querySelector('ol.days');
  const days = list ? [...list.children].filter((d) => d.classList.contains('day')) : [];
  if (days.length < 2) return { unmount() {} };

  let current = 0;
  const chips = el('div', { class: 'm-day-chips', role: 'group', 'aria-label': 'Dias' },
    ...days.map((_, i) => el('button', {
      class: 'tab', type: 'button', 'aria-pressed': i === 0 ? 'true' : 'false',
      onclick: () => go(i),
    }, `Dia ${i + 1}`)));
  list.before(chips);
  list.classList.add('pager');

  const fit = () => list.style.setProperty('height', `${days[current].offsetHeight}px`);
  const paint = (i) => {
    if (i === current && list.style.height) return;
    current = i;
    [...chips.children].forEach((c, j) => c.setAttribute('aria-pressed', j === i ? 'true' : 'false'));
    // Só a fila dos separadores anda (scrollIntoView podia mexer na página).
    const chip = chips.children[i];
    chips.scrollTo({ left: chip.offsetLeft - (chips.clientWidth - chip.offsetWidth) / 2, behavior: 'smooth' });
    fit();
  };
  function go(i) {
    list.scrollTo({ left: i * list.clientWidth, behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
    paint(i);
  }
  const onScroll = () => {
    const i = Math.min(days.length - 1, Math.max(0, Math.round(list.scrollLeft / Math.max(1, list.clientWidth))));
    if (i !== current) paint(i);
  };
  list.addEventListener('scroll', onScroll, { passive: true });
  const resize = new ResizeObserver(fit);
  days.forEach((d) => resize.observe(d));
  // Um link para #dia-3 abre nesse dia.
  const fromHash = () => {
    const n = /^#dia-(\d+)$/.exec(location.hash)?.[1];
    if (n && days[n - 1]) go(Number(n) - 1);
  };
  addEventListener('hashchange', fromHash);
  fit();
  fromHash();

  return {
    unmount() {
      list.removeEventListener('scroll', onScroll);
      removeEventListener('hashchange', fromHash);
      resize.disconnect();
      list.classList.remove('pager');
      list.style.removeProperty('height');
      chips.remove();
    },
  };
}

/**
 * O botão da conversa abre uma folha com as avaliações e a conversa. As
 * secções mudam-se para lá (os mesmos elementos, com o que já se escreveu) e
 * voltam ao sítio quando a folha fecha.
 */
export function mountTalkSheet(button, sections) {
  if (!button || !sections.length) return { unmount() {} };
  const onClick = (e) => {
    e.preventDefault();
    const marks = sections.map((s) => {
      const mark = document.createComment('folha');
      s.before(mark);
      return mark;
    });
    openSheet({
      title: 'Avaliações e conversa',
      full: true,
      content: el('div', { class: 'talk-sheet' }, ...sections),
      onClose: () => sections.forEach((s, i) => { marks[i].replaceWith(s); }),
    });
  };
  button.addEventListener('click', onClick);
  return { unmount() { button.removeEventListener('click', onClick); } };
}
