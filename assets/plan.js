// O editor de um plano partilhado, ao vivo.
//
// Cada alteração sai meio segundo depois de parar de escrever (ou logo, se
// for mexer em paragens), e chega aos outros pelo Supabase Realtime. Quem
// está na página aparece em cima. Se o tempo real falhar, a página pergunta
// o que mudou a cada três segundos.
import {
  $, appScheme, avatar, el, explain, header, notice, sb, show, signInLink,
} from './app.js';
import {
  addDay, addStop, buildModel, clockOf, dayLabel, durationText, moveToDay, moveWithinDay, remove,
  peopleLabel, setField, setStart, setStopPeople,
} from './plan-model.js';

const session = await header('');
const planId = new URLSearchParams(location.search).get('id') ?? '';
const status = $('status');
if (!session) location.replace(signInLink());

const me = session?.user.id;
const client = `web-${Math.random().toString(36).slice(2, 10)}`;
/** O plano como o servidor o tem, mais o que esta página já escreveu. */
const fields = new Map();
const revs = new Map();
let maxRev = 0;
/** O que se escreveu aqui e ainda não saiu. */
const pending = new Map();
/** O que saiu daqui e ainda não voltou pelo tempo real. */
const inFlight = new Map();
let model = buildModel(fields);
let members = [];
let myRole = null;
let lastChange = null;
let flushTimer = null;
let pollTimer = null;
let realtimeOk = false;
/** O que outra pessoa acabou de mudar, e até quando se destaca. */
const flashes = new Map();

const SCHEMA_MISSING = new Set(['42P01', 'PGRST205', 'PGRST202', '42883']);


async function start() {
  notice(status, 'A abrir o plano…');
  const [{ data: plan, error }, { data: people }] = await Promise.all([
    sb.from('shared_plans').select('id, title, owner_id').eq('id', planId).maybeSingle(),
    sb.from('shared_plan_members').select('user_id, role, profile:profiles(display_name)').eq('plan_id', planId),
  ]);
  if (error) {
    notice(status, SCHEMA_MISSING.has(error.code) ? 'Os planos partilhados ainda não estão ativos na Comunidade.' : explain(error), 'error');
    return;
  }
  if (!plan) { notice(status, 'Este plano não existe ou não está partilhado contigo.', 'error'); return; }
  members = (people ?? []).map((m) => ({ id: m.user_id, role: m.role, name: m.profile?.display_name ?? 'Viajante' }));
  myRole = members.find((m) => m.id === me)?.role ?? null;
  if (!(await catchUp())) return;
  status.replaceChildren();
  document.title = `${model.trip.name ?? plan.title} · Plano partilhado`;
  show($('plan'), true);
  wire();
  render();
  renderMembers();
  listen();
}

/* ------------------------------------------------------------ servidor */

async function catchUp() {
  const { data, error } = await sb.from('shared_plan_fields')
    .select('key, value, rev, client_id, author_id, updated_at')
    .eq('plan_id', planId).gt('rev', maxRev).order('rev');
  if (error) { notice(status, explain(error), 'error'); return false; }
  if (data.length) receive(data, maxRev > 0);
  return true;
}

function receive(rows, remote = true) {
  for (const row of rows) {
    const rev = Number(row.rev);
    if (rev <= (revs.get(row.key) ?? 0)) continue;
    revs.set(row.key, rev);
    maxRev = Math.max(maxRev, rev);
    // O eco do que esta página escreveu. (Não se compara o valor: o servidor
    // pode devolver um objeto com as chaves noutra ordem.)
    if (row.client_id === client) {
      // Com duas escritas do mesmo campo a caminho, o eco da primeira traria
      // de volta o texto antigo: só a última conta.
      const left = (inFlight.get(row.key) ?? 1) - 1;
      if (left > 0) { inFlight.set(row.key, left); continue; }
      inFlight.delete(row.key);
      fields.set(row.key, row.value);
      continue;
    }
    // Uma escrita de outra pessoa mais antiga do que a nossa, ainda a caminho.
    if (inFlight.has(row.key)) continue;
    fields.set(row.key, row.value);
    if (remote) {
      flashes.set(row.key, Date.now() + 1600);
      lastChange = { author: row.author_id, at: row.updated_at ?? new Date().toISOString() };
    }
  }
  model = buildModel(fields);
  scheduleRender();
}

