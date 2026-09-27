// node --test test/plan-model.test.mjs
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  addDay, addStop, buildModel, clockOf, dayLabel, durationText, moveToDay, moveWithinDay, parseKey,
  remove, setStart, withClock,
} from '../assets/plan-model.js';

// Um plano inventado, escrito como a app o escreve.
function sample() {
  return new Map(Object.entries({
    'trip:trip:name': 'Fim de semana na serra',
    'trip:trip:startDate': '2027-05-01',
    'trip:trip:endDate': '2027-05-02',
    'day:d1:date': '2027-05-01', 'day:d1:title': 'Chegada', 'day:d1:order': 1,
    'day:d2:date': '2027-05-02', 'day:d2:title': 'Regresso', 'day:d2:order': 2,
    'stop:a:name': 'Café', 'stop:a:dayId': 'd1', 'stop:a:order': 1, 'stop:a:durationMin': 30,
    'stop:b:name': 'Miradouro', 'stop:b:dayId': 'd1', 'stop:b:order': 2, 'stop:b:durationMin': 45,
    'stop:c:name': 'Almoço', 'stop:c:dayId': 'd2', 'stop:c:order': 1, 'stop:c:durationMin': 90,
    'stop:h.1k2j3.40:id': 'id com espaços', 'stop:h.1k2j3.40:name': 'Estranha', 'stop:h.1k2j3.40:dayId': 'd2', 'stop:h.1k2j3.40:order': 2,
    'idea:i1:name': 'Cascata',
    'item:ck.t1:label': 'Toalha',
    'item:lg.abc.1.1:fromStopId': 'a',
  }));
}

test('lê as chaves como a app as escreve', () => {
  assert.deepEqual(parseKey('stop:s1:name'), { entity: 'stop', slot: 's1', field: 'name' });
  assert.deepEqual(parseKey('item:lg.x.1.2:mode'), { entity: 'item', slot: 'lg.x.1.2', field: 'mode' });
  assert.equal(parseKey('drop table'), null);
});

test('monta dias e paragens pela ordem da app', () => {
  const m = buildModel(sample());
  assert.equal(m.trip.name, 'Fim de semana na serra');
  assert.deepEqual(m.days.map((d) => d.title), ['Chegada', 'Regresso']);
  assert.deepEqual(m.days[0].stops.map((s) => s.name), ['Café', 'Miradouro']);
  assert.deepEqual(m.days[1].stops.map((s) => s.id), ['c', 'id com espaços']);
  assert.equal(m.stopCount, 4);
  assert.deepEqual(m.ideas.map((i) => i.name), ['Cascata']);
  assert.deepEqual(m.checklist.map((i) => i.label), ['Toalha']);
});

test('os dias vão pela data, mesmo com números de ordem trocados', () => {
  const f = sample();
  f.set('day:d1:order', 9);
  assert.deepEqual(buildModel(f).days.map((d) => d.id), ['d1', 'd2']);
});

test('duas paragens com o mesmo número de ordem ficam pelo id, como na app', () => {
  const f = sample();
  f.set('stop:b:order', 1);
  assert.deepEqual(buildModel(f).days[0].stops.map((s) => s.id), ['a', 'b']);
});

test('apagado não aparece; um dia apagado leva as paragens', () => {
  const f = sample();
  for (const c of remove('stop', 'a')) f.set(c.key, c.value);
  assert.deepEqual(buildModel(f).days[0].stops.map((s) => s.id), ['b']);
  for (const c of remove('day', 'd2')) f.set(c.key, c.value);
  const m = buildModel(f);
  assert.equal(m.days.length, 1);
  assert.equal(m.stopCount, 1);
});

test('subir e descer muda só o número da paragem que se mexe', () => {
  const f = sample();
  f.set('stop:x:name', 'Loja'); f.set('stop:x:dayId', 'd1'); f.set('stop:x:order', 3);
  const m = buildModel(f);
  // a(1) b(2) x(3): subir o x põe-no entre a e b.
  assert.deepEqual(moveWithinDay(m.days[0], 'x', -1), [{ key: 'stop:x:order', value: 1.5 }]);
  // subir o b para o topo: antes do a.
  assert.deepEqual(moveWithinDay(m.days[0], 'b', -1), [{ key: 'stop:b:order', value: 0 }]);
  // descer o b para o fundo: depois do x.
  assert.deepEqual(moveWithinDay(m.days[0], 'b', 1), [{ key: 'stop:b:order', value: 4 }]);
  assert.deepEqual(moveWithinDay(m.days[0], 'a', -1), []);
});

