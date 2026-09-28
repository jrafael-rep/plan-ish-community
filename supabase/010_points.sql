-- Comunidade Plan-ish — esquema 10: pontos.
--
-- Correr depois dos esquemas 1 a 9. Pode correr mais do que uma vez.
--
-- Os pontos são só da Comunidade: ganham-se e gastam-se no site e no
-- servidor. A app não mostra nem pede pontos.
--
-- Ganhar (regras em private.points_rules, que se mudam sem mexer no código):
--   trip_done         alguém fez um itinerário teu e o GPS confirmou-o
--                     (itinerary_completions com evidence = 'original'). Uma
--                     vez por conta e por itinerário; nunca o teu próprio.
--   review_from_doer  quem fez o teu itinerário (com GPS) avaliou-o. Conta a
--                     avaliação, não as estrelas: uma avaliação má vale o
--                     mesmo. Uma vez por conta e por itinerário.
--   comment           comentaste num itinerário de outra pessoa. No máximo
--                     10 pontos por dia.
--   likes             cada 10 gostos num itinerário teu. Só contam os gostos
--                     de contas que já tinham 7 dias quando gostaram. No
--                     máximo 20 pontos por dia.
--   invite            alguém que convidaste fez uma viagem com GPS
--                     confirmado ou tornou-se membro. Uma vez por convidado.
--
-- Gastar:
--   redeem_month      500 pontos: mais 1 mês de membro.
--   gift_code         500 pontos: um código PLAN-XXXX-XXXX que dá 1 mês de
--                     membro a quem o usar (vale 90 dias).
--
-- Cada movimento fica em private.points_ledger; o saldo é a soma. Nenhum
-- movimento se repete: (reason, ref_id) é único. Quando a moderação esconde
-- um itinerário, um comentário ou uma avaliação, entra um movimento negativo
-- ("revoked") com a referência do que foi ganho com ele; voltar a mostrar
-- tira esse movimento. Um comentário apagado perde o seu ponto.
--
-- Os pontos não valem dinheiro, não se compram nem se vendem (ver termos).

-- ------------------------------------------------------------------ regras

create table if not exists private.points_rules (
  reason text primary key,
  -- 'earn': pontos que se ganham; 'cost': pontos que custa.
  kind text not null default 'earn' check (kind in ('earn', 'cost')),
  points int not null check (points >= 0),
  -- Máximo de pontos por dia (hora de Lisboa) por esta razão; null: sem máximo.
  daily_cap int check (daily_cap is null or daily_cap >= 0),
  -- Quantos acontecimentos dão os pontos uma vez (10 gostos = 1 ponto).
  every int not null default 1 check (every >= 1),
  -- Só contam acontecimentos de contas com pelo menos esta idade.
  giver_min_age interval,
  note text
);
alter table private.points_rules enable row level security;

-- Os valores de partida. Voltar a correr o script não desfaz o que se mudou à mão:
--   update private.points_rules set points = 60 where reason = 'trip_done';
insert into private.points_rules (reason, kind, points, daily_cap, every, giver_min_age, note) values
  ('trip_done',        'earn',  50, null,  1, null,              'Alguém fez o teu itinerário, com GPS'),
  ('review_from_doer', 'earn',  10, null,  1, null,              'Quem fez o teu itinerário avaliou-o'),
  ('comment',          'earn',   1,   10,  1, null,              'Comentário num itinerário de outra pessoa'),
  ('likes',            'earn',   1,   20, 10, interval '7 days', 'Cada 10 gostos num itinerário teu'),
  ('invite',           'earn', 100, null,  1, null,              'Quem convidaste fez uma viagem com GPS ou tornou-se membro'),
  ('redeem_month',     'cost', 500, null,  1, null,              '1 mês de membro'),
  ('gift_code',        'cost', 500, null,  1, null,              'Código de oferta de 1 mês')
on conflict (reason) do nothing;

-- ------------------------------------------------------------------ movimentos

