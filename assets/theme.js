// Corre no <head>, antes de a página se desenhar, para não piscar.
//
// Tema: claro por defeito; escuro se a pessoa o escolheu no botão do topo. A
// escolha fica em localStorage e é partilhada com a página da app (mesma origem).
//
// Layout: o site tem três formas, não só tamanhos. <html data-layout> diz qual:
// "pc" (≥ 1024 px), "tablet" (768–1023 px) ou "mobile" (< 768 px). O CSS de
// cada uma só vale dentro do seu [data-layout], e as páginas que desenham de
// maneira diferente ouvem o evento "planish:layout" quando a janela cruza um
// limite.
(() => {
  const root = document.documentElement;
  try {
    if (localStorage.getItem('planish-theme') === 'dark') {
      root.dataset.theme = 'dark';
      document.querySelector('meta[name="color-scheme"]')?.setAttribute('content', 'dark');
      document.querySelector('meta[name="theme-color"]')?.setAttribute('content', '#0E1B26');
    }
  } catch { /* sem armazenamento: fica claro */ }

  const pc = matchMedia('(min-width: 1024px)');
  const tablet = matchMedia('(min-width: 768px)');
  const pick = () => (pc.matches ? 'pc' : tablet.matches ? 'tablet' : 'mobile');
  root.dataset.layout = pick();
  const changed = () => {
    const next = pick();
    if (next === root.dataset.layout) return;
    root.dataset.layout = next;
    dispatchEvent(new CustomEvent('planish:layout', { detail: next }));
  };
  pc.addEventListener('change', changed);
  tablet.addEventListener('change', changed);
})();
