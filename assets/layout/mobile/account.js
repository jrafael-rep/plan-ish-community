// A conta no telemóvel: uma lista de secções, e cada uma abre o seu ecrã com
// "← Conta". Vive no # do endereço, por isso o Voltar do Android fecha a
// secção e um link (conta.html#pontos) abre-a direta.
import { el } from '../../app.js';

export function mountMobileAccount() {
  const body = document.querySelector('.account-body');
  const page = document.body;
  // As secções: cada título com id começa uma; o que vem antes é o perfil.
  if (!body.querySelector(':scope > .m-group')) {
    const groups = [];
    let current = el('div', { class: 'm-group', 'data-id': 'perfil' });
    groups.push(current);
    for (const node of [...body.children]) {
      if (node.matches('h2[id]')) {
        current = el('div', { class: 'm-group', 'data-id': node.id });
        groups.push(current);
      }
      current.append(node);
    }
    body.replaceChildren(...groups);
  }
  const groups = [...body.querySelectorAll(':scope > .m-group')];
  const labels = Object.fromEntries([...document.querySelectorAll('.account-nav a')].map((a) => [a.hash.slice(1), a.textContent]));

  let fromList = false;
  const list = el('nav', { class: 'm-sections', 'aria-label': 'Secções da conta' },
    ...groups.filter((g) => g.dataset.id !== 'perfil').map((g) => el('a', {
      href: `#${g.dataset.id}`, class: `m-section-link${g.dataset.id === 'apagar' ? ' danger-link' : ''}`,
      onclick: () => { fromList = true; },
    }, el('span', {}, labels[g.dataset.id] ?? g.querySelector('h2')?.textContent ?? ''), el('span', { 'aria-hidden': 'true' }, '›'))));
  groups[0].after(list);

  const backs = groups.filter((g) => g.dataset.id !== 'perfil').map((g) => {
    const back = el('button', { class: 'm-back', type: 'button', onclick: () => {
      if (fromList) history.back();
      else history.replaceState(null, '', location.pathname + location.search);
      fromList = false;
      show();
    } }, '← Conta');
    g.prepend(back);
    return back;
  });

  function show() {
    const id = location.hash.slice(1);
    const open = groups.find((g) => g.dataset.id === id && id !== 'perfil');
    page.dataset.msection = open ? id : '';
    for (const g of groups) g.classList.toggle('on', Boolean(open) && g === open);
    if (open) scrollTo(0, 0);
  }
  addEventListener('hashchange', show);
  show();

  return {
    unmount() {
      removeEventListener('hashchange', show);
      list.remove();
      for (const b of backs) b.remove();
      delete page.dataset.msection;
      for (const g of groups) g.classList.remove('on');
    },
  };
}