create table if not exists private.points_ledger (
  id bigserial primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  delta int not null check (delta <> 0),
  reason text not null check (char_length(reason) between 1 and 40),
  ref_id text not null check (char_length(ref_id) between 1 and 200),
  created_at timestamptz not null default now(),
  unique (reason, ref_id)
);
create index if not exists points_ledger_by_user on private.points_ledger (user_id, reason, created_at desc);
alter table private.points_ledger enable row level security;

create or replace function private.points_balance(uid uuid)
returns int language sql stable security definer set search_path = '' as $$
  select coalesce(sum(l.delta), 0)::int from private.points_ledger l where l.user_id = uid
$$;

-- O início do dia de hoje, na hora de Lisboa.
create or replace function private.day_start()
returns timestamptz language sql stable set search_path = '' as $$
  select date_trunc('day', now() at time zone 'Europe/Lisbon') at time zone 'Europe/Lisbon'
$$;

-- Um movimento de cada vez por conta: o saldo e os máximos por dia não se
-- contornam com pedidos em paralelo.
create or replace function private.points_lock(uid uuid)
returns void language sql volatile set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('points:' || uid::text, 0))
$$;

create or replace function private.points_cost(p_reason text)
returns int language sql stable security definer set search_path = '' as $$
  select r.points from private.points_rules r where r.reason = p_reason and r.kind = 'cost'
$$;

-- Dá os pontos de uma regra, uma vez por referência, dentro do máximo do dia.
-- Devolve se deu. Contas bloqueadas ou já apagadas não ganham.
create or replace function private.award_points(uid uuid, p_reason text, p_ref text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  r private.points_rules;
  today int;
  n int;
begin
  if uid is null or p_ref is null then return false; end if;
  if not exists (select 1 from auth.users u where u.id = uid) or private.is_blocked(uid) then return false; end if;
  select * into r from private.points_rules where reason = p_reason and kind = 'earn';
  if r.reason is null or r.points <= 0 then return false; end if;
  if exists (select 1 from private.points_ledger l where l.reason = p_reason and l.ref_id = p_ref) then
    return false;
  end if;
  perform private.points_lock(uid);
  if r.daily_cap is not null then
    select coalesce(sum(l.delta), 0) into today from private.points_ledger l
     where l.user_id = uid and l.reason = p_reason and l.created_at >= private.day_start();
    if today + r.points > r.daily_cap then return false; end if;
  end if;
  insert into private.points_ledger (user_id, delta, reason, ref_id)
  values (uid, r.points, p_reason, p_ref)
  on conflict (reason, ref_id) do nothing;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- Tira (p_revoked = true) ou devolve os pontos ganhos com estas razões e
-- referências (um padrão LIKE). Tirar é um movimento negativo "revoked" com a
-- referência "<razão>|<referência>"; devolver apaga esse movimento.
create or replace function private.set_revoked(p_reasons text[], p_ref_like text, p_revoked boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_revoked then
    insert into private.points_ledger (user_id, delta, reason, ref_id)
    select l.user_id, -l.delta, 'revoked', l.reason || '|' || l.ref_id
      from private.points_ledger l
     where l.reason = any (p_reasons) and l.ref_id like p_ref_like and l.delta > 0
       -- Durante o apagar de uma conta não há a quem tirar.
       and exists (select 1 from auth.users u where u.id = l.user_id)
    on conflict (reason, ref_id) do nothing;
  else
    delete from private.points_ledger v
     where v.reason = 'revoked'
       and exists (select 1 from private.points_ledger l
                    where l.reason = any (p_reasons) and l.ref_id like p_ref_like
                      and v.ref_id = l.reason || '|' || l.ref_id);
  end if;
end $$;

-- ------------------------------------------------------------------ convites

-- Cada conta tem um código de convite, para o link "?ref=CÓDIGO".
create table if not exists private.ref_codes (
  user_id uuid primary key references auth.users (id) on delete cascade,
  code text not null unique check (code ~ '^[A-HJKMNP-Z2-9]{8}$'),
  created_at timestamptz not null default now()
);
alter table private.ref_codes enable row level security;

-- Quem convidou quem. Uma vez por conta convidada.
create table if not exists private.referrals (
  invitee_id uuid primary key references auth.users (id) on delete cascade,
  inviter_id uuid not null references auth.users (id) on delete cascade,
  claimed_at timestamptz not null default now(),
  check (invitee_id <> inviter_id)
);
create index if not exists referrals_by_inviter on private.referrals (inviter_id);
alter table private.referrals enable row level security;

-- Letras e algarismos que não se confundem (sem I, L, O, 0 nem 1).
create or replace function private.random_code(n int)
returns text language sql volatile set search_path = '' as $$
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + get_byte(b, i) % 31, 1), '' order by i)
    from (select extensions.gen_random_bytes(n) as b) x, generate_series(0, n - 1) i