function listen() {
  const channel = sb.channel(`plan:${planId}`, { config: { presence: { key: me } } });
  channel.on('postgres_changes', {
    event: '*', schema: 'public', table: 'shared_plan_fields', filter: `plan_id=eq.${planId}`,
  }, (payload) => { if (payload.new?.key) receive([payload.new]); });
  channel.on('presence', { event: 'sync' }, () => renderPresence(channel.presenceState()));
  channel.subscribe(async (state) => {
    if (state === 'SUBSCRIBED') {
      realtimeOk = true;
      paintLive();
      const mine = members.find((m) => m.id === me);
      await channel.track({ name: mine?.name ?? 'Viajante', since: Date.now() });
      // O que mudou entre a primeira leitura e a ligação ficar ativa.
      await catchUp();
    } else if (state === 'CHANNEL_ERROR' || state === 'TIMED_OUT' || state === 'CLOSED') {
      realtimeOk = false;
      paintLive();
    }
  });
  // Rede de segurança: com tempo real, de vez em quando; sem ele, a cada 3 s.
  const tick = async () => {
    if (!document.hidden) await catchUp();
    pollTimer = setTimeout(tick, realtimeOk ? 30_000 : 3_000);
  };
  pollTimer = setTimeout(tick, 3_000);
  addEventListener('beforeunload', () => { clearTimeout(pollTimer); void flush(); });
}

async function write(changes) {
  if (!changes.length) return;
  for (const c of changes) {
    fields.set(c.key, c.value);
    inFlight.set(c.key, (inFlight.get(c.key) ?? 0) + 1);
  }
  model = buildModel(fields);
  scheduleRender();
  const { error } = await sb.rpc('write_plan_fields', { p_plan: planId, p_client: client, p_fields: changes });
  if (error) {
    for (const c of changes) {
      const left = (inFlight.get(c.key) ?? 1) - 1;
      if (left > 0) inFlight.set(c.key, left); else inFlight.delete(c.key);
    }
    paintLive(explain(error));
    // Sem rede: tenta outra vez; recusado por outra razão: volta ao que o servidor tem.
    if (/Failed to fetch|NetworkError/.test(error.message ?? '')) setTimeout(() => void write(changes), 3_000);
    else await catchUp();
    return;
  }
  paintLive();
}

/** O que se escreveu num campo de texto sai quando se para de escrever. */
function queue(key, value) {
  pending.set(key, value);
  clearTimeout(flushTimer);
  flushTimer = setTimeout(() => void flush(), 500);
}

async function flush() {
  clearTimeout(flushTimer);
  if (!pending.size) return;
  const changes = [...pending].map(([key, value]) => ({ key, value }));
  pending.clear();
  await write(changes);
}

/* ------------------------------------------------------------- mostrar */

let renderQueued = false;
function scheduleRender() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => { renderQueued = false; render(); });
}

