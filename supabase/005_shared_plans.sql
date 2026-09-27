-- Comunidade Plan-ish — esquema 5: planos partilhados, editados em conjunto.
--
-- Correr depois dos esquemas 1 a 4. Pode correr mais do que uma vez.
--
-- Um plano partilhado é um conjunto de campos: "trip:trip:name",
-- "stop:<id>:durationMin", "day:<id>:title"… Cada escrita muda só os campos
-- que mudaram, e o servidor dá-lhes um número de revisão por ordem de chegada.
-- Duas pessoas a mudar campos diferentes nunca se estragam; no mesmo campo,
-- fica a última escrita. Apagar é escrever "deleted"; mover é mudar "dayId" e
-- "position".
--
-- O site vê as alterações ao vivo (Supabase Realtime sobre a tabela de
-- campos); a app pergunta "o que mudou desde a revisão N" enquanto o plano
-- está aberto.
--
-- Só membros da Comunidade criam, aceitam convites e editam. O plano completo
-- vai para aqui (incluindo casa e ponto de partida, por decisão do dono); o
-- percurso GPS nunca.

-- ------------------------------------------------------------ tabelas

create table if not exists public.shared_plans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.shared_plan_members (
  plan_id uuid not null references public.shared_plans (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'editor' check (role in ('owner', 'editor')),
  added_at timestamptz not null default now(),
  primary key (plan_id, user_id)
);
create index if not exists shared_plan_members_by_user on public.shared_plan_members (user_id);

create sequence if not exists public.shared_plan_rev_seq;

create table if not exists public.shared_plan_fields (
  plan_id uuid not null references public.shared_plans (id) on delete cascade,
  key text not null check (char_length(key) between 3 and 200),
  value jsonb,
  rev bigint not null,
  author_id uuid references public.profiles (id) on delete set null,
  client_id text check (char_length(client_id) <= 64),
  updated_at timestamptz not null default now(),
  primary key (plan_id, key)
);
create index if not exists shared_plan_fields_by_rev on public.shared_plan_fields (plan_id, rev);

create table if not exists private.shared_plan_invites (
  code text primary key,
  plan_id uuid not null references public.shared_plans (id) on delete cascade,
  created_by uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days'
);

-- ------------------------------------------------------------ acesso

create or replace function private.plan_role(p_plan uuid, p_user uuid)
returns text language sql stable security definer set search_path = '' as $$
  select role from public.shared_plan_members where plan_id = p_plan and user_id = p_user
$$;

alter table public.shared_plans enable row level security;
alter table public.shared_plan_members enable row level security;
alter table public.shared_plan_fields enable row level security;

drop policy if exists "shared_plans: quem é do plano vê" on public.shared_plans;
create policy "shared_plans: quem é do plano vê" on public.shared_plans
  for select to authenticated using (private.plan_role(id, (select auth.uid())) is not null);
drop policy if exists "shared_plan_members: quem é do plano vê" on public.shared_plan_members;
create policy "shared_plan_members: quem é do plano vê" on public.shared_plan_members
  for select to authenticated using (private.plan_role(plan_id, (select auth.uid())) is not null);
drop policy if exists "shared_plan_fields: quem é do plano vê" on public.shared_plan_fields;
create policy "shared_plan_fields: quem é do plano vê" on public.shared_plan_fields
  for select to authenticated using (private.plan_role(plan_id, (select auth.uid())) is not null);

-- Ler, sim, com sessão; escrever, só pelas funções abaixo.
revoke all on public.shared_plans, public.shared_plan_members, public.shared_plan_fields from anon, authenticated;
grant select on public.shared_plans, public.shared_plan_members, public.shared_plan_fields to authenticated;
grant execute on function private.plan_role(uuid, uuid) to authenticated;

-- ------------------------------------------------------------ escrever

create or replace function private.require_plan_member(p_uid uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_member(p_uid) then
    raise exception 'members_only' using errcode = '42501',
      hint = 'Os planos partilhados são para membros da Comunidade.';
  end if;
end $$;

/*
  Escreve campos de um plano. `p_fields` é uma lista de {"key": …, "value": …};
  value null quer dizer "o campo deixou de existir". Devolve a revisão mais
  alta escrita (ou a atual, se não havia nada para escrever).
*/
create or replace function private.write_fields(p_uid uuid, p_plan uuid, p_client text, p_fields jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  f jsonb;
  r bigint := 0;
begin
  perform private.require_plan_member(p_uid);
  if private.plan_role(p_plan, p_uid) is null then
    raise exception 'not_in_plan' using errcode = '42501', hint = 'Este plano não está partilhado contigo.';
  end if;
  if jsonb_typeof(p_fields) <> 'array' or jsonb_array_length(p_fields) > 2000 then
    raise exception 'fields_invalid' using errcode = '22023', hint = 'Alterações a mais de uma vez.';
  end if;
  for f in select * from jsonb_array_elements(p_fields) loop
    if jsonb_typeof(f->'key') <> 'string' or char_length(f->>'key') not between 3 and 200
       or (f->>'key') !~ '^(trip|day|stop|item|idea):[A-Za-z0-9_.:-]{1,120}:[A-Za-z0-9_]{1,60}$'
       or pg_column_size(f->'value') > 65536 then
      raise exception 'fields_invalid' using errcode = '22023', hint = 'Um dos campos não é válido.';
    end if;
    r := nextval('public.shared_plan_rev_seq');
    insert into public.shared_plan_fields as sf (plan_id, key, value, rev, author_id, client_id, updated_at)
    values (p_plan, f->>'key', f->'value', r, p_uid, left(p_client, 64), now())
    on conflict (plan_id, key) do update set
      value = excluded.value, rev = excluded.rev, author_id = excluded.author_id,
      client_id = excluded.client_id, updated_at = excluded.updated_at;
    -- O nome da viagem é também o nome do plano nas listas.
    if f->>'key' = 'trip:trip:name' and jsonb_typeof(f->'value') = 'string' and char_length(btrim(f->>'value')) > 0 then
      update public.shared_plans set title = left(btrim(f->>'value'), 120) where id = p_plan;
    end if;
  end loop;
  update public.shared_plans set updated_at = now() where id = p_plan;
  if r = 0 then
    select coalesce(max(rev), 0) into r from public.shared_plan_fields where plan_id = p_plan;
  end if;
  return r;
end $$;

-- ------------------------------------------------------------ a app (chave de ligação)

create or replace function public.app_share_plan(p_token text, p_title text, p_client text, p_fields jsonb)
returns table (plan_id uuid, rev bigint) language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token); pid uuid; r bigint;
begin
  perform private.require_plan_member(uid);
  insert into public.shared_plans (owner_id, title) values (uid, left(btrim(p_title), 120)) returning id into pid;
  insert into public.shared_plan_members (plan_id, user_id, role) values (pid, uid, 'owner');
  r := private.write_fields(uid, pid, p_client, p_fields);
  return query select pid, r;
end $$;

create or replace function public.app_write_plan_fields(p_token text, p_plan uuid, p_client text, p_fields jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return private.write_fields(uid, p_plan, p_client, p_fields);
end $$;

create or replace function public.app_plan_fields_since(p_token text, p_plan uuid, p_since bigint)
returns table (key text, value jsonb, rev bigint, client_id text)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  if private.plan_role(p_plan, uid) is null then
    raise exception 'not_in_plan' using errcode = '42501', hint = 'Este plano não está partilhado contigo.';
  end if;
  return query select f.key, f.value, f.rev, f.client_id from public.shared_plan_fields f
    where f.plan_id = p_plan and f.rev > coalesce(p_since, 0) order by f.rev;
end $$;

create or replace function public.app_my_shared_plans(p_token text)
returns table (plan_id uuid, title text, role text, owner_name text, member_count int, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select p.id, p.title, m.role, o.display_name,
      (select count(*)::int from public.shared_plan_members x where x.plan_id = p.id), p.updated_at
    from public.shared_plan_members m
    join public.shared_plans p on p.id = m.plan_id
    join public.profiles o on o.id = p.owner_id
    where m.user_id = uid order by p.updated_at desc;
end $$;

create or replace function private.new_invite(p_uid uuid, p_plan uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  perform private.require_plan_member(p_uid);
  if private.plan_role(p_plan, p_uid) is null then
    raise exception 'not_in_plan' using errcode = '42501', hint = 'Este plano não está partilhado contigo.';
  end if;
  -- 12 caracteres sem ambíguos (0/O, 1/l): fáceis de ditar, impossíveis de adivinhar.
  c := array_to_string(array(
    select substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + (get_byte(extensions.gen_random_bytes(1), 0) % 31), 1)
    from generate_series(1, 12)), '');
  insert into private.shared_plan_invites (code, plan_id, created_by) values (c, p_plan, p_uid);
  return c;
end $$;

create or replace function public.app_plan_invite(p_token text, p_plan uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return private.new_invite(uid, p_plan);
end $$;

create or replace function private.accept_invite(p_uid uuid, p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare pid uuid;
begin
  perform private.require_plan_member(p_uid);
  select i.plan_id into pid from private.shared_plan_invites i
    where i.code = lower(btrim(p_code)) and i.expires_at > now();
  if pid is null then
    raise exception 'invite_invalid' using errcode = '22023', hint = 'Este convite expirou ou não existe.';
  end if;
  insert into public.shared_plan_members (plan_id, user_id, role) values (pid, p_uid, 'editor')
    on conflict (plan_id, user_id) do nothing;
  return pid;
end $$;

create or replace function public.app_accept_plan_invite(p_token text, p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return private.accept_invite(uid, p_code);
end $$;

/* Quem está no plano: só o nome público e o papel. */
create or replace function public.app_plan_members(p_token text, p_plan uuid)
returns table (display_name text, role text)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  if private.plan_role(p_plan, uid) is null then
    raise exception 'not_in_plan' using errcode = '42501', hint = 'Este plano não está partilhado contigo.';
  end if;
  return query select p.display_name, m.role from public.shared_plan_members m
    join public.profiles p on p.id = m.user_id
    where m.plan_id = p_plan order by m.role desc, m.added_at;
end $$;

create or replace function public.app_leave_plan(p_token text, p_plan uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  if private.plan_role(p_plan, uid) = 'owner' then
    delete from public.shared_plans where id = p_plan;
  else
    delete from public.shared_plan_members where plan_id = p_plan and user_id = uid;
  end if;
end $$;

-- ------------------------------------------------------------ o site (sessão)

create or replace function public.write_plan_fields(p_plan uuid, p_client text, p_fields jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return private.write_fields((select auth.uid()), p_plan, p_client, p_fields);
end $$;

create or replace function public.plan_invite(p_plan uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return private.new_invite((select auth.uid()), p_plan);
end $$;

/* O que um convite diz antes de ser aceite: o nome do plano e de quem convida. */
create or replace function public.plan_invite_info(p_code text)
returns table (plan_id uuid, title text, owner_name text, member_count int, already boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return query select p.id, p.title, o.display_name,
      (select count(*)::int from public.shared_plan_members x where x.plan_id = p.id),
      private.plan_role(p.id, (select auth.uid())) is not null
    from private.shared_plan_invites i
    join public.shared_plans p on p.id = i.plan_id
    join public.profiles o on o.id = p.owner_id
    where i.code = lower(btrim(p_code)) and i.expires_at > now();
end $$;

create or replace function public.accept_plan_invite(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return private.accept_invite((select auth.uid()), p_code);
end $$;

create or replace function public.leave_plan(p_plan uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  if private.plan_role(p_plan, uid) = 'owner' then
    delete from public.shared_plans where id = p_plan;
  else
    delete from public.shared_plan_members where plan_id = p_plan and user_id = uid;
  end if;
end $$;

-- ------------------------------------------------------------ ao vivo

-- O site ouve as alterações da tabela de campos; as regras de leitura acima
-- decidem quem as recebe.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'shared_plan_fields') then
    alter publication supabase_realtime add table public.shared_plan_fields;
  end if;
end $$;

-- ------------------------------------------------------------ permissões

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;
grant execute on function private.plan_role(uuid, uuid) to authenticated;

revoke execute on function
  public.app_share_plan(text, text, text, jsonb),
  public.app_write_plan_fields(text, uuid, text, jsonb),
  public.app_plan_fields_since(text, uuid, bigint),
  public.app_my_shared_plans(text),
  public.app_plan_invite(text, uuid),
  public.app_accept_plan_invite(text, text),
  public.app_plan_members(text, uuid),
  public.app_leave_plan(text, uuid),
  public.write_plan_fields(uuid, text, jsonb),
  public.plan_invite(uuid),
  public.plan_invite_info(text),
  public.accept_plan_invite(text),
  public.leave_plan(uuid)
  from public, anon, authenticated;
grant execute on function
  public.app_share_plan(text, text, text, jsonb),
  public.app_write_plan_fields(text, uuid, text, jsonb),
  public.app_plan_fields_since(text, uuid, bigint),
  public.app_my_shared_plans(text),
  public.app_plan_invite(text, uuid),
  public.app_accept_plan_invite(text, text),
  public.app_plan_members(text, uuid),
  public.app_leave_plan(text, uuid)
  to anon, authenticated;
grant execute on function
  public.write_plan_fields(uuid, text, jsonb),
  public.plan_invite(uuid),
  public.plan_invite_info(text),
  public.accept_plan_invite(text),
  public.leave_plan(uuid)
  to authenticated;