$$;

-- Se esta conta foi convidada e já fez uma viagem com GPS confirmado (feita
-- a partir de um itinerário ou publicada por ela) ou é membro, quem a
-- convidou ganha os pontos do convite, uma vez.
create or replace function private.check_invite(uid uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare inviter uuid;
begin
  select r.inviter_id into inviter from private.referrals r where r.invitee_id = uid;
  if inviter is null then return; end if;
  if exists (select 1 from public.itinerary_completions c where c.user_id = uid and c.evidence = 'original')
     or exists (select 1 from public.itineraries i where i.author_id = uid and i.evidence = 'original' and not i.hidden)
     or private.is_member(uid) then
    perform private.award_points(inviter, 'invite', uid::text);
  end if;
end $$;

-- ------------------------------------------------------ ganhar: gatilhos

-- Viagem feita com GPS: pontos para o autor do itinerário e, se for caso
-- disso, para quem convidou quem a fez.
create or replace function private.points_on_completion()
returns trigger language plpgsql security definer set search_path = '' as $$
declare author uuid;
begin
  if new.evidence <> 'original' then return null; end if;
  select i.author_id into author from public.itineraries i where i.id = new.itinerary_id and not i.hidden;
  if author is not null and author <> new.user_id then
    perform private.award_points(author, 'trip_done', new.itinerary_id::text || ':' || new.user_id::text);
  end if;
  perform private.check_invite(new.user_id);
  return null;
end $$;
drop trigger if exists points_on_completion on public.itinerary_completions;
create trigger points_on_completion after insert or update of evidence on public.itinerary_completions
  for each row execute function private.points_on_completion();

-- Avaliação de quem fez: pontos para o autor do itinerário.
create or replace function private.points_on_review()
returns trigger language plpgsql security definer set search_path = '' as $$
declare author uuid;
begin
  if not new.verified or new.hidden then return null; end if;
  select i.author_id into author from public.itineraries i where i.id = new.itinerary_id and not i.hidden;
  if author is not null and author <> new.author_id then
    perform private.award_points(author, 'review_from_doer', new.itinerary_id::text || ':' || new.author_id::text);
  end if;
  return null;
end $$;
drop trigger if exists points_on_review on public.reviews;
create trigger points_on_review after insert or update of verified, hidden on public.reviews
  for each row execute function private.points_on_review();

-- Comentário: um ponto para quem comenta, num itinerário que não é seu.
create or replace function private.points_on_comment()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    -- Apagado por si (não com o itinerário, que já cá não estaria): perde o ponto.
    if exists (select 1 from public.itineraries i where i.id = old.itinerary_id) then
      perform private.set_revoked(array['comment'], old.id::text, true);
    end if;
    return null;
  end if;
  if new.hidden then return null; end if;
  if exists (select 1 from public.itineraries i
              where i.id = new.itinerary_id and not i.hidden and i.author_id <> new.author_id) then
    perform private.award_points(new.author_id, 'comment', new.id::text);
  end if;
  return null;
end $$;
drop trigger if exists points_on_comment on public.comments;
create trigger points_on_comment after insert or delete on public.comments
  for each row execute function private.points_on_comment();

-- Gostos: cada 10 gostos (de contas com 7 dias) num itinerário dão 1 ponto
-- ao autor. A referência é "<itinerário>:<n.º do bloco de 10>": tirar e voltar
-- a dar o mesmo gosto nunca paga duas vezes. Blocos que ficaram de fora pelo
-- máximo do dia entram no gosto seguinte, noutro dia.
create or replace function private.points_on_like()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  it public.itineraries;
  r private.points_rules;
  n int;
  m int;
begin
  select * into it from public.itineraries i where i.id = new.itinerary_id;
  if it.id is null or it.hidden or it.author_id = new.user_id then return null; end if;
  select * into r from private.points_rules where reason = 'likes' and kind = 'earn';
  if r.reason is null then return null; end if;
  select count(*) into n
    from public.likes l join public.profiles p on p.id = l.user_id
   where l.itinerary_id = it.id and l.user_id <> it.author_id
     and (r.giver_min_age is null or l.created_at - p.created_at >= r.giver_min_age);
  for m in
    select g from generate_series(1, n / r.every) g
     where not exists (select 1 from private.points_ledger x
                        where x.reason = 'likes' and x.ref_id = it.id::text || ':' || g)
     order by g
  loop
    exit when not private.award_points(it.author_id, 'likes', it.id::text || ':' || m);
  end loop;
  return null;
end $$;
drop trigger if exists points_on_like on public.likes;
create trigger points_on_like after insert on public.likes
  for each row execute function private.points_on_like();

-- Convites: publicar uma viagem com GPS confirmado, ou tornar-se membro.
create or replace function private.points_invite_on_publish()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.evidence = 'original' then perform private.check_invite(new.author_id); end if;
  return null;
end $$;
drop trigger if exists points_invite_on_publish on public.itineraries;
create trigger points_invite_on_publish after insert or update of evidence on public.itineraries
  for each row execute function private.points_invite_on_publish();

create or replace function private.points_invite_on_membership()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_invite(new.user_id);
  return null;
end $$;
drop trigger if exists points_invite_on_membership on public.memberships;
create trigger points_invite_on_membership after insert or update of valid_until on public.memberships
  for each row execute function private.points_invite_on_membership();

-- Moderação: esconder tira os pontos ganhos com aquilo; voltar a mostrar devolve-os.
create or replace function private.points_on_hidden()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.hidden is not distinct from old.hidden then return null; end if;
  if tg_table_name = 'itineraries' then
    perform private.set_revoked(array['trip_done', 'review_from_doer', 'likes'], new.id::text || ':%', new.hidden);
  elsif tg_table_name = 'comments' then
    perform private.set_revoked(array['comment'], new.id::text, new.hidden);
  elsif tg_table_name = 'reviews' then
    perform private.set_revoked(array['review_from_doer'], new.itinerary_id::text || ':' || new.author_id::text, new.hidden);
  end if;
  return null;
end $$;
drop trigger if exists points_on_hidden on public.itineraries;
create trigger points_on_hidden after update of hidden on public.itineraries
  for each row execute function private.points_on_hidden();
drop trigger if exists points_on_hidden on public.comments;
create trigger points_on_hidden after update of hidden on public.comments
  for each row execute function private.points_on_hidden();
drop trigger if exists points_on_hidden on public.reviews;
create trigger points_on_hidden after update of hidden on public.reviews
  for each row execute function private.points_on_hidden();

-- ------------------------------------------------------------------ gastar

-- Mais 1 mês de membro, a contar do fim do que já tem (ou de agora, se já
-- acabou ou nunca teve). Quem é membro sem fim não passa por aqui.
create or replace function private.extend_membership(uid uuid, p_note text)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  m public.memberships;
  new_until timestamptz;
begin
  select * into m from public.memberships where user_id = uid for update;
  if m.user_id is null then
    insert into public.memberships (user_id, valid_until, note)
    values (uid, now() + interval '1 month', p_note)
    returning valid_until into new_until;
  elsif m.valid_until is null then
    raise exception 'no_end' using errcode = '22023', hint = 'Já és membro sem data de fim.';
  else
    update public.memberships
       set valid_until = greatest(now(), m.valid_until) + interval '1 month', updated_at = now()
     where user_id = uid
    returning valid_until into new_until;
  end if;
  return new_until;
end $$;

create or replace function private.require_points_user()
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  if private.is_blocked(auth.uid()) then
    raise exception 'account_blocked' using errcode = '42501',
      hint = 'Esta conta foi bloqueada na Comunidade por não cumprir os termos de utilização.';
  end if;
  return auth.uid();
end $$;

create or replace function private.has_no_end(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.memberships m where m.user_id = uid and m.valid_until is null)
$$;

create or replace function private.spend_points(uid uuid, p_reason text, p_ref text)
returns void language plpgsql security definer set search_path = '' as $$
declare cost int := private.points_cost(p_reason);
begin
  if cost is null then raise exception 'rule_missing' using errcode = '22023'; end if;
  if private.points_balance(uid) < cost then
    raise exception 'points_insufficient' using errcode = '22023',
      hint = 'Ainda não tens pontos suficientes.';
  end if;
  if cost > 0 then
    insert into private.points_ledger (user_id, delta, reason, ref_id) values (uid, -cost, p_reason, p_ref);
  end if;
end $$;

-- Site: trocar pontos por 1 mês de membro. outcome: 'extended', ou 'no_end'
-- (já é membro sem data de fim: nada muda e nada se gasta).
create or replace function public.redeem_points_for_month()
returns table (outcome text, member_until timestamptz, points_left int)
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_points_user();
  new_until timestamptz;
begin
  perform private.points_lock(uid);
  if private.has_no_end(uid) then
    return query select 'no_end'::text, null::timestamptz, private.points_balance(uid);
    return;
  end if;
  perform private.spend_points(uid, 'redeem_month', gen_random_uuid()::text);
  new_until := private.extend_membership(uid, 'pontos');
  return query select 'extended'::text, new_until, private.points_balance(uid);
end $$;

-- ------------------------------------------------------------ códigos de oferta

create table if not exists private.gift_codes (
  code text primary key check (code ~ '^PLAN-[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$'),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '90 days',
  redeemed_by uuid references auth.users (id) on delete set null,
  redeemed_at timestamptz
);
create index if not exists gift_codes_by_creator on private.gift_codes (created_by, created_at desc);
alter table private.gift_codes enable row level security;

-- Site: gastar pontos num código de oferta. Devolve o código.
create or replace function public.create_gift_code()
returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_points_user();
  c text;
begin
  perform private.points_lock(uid);
  loop
    c := private.random_code(8);
    c := 'PLAN-' || substr(c, 1, 4) || '-' || substr(c, 5, 4);
    exit when not exists (select 1 from private.gift_codes g where g.code = c);
  end loop;
  perform private.spend_points(uid, 'gift_code', c);
  insert into private.gift_codes (code, created_by) values (c, uid);
  return c;
end $$;

-- "plan xxxx xxxx", "PLANXXXXXXXX"… → "PLAN-XXXX-XXXX"; null se não tem a forma.
create or replace function private.gift_code_norm(p_code text)
returns text language sql immutable set search_path = '' as $$
  select case when c ~ '^PLAN[A-Z0-9]{8}$' then 'PLAN-' || substr(c, 5, 4) || '-' || substr(c, 9, 4) end
    from (select regexp_replace(upper(coalesce(p_code, '')), '[^A-Z0-9]', '', 'g') as c) x
$$;

-- Site: usar um código de oferta. Marca-o como usado e dá 1 mês de membro,
-- numa só operação: dois pedidos ao mesmo tempo não usam o mesmo código.
create or replace function public.redeem_gift_code(p_code text)
returns table (outcome text, member_until timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_points_user();
  c text := private.gift_code_norm(p_code);
  used text;
  new_until timestamptz;
begin
  if c is null then
    raise exception 'gift_invalid' using errcode = '22023',
      hint = 'Este código não existe, já foi usado ou expirou.';
  end if;
  perform private.points_lock(uid);
  -- Quem é membro sem fim não gasta o código: fica para outra pessoa.
  if private.has_no_end(uid) then
    return query select 'no_end'::text, null::timestamptz;
    return;
  end if;
  update private.gift_codes g set redeemed_by = uid, redeemed_at = now()
   where g.code = c and g.redeemed_by is null and g.redeemed_at is null and g.expires_at > now()
  returning g.code into used;
  if used is null then
    raise exception 'gift_invalid' using errcode = '22023',
      hint = 'Este código não existe, já foi usado ou expirou.';
  end if;
  new_until := private.extend_membership(uid, 'código de oferta');
  return query select 'extended'::text, new_until;
end $$;

-- Site: os códigos que criei, para os voltar a copiar.
create or replace function public.my_gift_codes()
returns table (code text, created_at timestamptz, expires_at timestamptz, redeemed boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return query select g.code, g.created_at, g.expires_at, g.redeemed_at is not null
    from private.gift_codes g where g.created_by = auth.uid()
   order by g.created_at desc limit 50;
end $$;

-- ------------------------------------------------------------ convites (site)

create or replace function public.my_ref_code()
returns text language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  select r.code into c from private.ref_codes r where r.user_id = auth.uid();
  while c is null loop
    insert into private.ref_codes (user_id, code) values (auth.uid(), private.random_code(8))
    on conflict do nothing;
    select r.code into c from private.ref_codes r where r.user_id = auth.uid();
  end loop;
  return c;
end $$;

-- Quem chegou por um link de convite diz quem o convidou, uma vez, nos
-- primeiros 7 dias da conta, e nunca a si próprio.
create or replace function public.claim_ref(p_code text)
returns void language plpgsql security definer set search_path = '' as $$
declare inviter uuid;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  select r.user_id into inviter from private.ref_codes r where r.code = upper(btrim(coalesce(p_code, '')));
  if inviter is null then
    raise exception 'ref_invalid' using errcode = '22023', hint = 'Este convite não existe.';
  end if;
  if inviter = auth.uid() then
    raise exception 'ref_self' using errcode = '22023', hint = 'Este convite é teu.';
  end if;
  if exists (select 1 from private.referrals f where f.invitee_id = auth.uid()) then
    raise exception 'ref_already' using errcode = '22023', hint = 'Já disseste quem te convidou.';
  end if;
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.created_at > now() - interval '7 days') then
    raise exception 'ref_too_late' using errcode = '22023', hint = 'Os convites valem para contas novas.';
  end if;
  insert into private.referrals (invitee_id, inviter_id) values (auth.uid(), inviter)
  on conflict do nothing;
  perform private.check_invite(auth.uid());
end $$;

-- ------------------------------------------------------------ saldo (site)

-- O saldo, os custos em vigor e os 20 últimos movimentos. Sem referências:
-- não se vê quem fez, gostou ou comentou. Num movimento "revoked", "about"
-- diz o que foi tirado.
create or replace function public.my_points()
returns table (balance int, month_cost int, gift_cost int, movements jsonb)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return query select
    private.points_balance(uid),
    private.points_cost('redeem_month'),
    private.points_cost('gift_code'),
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'delta', x.delta, 'reason', x.reason, 'created_at', x.created_at,
               'about', case when x.reason = 'revoked' then split_part(x.ref_id, '|', 1) end)
             order by x.created_at desc, x.id desc)
        from (select l.id, l.delta, l.reason, l.ref_id, l.created_at from private.points_ledger l
               where l.user_id = uid order by l.created_at desc, l.id desc limit 20) x
    ), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------ permissões

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;
grant execute on function private.plan_role(uuid, uuid) to authenticated;

revoke execute on function
  public.redeem_points_for_month(), public.create_gift_code(), public.redeem_gift_code(text),
  public.my_gift_codes(), public.my_ref_code(), public.claim_ref(text), public.my_points()
  from public, anon, authenticated;
-- Só o site, com sessão. A app não tem nada de pontos.
grant execute on function
  public.redeem_points_for_month(), public.create_gift_code(), public.redeem_gift_code(text),
  public.my_gift_codes(), public.my_ref_code(), public.claim_ref(text), public.my_points()
  to authenticated;