/** Volta a desenhar sem tirar o cursor a quem está a escrever. */
function render() {
  const active = document.activeElement;
  const focusKey = active?.dataset?.key;
  const caret = focusKey && 'selectionStart' in active ? [active.selectionStart, active.selectionEnd] : null;
  // O que está na caixa onde se escreve é da pessoa, até sair dela.
  const typed = focusKey && 'value' in active ? active.value : null;
  const openNotes = new Set([...document.querySelectorAll('details[data-notes][open]')].map((d) => d.dataset.notes));

  const title = $('title');
  if (document.activeElement !== title) title.value = pending.get('trip:trip:name') ?? model.trip.name ?? '';
  const range = [model.trip.startDate, model.trip.endDate].filter(Boolean).map(dayLabel).join(' – ');
  $('dates').textContent = [model.trip.destination, range, `${model.stopCount} ${model.stopCount === 1 ? 'paragem' : 'paragens'}`]
    .filter(Boolean).join(' · ');

  $('days').replaceChildren(...(model.days.length
    ? model.days.map((day, i) => dayCard(day, i, openNotes))
    : [el('p', { class: 'muted' }, 'Este plano ainda não tem dias.')]));
  $('ideas').replaceChildren(...(model.ideas.length
    ? model.ideas.map((idea) => el('li', {}, idea.name ?? 'Ideia'))
    : [el('li', { class: 'muted' }, 'Sem ideias guardadas.')]));
  $('checklist').replaceChildren(...(model.checklist.length
    ? model.checklist.map((item) => el('li', {}, item.label ?? ''))
    : [el('li', { class: 'muted' }, 'Nada na lista.')]));

  if (focusKey) {
    const again = document.querySelector(`[data-key="${CSS.escape(focusKey)}"]`);
    if (again) {
      if (typed !== null && again.type !== 'time' && again.value !== typed) again.value = typed;
      again.focus({ preventScroll: true });
      if (caret && 'setSelectionRange' in again) { try { again.setSelectionRange(...caret); } catch { /* campos sem cursor */ } }
    }
  }
  // O destaque dura o mesmo que a animação, mesmo que a página se redesenhe
  // entretanto (outra alteração a chegar logo a seguir).
  const now = Date.now();
  for (const [key, until] of flashes) {
    if (until < now) { flashes.delete(key); continue; }
    const [entity, ...rest] = key.split(':');
    const slot = rest.slice(0, -1).join(':');
    const node = document.querySelector(`[data-key="${CSS.escape(key)}"]`)
      ?? document.querySelector(`[data-${entity}="${CSS.escape(slot)}"]`);
    if (!node) continue;
    node.classList.add('flash');
    node.style.animationDelay = `${-(1600 - (until - now))}ms`;
  }
  paintLive();
}

/** Um campo de texto ligado a uma chave. */
function field(key, value, attrs = {}, kind = 'text') {
  const current = pending.has(key) ? pending.get(key) : value;
  const input = el(attrs.multiline ? 'textarea' : 'input', {
    ...attrs, multiline: undefined, 'data-key': key, type: attrs.multiline ? undefined : kind,
  });
  input.value = current ?? '';
  input.addEventListener('input', () => {
    if (kind === 'number') {
      const n = Math.round(Number(input.value));
      if (input.value !== '' && Number.isFinite(n) && n >= 0 && n <= 24 * 60) queue(key, n);
    } else {
      queue(key, input.value);
    }
  });
  input.addEventListener('blur', () => void flush());
  return input;
}

function dayCard(day, index, openNotes) {
  const others = model.days.filter((d) => d.id !== day.id);
  return el('article', { class: 'day-card', 'data-day': day.slot },
    el('div', { class: 'day-top' },
      el('span', { class: 'day-n' }, `Dia ${index + 1}`),
      el('span', { class: 'muted small' }, dayLabel(day.date)),
      el('button', {
        class: 'btn quiet danger', type: 'button', 'aria-label': `Apagar o dia ${index + 1}`,
        onclick: () => {
          const n = day.stops.length;
          if (!confirm(`Apagar o dia ${index + 1}${n ? ` e as suas ${n === 1 ? 'paragem' : `${n} paragens`}` : ''}? Desaparece para todos.`)) return;
          void write(remove('day', day.slot));
        },
      }, 'Apagar dia'),
    ),
    field(`day:${day.slot}:title`, day.title, { class: 'day-title', 'aria-label': `Título do dia ${index + 1}`, maxlength: 120 }),
    el('ol', { class: 'edit-stops' }, ...day.stops.map((stop, i) => stopRow(day, stop, i, others, openNotes))),
    addStopForm(day),
  );
}