test('duas pessoas sobem paragens diferentes ao mesmo tempo: as duas mudanças ficam', () => {
  const f = sample();
  f.set('stop:x:name', 'Loja'); f.set('stop:x:dayId', 'd1'); f.set('stop:x:order', 3);
  const m = buildModel(f);
  const ana = moveWithinDay(m.days[0], 'x', -1); // x antes de b
  const rui = moveWithinDay(m.days[0], 'b', -1); // b antes de a
  for (const c of [...ana, ...rui]) f.set(c.key, c.value);
  assert.deepEqual(buildModel(f).days[0].stops.map((s) => s.id), ['b', 'a', 'x']);
});

test('sem espaço entre vizinhas com o mesmo número, renumera o dia', () => {
  const f = sample();
  f.set('stop:x:name', 'Loja'); f.set('stop:x:dayId', 'd1'); f.set('stop:x:order', 2);
  const m = buildModel(f); // a(1) b(2) x(2)
  const out = moveWithinDay(m.days[0], 'a', 1); // a entre b e x, ambos 2
  const g = sample(); g.set('stop:x:name', 'Loja'); g.set('stop:x:dayId', 'd1'); g.set('stop:x:order', 2);
  for (const c of out) g.set(c.key, c.value);
  assert.deepEqual(buildModel(g).days[0].stops.map((s) => s.id), ['b', 'a', 'x']);
});

test('mudar de dia vai para o fim do outro dia', () => {
  const m = buildModel(sample());
  assert.deepEqual(moveToDay(m, 'a', 'd2'), [{ key: 'stop:a:dayId', value: 'd2' }, { key: 'stop:a:order', value: 3 }]);
});

test('uma paragem nova tem chaves válidas e vai para o fim do dia', () => {
  const m = buildModel(sample());
  const { id, changes } = addStop(m, 'd1', '  Padaria  ');
  assert.match(id, /^web-s-[a-z0-9]+$/);
  for (const c of changes) assert.ok(parseKey(c.key), c.key);
  const f = sample();
  for (const c of changes) f.set(c.key, c.value);
  assert.deepEqual(buildModel(f).days[0].stops.map((s) => s.name), ['Café', 'Miradouro', 'Padaria']);
});

test('um dia novo é o dia a seguir ao último, e a viagem estica', () => {
  const { changes } = addDay(buildModel(sample()));
  const byKey = Object.fromEntries(changes.map((c) => [c.key.split(':').pop(), c.value]));
  assert.equal(byKey.date, '2027-05-03');
  assert.equal(byKey.title, 'Dia 3');
  assert.deepEqual(changes.find((c) => c.key === 'trip:trip:endDate'), { key: 'trip:trip:endDate', value: '2027-05-03' });
});

test('marcar uma hora prende a paragem; tirá-la solta, como na app', () => {
  const stop = { slot: 'a', scheduledTime: undefined };
  assert.deepEqual(setStart(stop, '21:00'), [
    { key: 'stop:a:scheduledTime', value: '21:00' }, { key: 'stop:a:startMode', value: 'explicit' },
    { key: 'stop:a:isAnchor', value: true }, { key: 'stop:a:anchorKind', value: 'appointment' },
  ]);
  assert.deepEqual(setStart({ slot: 'a', scheduledTime: '21:00', anchorKind: 'appointment' }, ''), [
    { key: 'stop:a:scheduledTime', value: null }, { key: 'stop:a:startMode', value: 'automatic' },
    { key: 'stop:a:isAnchor', value: null }, { key: 'stop:a:anchorKind', value: null },
  ]);
  // Um prazo ("estar em casa até") não é uma hora marcada: fica.
  assert.equal(setStart({ slot: 'a', anchorKind: 'deadline' }, '').length, 2);
});

test('uma marcação com dia mantém o dia quando se muda a hora', () => {
  assert.equal(withClock('2027-05-01T18:00', '19:30'), '2027-05-01T19:30');
  assert.equal(withClock('18:00', '19:30'), '19:30');
  assert.equal(clockOf('2027-05-01T18:00'), '18:00');
  assert.equal(clockOf('21:05'), '21:05');
  assert.equal(clockOf(undefined), '');
});

test('textos', () => {
  assert.equal(durationText(45), '45 min');
  assert.equal(durationText(90), '1h 30');
  assert.equal(durationText(120), '2h');
  assert.equal(dayLabel('2027-05-01'), 'sábado, 1 mai');
});
