// Planos partilhados: o plano como campos, lido da mesma forma que a app o lê
// (ver src/domain/sharedPlan.ts no repositório da app).
//
// Uma chave é "entidade:id:campo" — "stop:s1:name", "day:d2:title". Apagar é
// escrever "…:deleted" = true. A ordem dos dias é a data (e depois o número
// de ordem); a das paragens, o número de ordem e depois o id — exatamente como
// a app, para os dois lados mostrarem o plano pela mesma ordem.
//
// Sem dependências, para se poder testar com `node --test`.

export const FIELD_KEY = /^(trip|day|stop|item|idea):[A-Za-z0-9_.:-]{1,120}:[A-Za-z0-9_]{1,60}$/;

export function parseKey(key) {
  if (!FIELD_KEY.test(key)) return null;
  const first = key.indexOf(':');
  const last = key.lastIndexOf(':');
  return { entity: key.slice(0, first), slot: key.slice(first + 1, last), field: key.slice(last + 1) };
}

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : Number.MAX_SAFE_INTEGER);
const byOrder = (a, b) => num(a.order) - num(b.order) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const byDate = (a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : byOrder(a, b));

/**
 * O plano que um mapa de campos descreve: `{ trip, days: [{ …, stops }],
 * ideas, checklist }`. Cada entidade leva o seu `slot` (o lugar na chave).
 */
export function buildModel(fields) {
  const groups = { trip: new Map(), day: new Map(), stop: new Map(), item: new Map(), idea: new Map() };
  for (const [key, value] of fields) {
    if (value === null || value === undefined) continue;
    const k = parseKey(key);
    if (!k) continue;
    const record = groups[k.entity].get(k.slot) ?? {};
    record[k.field] = value;
    groups[k.entity].set(k.slot, record);
  }
  const alive = (bucket) => [...bucket.entries()]
    .filter(([, r]) => r.deleted !== true)
    .map(([slot, r]) => ({ ...r, slot, id: typeof r.id === 'string' ? r.id : slot }));

  const days = alive(groups.day).map((d) => ({ ...d, date: d.date ?? '', title: d.title ?? '', stops: [] })).sort(byDate);
  const bySlotOrId = new Map(days.map((d) => [d.id, d]));
  for (const stop of alive(groups.stop).sort(byOrder)) {
    bySlotOrId.get(stop.dayId)?.stops.push(stop);
  }
  const items = alive(groups.item);
  return {
    trip: groups.trip.get('trip') ?? {},
    days,
    ideas: alive(groups.idea).sort((a, b) => String(a.name ?? '').localeCompare(String(b.name ?? ''), 'pt')),
    checklist: items.filter((i) => i.slot.startsWith('ck.')).sort((a, b) => String(a.label ?? '').localeCompare(String(b.label ?? ''), 'pt')),
    // As pessoas do plano, para "Para quem" (ramos: paragens só de algumas).
    people: items.filter((i) => i.slot.startsWith('pp.') && typeof i.name === 'string')
      .sort((a, b) => String(a.name).localeCompare(String(b.name), 'pt')),
    stopCount: days.reduce((n, d) => n + d.stops.length, 0),
  };
}

/* ------------------------------------------------------------ alterações */

export function newId(prefix) {
  const rand = Math.random().toString(36).slice(2, 8);
  return `web-${prefix}-${Date.now().toString(36)}${rand}`;
}

export const setField = (entity, slot, field, value) => [{ key: `${entity}:${slot}:${field}`, value }];

export const remove = (entity, slot) => [{ key: `${entity}:${slot}:deleted`, value: true }];

/** Os números de ordem para as paragens de um dia ficarem por esta sequência. */
export function renumber(stops) {
  return stops.flatMap((s, i) => (s.order === i + 1 ? [] : setField('stop', s.slot, 'order', i + 1)));
}

/** Um número entre dois vizinhos (qualquer um pode faltar), como na app. */
export function between(prev, next) {
  const lo = Number.isFinite(prev?.order) ? prev.order : undefined;
  const hi = Number.isFinite(next?.order) ? next.order : undefined;
  if (lo !== undefined && hi !== undefined) return lo < hi ? (lo + hi) / 2 : null;
  if (lo !== undefined) return lo + 1;
  if (hi !== undefined) return hi - 1;
  return 1;
}

/**
 * Sobe ou desce uma paragem um lugar (`delta` −1 sobe, +1 desce).
 *
 * Só a paragem que se mexe muda de número: fica entre as novas vizinhas. Assim
 * duas pessoas a reordenar ao mesmo tempo não desfazem o que a outra fez.
 */
export function moveWithinDay(day, stopSlot, delta) {
  const list = [...day.stops];
  const i = list.findIndex((s) => s.slot === stopSlot);
  const j = i + delta;
  if (i < 0 || j < 0 || j >= list.length) return [];
  const [stop] = list.splice(i, 1);
  list.splice(j, 0, stop);
  const order = between(list[j - 1], list[j + 1]);
  // Vizinhas com o mesmo número (duas paragens postas ao mesmo tempo): não há
  // espaço entre elas, e aí renumera-se o dia.
  return order === null ? renumber(list) : setField('stop', stop.slot, 'order', order);
}