function stopRow(day, stop, i, others, openNotes) {
  const clock = clockOf(stop.scheduledTime);
  const time = el('input', { type: 'time', value: clock, 'aria-label': `Hora marcada de ${stop.name ?? 'paragem'}`, 'data-key': `stop:${stop.slot}:scheduledTime` });
  time.addEventListener('change', () => void write(setStart(stop, time.value)));
  const where = stop.locationName ?? stop.locationAddress ?? stop.place?.name
    ?? (Number.isFinite(stop.lat) && (stop.lat || stop.lon) ? 'com localização' : 'sem localização');
  const move = el('select', { 'aria-label': `Mudar ${stop.name ?? 'paragem'} para outro dia` },
    el('option', { value: '' }, 'Mudar de dia…'),
    ...others.map((d) => el('option', { value: d.id }, `${d.title || 'Dia'} · ${dayLabel(d.date)}`)));
  move.addEventListener('change', () => { if (move.value) void write(moveToDay(model, stop.slot, move.value)); });
  const notes = el('details', { 'data-notes': stop.slot, open: openNotes.has(stop.slot) || undefined },
    el('summary', {}, stop.description ? 'Notas' : 'Acrescentar notas'),
    field(`stop:${stop.slot}:description`, stop.description, { multiline: true, 'aria-label': `Notas de ${stop.name ?? 'paragem'}`, maxlength: 4000 }));
  return el('li', { class: 'edit-stop', 'data-stop': stop.slot },
    el('div', { class: 'stop-main' },
      field(`stop:${stop.slot}:name`, stop.name, { class: 'stop-name-input', 'aria-label': `Nome da paragem ${i + 1}`, maxlength: 200 }),
      el('div', { class: 'stop-fields' },
        el('label', { class: 'inline' }, 'Duração',
          field(`stop:${stop.slot}:durationMin`, stop.durationMin, { min: 0, max: 1440, step: 5, inputmode: 'numeric', 'aria-label': `Duração em minutos de ${stop.name ?? 'paragem'}` }, 'number'),
          el('span', { class: 'muted small' }, stop.durationMin >= 60 ? `min · ${durationText(stop.durationMin)}` : 'min')),
        el('label', { class: 'inline' }, 'Hora', time,
          clock ? null : el('span', { class: 'muted small' }, 'automática')),
      ),
      el('p', { class: 'muted small where' }, where),
      model.people.length >= 2 ? peoplePicker(stop) : null,
      notes,
    ),
    el('div', { class: 'stop-tools' },
      el('button', { class: 'btn quiet', type: 'button', disabled: i === 0 || undefined, 'aria-label': `Subir ${stop.name ?? 'paragem'}`, onclick: () => void write(moveWithinDay(day, stop.slot, -1)) }, '↑'),
      el('button', { class: 'btn quiet', type: 'button', disabled: i === day.stops.length - 1 || undefined, 'aria-label': `Descer ${stop.name ?? 'paragem'}`, onclick: () => void write(moveWithinDay(day, stop.slot, 1)) }, '↓'),
      others.length ? move : null,
      el('button', {
        class: 'btn quiet danger', type: 'button', 'aria-label': `Apagar ${stop.name ?? 'paragem'}`,
        onclick: () => { if (confirm(`Apagar “${stop.name ?? 'esta paragem'}”? Desaparece para todos.`)) void write(remove('stop', stop.slot)); },
      }, 'Apagar'),
    ),
  );
}

/** Para quem é a paragem: um ramo, quando não é de todos. */
function peoplePicker(stop) {
  const ids = Array.isArray(stop.forParticipantIds) ? stop.forParticipantIds : [];
  const label = peopleLabel(model, stop);
  return el('details', { class: 'people-pick' },
    el('summary', {}, label ? `Para quem: ${label.replace(/^Só /, 'só ')}` : 'Para quem: todos'),
    ...model.people.map((p) => {
      const box = el('input', { type: 'checkbox', checked: !ids.length || ids.includes(p.id) || undefined });
      box.addEventListener('change', () => {
        const current = ids.length ? ids : model.people.map((x) => x.id);
        const next = box.checked ? [...current, p.id] : current.filter((x) => x !== p.id);
        if (!next.length) { box.checked = true; return; } // alguém tem de fazer a paragem
        void write(setStopPeople(model, stop, next));
      });
      return el('label', { class: 'inline' }, box, p.name);
    }),
    el('p', { class: 'muted small' }, 'Só de algumas pessoas é um ramo: na app, cada uma vê o seu plano, com as suas horas.'),
  );
}

function addStopForm(day) {
  const name = el('input', { placeholder: 'Nova paragem', 'aria-label': `Nova paragem em ${day.title || 'este dia'}`, maxlength: 200 });
  return el('form', {
    class: 'add-stop',
    onsubmit: (e) => {
      e.preventDefault();
      if (!name.value.trim()) return;
      const { changes } = addStop(model, day.id, name.value);
      name.value = '';
      void write(changes);
    },
  }, name, el('button', { class: 'btn', type: 'submit' }, 'Acrescentar'));
}

function nameOf(id) {
  return members.find((m) => m.id === id)?.name ?? 'Alguém';
}

