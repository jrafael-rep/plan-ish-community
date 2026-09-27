// Claro por defeito; escuro se a pessoa o escolheu no botão do topo.
// Corre no <head>, antes de a página se desenhar, para não piscar. A escolha
// fica em localStorage e é partilhada com a página da app (mesma origem).
try {
  if (localStorage.getItem('planish-theme') === 'dark') document.documentElement.dataset.theme = 'dark';
} catch { /* sem armazenamento: fica claro */ }