/** Passa uma paragem para o fim de outro dia. */
export function moveToDay(model, stopSlot, dayId) {
  const target = model.days.find((d) => d.id === dayId);
  if (!target) return [];
  const last = target.stops.reduce((m, s) => Math.max(m, Number.isFinite(s.order) ? s.order : 0), 0);
  return [...setField('stop', stopSlot, 'dayId', dayId), ...setField('stop', stopSlot, 'order', last + 1)];
}

/** Uma paragem nova no fim de um dia, ainda sem localização. */
export function addStop(model, dayId, name, durationMin = 60) {
  const day = model.days.find((d) => d.id === dayId);
  if (!day) return { id: null, changes: [] };
  const id = newId('s');
  const last = day.stops.reduce((m, s) => Math.max(m, Number.isFinite(s.order) ? s.order : 0), 0);
  const changes = [
    { key: `stop:${id}:name`, value: name.trim().slice(0, 200) || 'Paragem' },
    { key: `stop:${id}:nameIsCustom`, value: true },
    { key: `stop:${id}:dayId`, value: dayId },
    { key: `stop:${id}:order`, value: last + 1 },
    { key: `stop:${id}:durationMin`, value: durationMin },
    { key: `stop:${id}:kind`, value: 'other' },
    { key: `stop:${id}:description`, value: '' },
  ];
  return { id, changes };
}

function nextDate(date) {
  const t = Date.parse(`${date}T12:00:00Z`);
  return Number.isNaN(t) ? '' : new Date(t + 86_400_000).toISOString().slice(0, 10);
}

/** Um dia novo a seguir ao último, e a viagem estica até ele — como na app. */
export function addDay(model) {
  const last = model.days[model.days.length - 1];
  const date = last ? nextDate(last.date) : (model.trip.startDate ?? '');
  const order = model.days.length + 1;
  const id = newId('d');
  const changes = [
    { key: `day:${id}:date`, value: date },
    { key: `day:${id}:title`, value: `Dia ${order}` },
    { key: `day:${id}:summary`, value: '' },
    { key: `day:${id}:order`, value: order },
  ];
  if (date && (!model.trip.endDate || date > model.trip.endDate)) changes.push({ key: 'trip:trip:endDate', value: date });
  return { id, changes };
}

/**
 * Marcar ou tirar a hora de uma paragem, com as mesmas regras da app: uma
 * hora marcada é um compromisso (a paragem fica presa a ela); sem hora, a
 * paragem começa quando se chega, e o compromisso vai com a hora.
 */
export function setStart(stop, clock) {
  const k = (f, v) => ({ key: `stop:${stop.slot}:${f}`, value: v });
  if (clock) {
    return [k('scheduledTime', withClock(stop.scheduledTime, clock)), k('startMode', 'explicit'), k('isAnchor', true), k('anchorKind', 'appointment')];
  }
  const out = [k('scheduledTime', null), k('startMode', 'automatic')];
  if (stop.anchorKind === 'appointment') out.push(k('isAnchor', null), k('anchorKind', null));
  return out;
}

/* --------------------------------------------------------------- mostrar */

/** 90 → "1h 30"; 45 → "45 min". */
export function durationText(min) {
  const m = Math.max(0, Math.round(Number(min) || 0));
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  const r = m % 60;
  return r ? `${h}h ${String(r).padStart(2, '0')}` : `${h}h`;
}

/** A hora marcada de uma paragem, como "HH:MM", venha como "21:00" ou "2026-09-04T21:00". */
export function clockOf(scheduled) {
  const m = /(?:^|T)(\d{2}):(\d{2})/.exec(String(scheduled ?? ''));
  return m ? `${m[1]}:${m[2]}` : '';
}

/** Muda a hora e mantém o dia, quando a marcação tinha dia. */
export function withClock(scheduled, clock) {
  if (!clock) return null;
  const m = /^(\d{4}-\d{2}-\d{2})T/.exec(String(scheduled ?? ''));
  return m ? `${m[1]}T${clock}` : clock;
}

const WEEKDAYS = ['domingo', 'segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado'];
const MONTHS = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
/** "2026-09-04" → "sexta, 4 set". */
export function dayLabel(date) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date ?? '');
  if (!m) return '';
  const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
  return `${WEEKDAYS[d.getUTCDay()]}, ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
}

/**
 * Para quem é uma paragem: uma lista de pessoas, ou todas (a lista sai).
 * Escolher toda a gente é o mesmo que "todas", como na app.
 */
export function setStopPeople(model, stop, ids) {
  const known = new Set(model.people.map((p) => p.id));
  const chosen = [...new Set(ids)].filter((id) => known.has(id));
  const everyone = chosen.length === 0 || chosen.length === known.size;
  return setField('stop', stop.slot, 'forParticipantIds', everyone ? null : chosen);
}

/** "Só Ana e Rui", ou nada numa paragem de todos. */
export function peopleLabel(model, stop) {
  const ids = Array.isArray(stop.forParticipantIds) ? stop.forParticipantIds : [];
  const names = ids.map((id) => model.people.find((p) => p.id === id)?.name).filter(Boolean);
  if (!names.length) return null;
  return `Só ${names.length === 1 ? names[0] : `${names.slice(0, -1).join(', ')} e ${names[names.length - 1]}`}`;
}