function paintLive(error) {
  const box = $('live');
  if (!box) return;
  const since = lastChange ? Math.round((Date.now() - Date.parse(lastChange.at)) / 1000) : null;
  const when = since === null ? '' : since < 10 ? 'agora mesmo' : since < 60 ? `há ${since} s` : since < 3600 ? `há ${Math.round(since / 60)} min` : '';
  // replaceChildren escreveria "null": só entra o que existe.
  box.replaceChildren(...[
    el('span', { class: `live-dot${realtimeOk && !error ? ' on' : ''}`, 'aria-hidden': 'true' }),
    el('span', {}, error ?? (realtimeOk ? 'Ao vivo' : 'A ligar…')),
    lastChange && when ? el('span', { class: 'muted' }, ` · ${nameOf(lastChange.author)} mudou ${when}`) : null,
  ].filter(Boolean));
}
setInterval(() => { if (lastChange) paintLive(); }, 10_000);

function renderPresence(state) {
  const here = Object.entries(state).map(([id, metas]) => ({ id, name: metas[0]?.name ?? nameOf(id) }));
  $('presence').replaceChildren(...here.map((p) => el('span', { class: 'here', title: p.id === me ? 'Tu' : p.name },
    avatar(p.name), el('span', {}, p.id === me ? 'Tu' : p.name))),
  ...(here.length > 1 ? [] : [el('span', { class: 'muted small' }, 'Só tu nesta página')]));
}

function renderMembers() {
  $('members').replaceChildren(...members.map((m) => el('div', { class: 'person' },
    avatar(m.name), el('span', {}, m.id === me ? `${m.name} (tu)` : m.name),
    m.role === 'owner' ? el('span', { class: 'small' }, 'dono') : null)));
  $('leave').textContent = myRole === 'owner' ? 'Apagar o plano para todos' : 'Sair do plano';
}

/* ------------------------------------------------------------ ações */

function wire() {
  const title = $('title');
  title.dataset.key = 'trip:trip:name';
  title.addEventListener('input', () => { if (title.value.trim()) queue('trip:trip:name', title.value.trim()); });
  title.addEventListener('blur', () => void flush());

  $('add-day').addEventListener('click', () => void write(addDay(model).changes));

  $('invite').addEventListener('click', async () => {
    const button = $('invite');
    button.disabled = true;
    const { data: code, error } = await sb.rpc('plan_invite', { p_plan: planId });
    button.disabled = false;
    if (error) { notice($('invite-box'), explain(error), 'error'); return; }
    const url = new URL(`convite.html?c=${code}`, location.href).href;
    const input = el('input', { value: url, readonly: true, 'aria-label': 'Link do convite' });
    $('invite-box').replaceChildren(
      el('p', { class: 'muted small' }, 'Envia este link. Vale 14 dias e é para membros da Comunidade.'),
      el('div', { class: 'row' }, input,
        el('button', { class: 'btn', type: 'button', onclick: async () => {
          try { await navigator.clipboard.writeText(url); notice($('invite-box'), 'Link copiado.'); } catch { input.select(); }
        } }, 'Copiar'),
        navigator.share ? el('button', { class: 'btn', type: 'button', onclick: () => void navigator.share({ title: 'Plano partilhado', url }).catch(() => {}) }, 'Partilhar') : null),
    );
  });

  $('open-app').href = `${appScheme()}://shared-plans`;

  $('leave').addEventListener('click', async () => {
    const owner = myRole === 'owner';
    const name = model.trip.name ?? 'este plano';
    if (!confirm(owner
      ? `Apagar “${name}” para todos? Quem tem o plano na app fica com a sua cópia, mas deixa de poder editá-lo em conjunto.`
      : `Sair de “${name}”? Deixas de o ver aqui.`)) return;
    await flush();
    const { error } = await sb.rpc('leave_plan', { p_plan: planId });
    if (error) { notice(status, explain(error), 'error'); return; }
    location.href = 'conta.html#planos';
  });
}

// Uma tecla para tudo: Ctrl/Cmd+S guarda já o que estiver por guardar.
addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); void flush(); }
});

// No fim: o módulo corre de cima para baixo, e o arranque usa tudo o que está acima.
if (session) await start();
