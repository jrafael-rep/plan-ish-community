// Publicar um roteiro a partir de um JSON, no painel (esquema 17).
//
// O JSON é o formato de importação da app. Antes de publicar vê-se cada
// paragem; as que não têm coordenadas procuram-se no OpenStreetMap (Nominatim,
// uma de cada vez, como pede a política deles) ou saem de um link do Google
// Maps com as coordenadas lá dentro. Nada é aceite sem se ver: cada resultado
// mostra a morada encontrada e um link para o mapa, e pode ser recusado.
import { $, el, explain, notice, sb } from './app.js';

const NOMINATIM = 'https://nominatim.openstreetmap.org/search';
let plan = null;

export function mountPublish() {
  $('plan-read').addEventListener('click', read);
}

function read() {
  const box = $('plan-preview');
  try {
    plan = JSON.parse($('plan-json').value);
  } catch (e) {
    notice(box, `O texto não é JSON válido: ${e.message}`, 'error');
    return;
  }
  if (!Array.isArray(plan?.days) || !plan.days.length) { notice(box, 'O plano não tem dias.', 'error'); return; }
  for (const key of ['home', 'participants', 'responsibilities', 'id']) delete plan[key];
  for (const s of stops()) {
    if (!has(s) && s.mapsUrl) {
      const c = fromMapsUrl(s.mapsUrl);
      if (c) Object.assign(s, c, { _found: 'do link do Google Maps' });
    }
  }
  paint();
}

function stops() {
  return plan.days.flatMap((d) => (Array.isArray(d.stops) ? d.stops : []).filter((s) => s && typeof s === 'object'));
}

const has = (s) => Number.isFinite(s.lat) && Number.isFinite(s.lon);

/** As coordenadas de um link do Google Maps, quando as traz (…/@lat,lon… ou !3d…!4d…). */
export function fromMapsUrl(url) {
  const m = /!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/.exec(url) ?? /@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/.exec(url);
  if (!m) return null;
  const lat = Number(m[1]);
  const lon = Number(m[2]);
  return Math.abs(lat) <= 90 && Math.abs(lon) <= 180 ? { lat, lon } : null;
}

function paint() {
  const all = stops();
  const missing = all.filter((s) => !has(s));
  const title = el('input', { id: 'plan-title', value: plan.name ?? '', maxlength: 120 });
  const dest = el('input', { id: 'plan-dest', value: plan.destination ?? '', maxlength: 120 });
  const summary = el('textarea', { id: 'plan-summary', rows: 3, maxlength: 2000 }, plan.summary ?? '');
  const ai = el('input', { type: 'checkbox', id: 'plan-ai', checked: '' });
  const rows = plan.days.map((d, di) => el('li', {},
    el('strong', {}, `Dia ${di + 1}${d.date ? ` · ${d.date}` : ''}`),
    el('ol', {}, ...(Array.isArray(d.stops) ? d.stops : []).map((s) => stopRow(s)))));
  $('plan-preview').replaceChildren(...[
    el('p', {}, `${plan.days.length} dias, ${all.length} paragens; ${missing.length ? `${missing.length} sem localização` : 'todas com localização'}.`),
    el('ol', { class: 'plan-days' }, ...rows),
    missing.length ? el('p', { class: 'row' },
      el('button', { class: 'btn', type: 'button', onclick: (e) => void findAll(e.currentTarget) }, `Procurar as ${missing.length} no mapa`),
      el('span', { class: 'muted small' }, 'Uma por segundo. Confirma cada uma antes de publicar.')) : null,
    el('div', { class: 'plan-form' },
      el('label', { for: 'plan-title' }, 'Título'), title,
      el('label', { for: 'plan-dest' }, 'Destino'), dest,
      el('label', { for: 'plan-summary' }, 'Resumo (opcional)'), summary,
      el('label', { class: 'check' }, ai, 'Feito com IA (aparece na fila "Feitos com IA", com a etiqueta, assinado por AI-ish)')),
    el('p', { class: 'row' }, el('button', { class: 'btn primary', type: 'button', onclick: (e) => void publish(e.currentTarget) }, 'Publicar como roteiro')),
    el('div', { id: 'plan-status' }),
  ].filter(Boolean));
}

function stopRow(s) {
  const name = s.name ?? String(s);
  if (typeof s !== 'object') return el('li', {}, name, ' ', el('span', { class: 'state bad' }, 'sem localização'));
  const where = has(s)
    ? el('span', { class: 'state ok' }, s._found ? `encontrado ${s._found}` : 'com coordenadas', ' · ',
      el('a', { href: `https://www.openstreetmap.org/?mlat=${s.lat}&mlon=${s.lon}#map=16/${s.lat}/${s.lon}`, target: '_blank', rel: 'noopener' }, 'ver no mapa'),
      s._found ? [' · ', el('button', { class: 'linklike', type: 'button', onclick: () => { delete s.lat; delete s.lon; delete s._found; delete s._address; paint(); } }, 'recusar')] : null)
    : el('span', { class: 'state bad' }, 'sem localização', s.locationQuery ? ` (procura: ${s.locationQuery})` : '');
  return el('li', {}, name, ' ', where, s._address ? el('div', { class: 'muted small' }, s._address) : null);
}

async function findAll(button) {
  button.disabled = true;
  for (const s of stops().filter((x) => !has(x))) {
    const q = s.locationQuery || s.locationName || s.name;
    if (!q) continue;
    button.textContent = `A procurar: ${s.name ?? q}…`;
    try {
      const url = `${NOMINATIM}?format=jsonv2&limit=1&accept-language=pt&q=${encodeURIComponent(q)}`;
      const [hit] = await (await fetch(url, { headers: { Accept: 'application/json' } })).json();
      if (hit) Object.assign(s, { lat: Number(hit.lat), lon: Number(hit.lon), _found: 'no OpenStreetMap', _address: hit.display_name });
    } catch { /* fica sem localização; pode tentar-se outra vez */ }
    await new Promise((r) => setTimeout(r, 1100));
  }
  paint();
}

async function publish(button) {
  const status = $('plan-status');
  const title = $('plan-title').value.trim();
  if (!title) { notice(status, 'Falta o título.', 'error'); return; }
  const clean = JSON.parse(JSON.stringify(plan, (k, v) => (k.startsWith('_') ? undefined : v)));
  clean.name = title;
  if ($('plan-dest').value.trim()) clean.destination = $('plan-dest').value.trim();
  button.disabled = true;
  const { data, error } = await sb.rpc('admin_publish_plan', {
    p_title: title, p_destination: $('plan-dest').value, p_summary: $('plan-summary').value,
    p_plan: clean, p_ai: $('plan-ai').checked,
  });
  button.disabled = false;
  if (error) { notice(status, explain(error), 'error'); return; }
  status.replaceChildren(el('p', {}, 'Publicado. ', el('a', { href: `itinerario.html?id=${encodeURIComponent(data)}` }, 'Ver o roteiro')));
  $('plan-json').value = '';
  plan = null;
}
