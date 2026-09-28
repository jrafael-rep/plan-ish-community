// O itinerário no PC: à esquerda, fixo, o traçado com os dias a cores, as
// fotografias e o QR para abrir no telemóvel; à direita, o cartão com o dia a
// dia, as avaliações e a conversa. Passar o rato numa paragem acende o ponto
// no traçado, e o contrário; descer na lista acende o dia que está à vista.
import { el, icon, photoUrl } from '../../app.js';
import { DAY_COLORS, routeMap } from '../shared/route-map.js';
import qrcode from '../../vendor/qrcode.js';

/** Um QR em SVG, desenhado módulo a módulo (sem HTML vindo da biblioteca). */
function qrSvg(text) {
  const code = qrcode(0, 'M');
  code.addData(text);
  code.make();
  const n = code.getModuleCount();
  const quiet = 2;
  const size = n + quiet * 2;
  let d = '';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (code.isDark(r, c)) d += `M${c + quiet} ${r + quiet}h1v1h-1z`;
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${size} ${size}`);
  svg.setAttribute('class', 'qr');
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', 'Código QR com o link desta página');
  svg.setAttribute('shape-rendering', 'crispEdges');
  const bg = document.createElementNS(NS, 'rect');
  bg.setAttribute('width', String(size)); bg.setAttribute('height', String(size)); bg.setAttribute('fill', '#fff');
  const path = document.createElementNS(NS, 'path');
  path.setAttribute('d', d); path.setAttribute('fill', '#0A1D26');
  svg.append(bg, path);
  return svg;
}

/**
 * Monta a coluna da esquerda e liga-a à lista de dias da direita.
 * @returns {{ unmount: () => void }}
 */
export function mountItinerarySide(it, { side, list }) {
  const days = Array.isArray(it.plan?.days) ? it.plan.days : [];
  const map = routeMap(it.plan);
  const legend = el('div', { class: 'legend', role: 'group', 'aria-label': 'Ver no traçado' });
  let chosenAt = 0;
  const focusDay = (day, scroll) => {
    if (!map) return;
    for (const g of map.querySelectorAll('.leg')) g.classList.toggle('dim', day !== null && g.dataset.day !== String(day));
    for (const b of legend.children) b.setAttribute('aria-pressed', String(b.dataset.day === String(day ?? '')));
    // Enquanto a lista desce até ao dia escolhido, o dia à vista não manda.
    if (scroll) chosenAt = Date.now();
    if (scroll && day !== null) list.querySelector(`#dia-${day + 1}`)?.scrollIntoView({ block: 'start', behavior: smooth() });
  };
  if (map && days.length > 1) {
    legend.append(el('button', { class: 'legend-item', type: 'button', 'data-day': '', 'aria-pressed': 'true', onclick: () => focusDay(null, false) }, 'Todos'));
    days.forEach((_, i) => {
      const b = el('button', { class: 'legend-item', type: 'button', 'data-day': String(i), 'aria-pressed': 'false', onclick: () => focusDay(i, true) },
        el('i', { 'aria-hidden': 'true' }), `Dia ${i + 1}`);
      b.querySelector('i').style.setProperty('background', DAY_COLORS[i % DAY_COLORS.length]);
      legend.append(b);
    });
  }

  const photos = Array.isArray(it.photos) ? it.photos.slice(0, 6) : [];
  const url = new URL(`itinerario.html?id=${encodeURIComponent(it.id)}`, location.href).href;
  const copied = el('span', { class: 'small muted', role: 'status' });
  const copy = el('button', { class: 'btn quiet small-btn', type: 'button', onclick: async () => {
    try { await navigator.clipboard.writeText(url); copied.textContent = 'Link copiado.'; } catch { copied.textContent = url; }
  } }, icon('copy'), 'Copiar o link');

  side.replaceChildren(...[
    map ? el('section', { class: 'side-card map-card', 'aria-label': 'Traçado' }, map, legend) : null,
    photos.length ? el('section', { class: 'side-card photos', 'aria-label': 'Fotografias' },
      el('div', { class: `photo-grid n${Math.min(photos.length, 4)}` }, ...photos.slice(0, 4).map((p, i) => el('img', {
        src: photoUrl(p), alt: `Fotografia ${i + 1} de ${photos.length}`, loading: 'lazy', decoding: 'async', width: 640, height: 480,
      })))) : null,
    el('section', { class: 'side-card phone', 'aria-labelledby': 'phone-title' },
      qrSvg(url),
      el('div', {},
        el('h2', { id: 'phone-title' }, 'Abrir no telemóvel'),
        el('p', { class: 'small muted' }, 'Aponta a câmara ao código. No telemóvel, "Abrir no Plan-ish" leva o itinerário para a app, onde o podes copiar para o teu planeamento.'),
        el('div', { class: 'row' }, copy, copied))),
  ].filter(Boolean));
  side.hidden = false;

  // Rato na lista → ponto no traçado; rato no ponto → linha na lista.
  const light = (key, on) => {
    map?.querySelector(`circle[data-stop="${key}"]`)?.classList.toggle('on', on);
    list.querySelector(`.stop[data-stop="${key}"]`)?.classList.toggle('lit', on);
  };
  const over = (e) => { const k = e.target.closest?.('[data-stop]')?.dataset.stop; if (k) light(k, true); };
  const out = (e) => { const k = e.target.closest?.('[data-stop]')?.dataset.stop; if (k) light(k, false); };
  const pick = (e) => {
    const k = e.target.closest?.('circle[data-stop]')?.dataset.stop;
    if (k) list.querySelector(`.stop[data-stop="${k}"]`)?.scrollIntoView({ block: 'center', behavior: smooth() });
  };
  list.addEventListener('mouseover', over); list.addEventListener('mouseout', out);
  map?.addEventListener('mouseover', over); map?.addEventListener('mouseout', out); map?.addEventListener('click', pick);

  // O dia à vista na lista acende-se no traçado.
  let seen = null;
  if (map && days.length > 1 && 'IntersectionObserver' in window) {
    seen = new IntersectionObserver((entries) => {
      const visible = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
      if (visible && Date.now() - chosenAt > 1200) focusDay(Number(visible.target.dataset.day), false);
    }, { rootMargin: '-30% 0px -60% 0px' });
    for (const d of list.querySelectorAll('.day[data-day]')) seen.observe(d);
  }

  return {
    unmount() {
      seen?.disconnect();
      list.removeEventListener('mouseover', over); list.removeEventListener('mouseout', out);
      side.replaceChildren(); side.hidden = true;
    },
  };
}

function smooth() {
  return matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
}
