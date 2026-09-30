// A conta no PC: separadores em vez de uma página comprida. O dono, 30 set:
// "está muita informação sempre vertical". Cada separador junta secções que
// andam juntas; o # do endereço escolhe o separador (conta.html#pontos abre
// Pontos), e um # de uma secção leva ao separador onde ela está.
import { el } from '../../app.js';

export const ACCOUNT_TABS = [
  { id: 'perfil', label: 'Perfil', sections: ['perfil'] },
  { id: 'itinerarios', label: 'Itinerários', sections: ['meus', 'planos'] },
  { id: 'pontos', label: 'Pontos', sections: ['pontos'] },
  { id: 'privacidade', label: 'Privacidade', sections: ['termos', 'bloqueadas', 'telemoveis'] },
  { id: 'sessao', label: 'Sessão', sections: ['sessao', 'apagar'] },
];

/** O separador de uma secção (ou de um separador): 'meus' fica em Itinerários. */
export function tabFor(hash) {
  const id = (hash ?? '').replace(/^#/, '');
  return ACCOUNT_TABS.find((t) => t.id === id || t.sections.includes(id)) ?? ACCOUNT_TABS[0];
}

export function mountPcAccount() {
  const body = document.querySelector('.account-body');
  // Vindo do telemóvel, as secções ainda estão embrulhadas: desembrulha-as.
  const original = [...body.children].flatMap((n) => (n.matches('.m-group') ? [...n.children] : [n]));
  // As secções, como no telemóvel: cada h2 com id começa uma; antes é o perfil.
  const groups = new Map([['perfil', []]]);
  let current = 'perfil';
  for (const node of original) {
    if (node.matches('h2[id]')) { current = node.id; groups.set(current, []); }
    groups.get(current).push(node);
  }
  const panels = ACCOUNT_TABS.map((t) => el('div', {
    class: 'acc-panel', role: 'tabpanel', id: `painel-${t.id}`, 'aria-labelledby': `tab-${t.id}`, hidden: '',
  }, ...t.sections.flatMap((s) => groups.get(s) ?? [])));
  // O que não coube em nenhum separador (por exemplo o atalho da moderação) fica no Perfil.
  const placed = new Set(ACCOUNT_TABS.flatMap((t) => t.sections));
  for (const [id, nodes] of groups) if (!placed.has(id)) panels[0].append(...nodes);

  const tabs = ACCOUNT_TABS.map((t) => el('a', {
    href: `#${t.id}`, role: 'tab', id: `tab-${t.id}`, class: t.id === 'sessao' ? 'acc-tab end' : 'acc-tab',
    'aria-controls': `painel-${t.id}`,
  }, t.label));
  const bar = el('nav', { class: 'acc-tabs', role: 'tablist', 'aria-label': 'Secções da conta' }, ...tabs);
  body.replaceChildren(bar, ...panels);

  function show() {
    const tab = tabFor(location.hash);
    ACCOUNT_TABS.forEach((t, i) => {
      const on = t === tab;
      tabs[i].setAttribute('aria-selected', String(on));
      tabs[i].tabIndex = on ? 0 : -1;
      panels[i].hidden = !on;
    });
    // Um # de secção (#bloqueadas) mostra o separador e leva lá.
    const id = location.hash.slice(1);
    if (id && id !== tab.id) document.getElementById(id)?.scrollIntoView();
  }
  // Setas esquerda e direita entre separadores, como num tablist.
  bar.addEventListener('keydown', (e) => {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    const i = tabs.indexOf(document.activeElement);
    if (i < 0) return;
    const next = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
    next.focus();
    next.click();
  });
  addEventListener('hashchange', show);
  show();

  return {
    unmount() {
      removeEventListener('hashchange', show);
      body.replaceChildren(...original);
    },
  };
}
