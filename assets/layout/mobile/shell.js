// A moldura de telemóvel, em todas as páginas: separadores em baixo (onde está
// o polegar) e o topo que se esconde ao descer e volta ao subir.
import { el, icon, signInLink } from '../../app.js';

/**
 * @param {{ current: string, session: object | null, detail?: boolean }} opts
 *   detail: páginas de detalhe (itinerário) têm a sua própria barra em baixo
 *   e não levam os separadores.
 */
export function mountMobileShell({ current, session, detail = false }) {
  document.body.classList.add('m-shell');
  const top = document.querySelector('header.top');
  let tabs = null;
  if (!detail) {
    const tab = (href, label, iconName, id, extra = {}) => el('a', {
      href, class: 'm-tab', 'aria-current': current === id ? 'page' : undefined, ...extra,
    }, icon(iconName), el('span', {}, label));
    const onFeed = current === 'feed';
    tabs = el('nav', { class: 'm-tabs', 'aria-label': 'Separadores' },
      tab('./', 'Explorar', 'map', 'feed'),
      onFeed
        ? el('button', { class: 'm-tab', type: 'button', onclick: () => dispatchEvent(new CustomEvent('planish:search')) }, icon('search'), el('span', {}, 'Procurar'))
        : tab('./?procurar=1', 'Procurar', 'search', 'procurar'),
      session ? tab('./?vista=guardados', 'Guardados', 'bookmark', 'guardados') : null,
      session ? tab('conta.html', 'Conta', 'users', 'conta') : tab(signInLink(), 'Entrar', 'users', 'entrar'));
    tabs.style.setProperty('--tabs', String(tabs.children.length));
    document.body.append(tabs);
    document.body.classList.add('has-tabs');
  }

  // O topo esconde-se ao descer e volta ao subir (ou no topo da página).
  let lastY = scrollY;
  let ticking = false;
  const onScroll = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      const y = scrollY;
      const down = y > lastY + 4;
      const up = y < lastY - 4;
      if (down && y > 80) top?.classList.add('tucked');
      else if (up || y < 80) top?.classList.remove('tucked');
      lastY = y;
      ticking = false;
    });
  };
  addEventListener('scroll', onScroll, { passive: true });

  return {
    unmount() {
      removeEventListener('scroll', onScroll);
      top?.classList.remove('tucked');
      tabs?.remove();
      document.body.classList.remove('m-shell', 'has-tabs');
    },
  };
}
