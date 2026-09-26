-- Comunidade Plan-ish — esquema 1 (prova de conceito)
--
-- Colar inteiro no SQL Editor do Supabase e carregar em Run. Pode correr mais
-- do que uma vez: o que já existe fica como está.
--
-- Princípios:
--   * Qualquer pessoa, sem conta, lê o que está publicado (feed, itinerários,
--     comentários). Nada mais é público.
--   * Escrever exige uma conta. A app nunca inicia sessão: fica "ligada" a uma
--     conta por um pedido confirmado no site, e fala com o servidor só através
--     das funções app_* abaixo, com a chave dessa ligação.
--   * Quem é membro só o servidor escreve (tabela memberships).
--   * Sem localização de pessoas: só se guardam os itinerários que alguém
--     escolheu publicar.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------- definições

create table if not exists public.community_settings (
  id boolean primary key default true check (id),
  -- Durante a prova de conceito, qualquer conta pode interagir. Quando a
  -- Comunidade for paga: update public.community_settings set members_only = true;
  members_only boolean not null default false
);
insert into public.community_settings default values on conflict do nothing;
alter table public.community_settings enable row level security;
drop policy if exists "settings: toda a gente lê" on public.community_settings;
create policy "settings: toda a gente lê" on public.community_settings
  for select to anon, authenticated using (true);
grant select on public.community_settings to anon, authenticated;

-- ------------------------------------------------------------------ perfis

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profiles: toda a gente lê" on public.profiles;
create policy "profiles: toda a gente lê" on public.profiles
  for select to anon, authenticated using (true);
drop policy if exists "profiles: cada um muda o seu" on public.profiles;
create policy "profiles: cada um muda o seu" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
grant select on public.profiles to anon, authenticated;
grant update (display_name) on public.profiles to authenticated;

-- Um perfil por conta, com um nome neutro. O email nunca aparece em público.
create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, 'Viajante ' || upper(substr(replace(new.id::text, '-', ''), 1, 4)))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- Contas criadas antes deste script.
insert into public.profiles (id, display_name)
select id, 'Viajante ' || upper(substr(replace(id::text, '-', ''), 1, 4)) from auth.users
on conflict (id) do nothing;

-- ------------------------------------------------------------------ membros

create table if not exists public.memberships (
  user_id uuid primary key references auth.users (id) on delete cascade,
  tier text not null default 'member',
  valid_until timestamptz,          -- null: sem fim
  note text,
  updated_at timestamptz not null default now()
);
alter table public.memberships enable row level security;
drop policy if exists "memberships: cada um vê a sua" on public.memberships;
create policy "memberships: cada um vê a sua" on public.memberships
  for select to authenticated using (user_id = (select auth.uid()));
-- Só leitura. Quem escreve é o servidor (ou o dono, à mão, no SQL Editor).
grant select on public.memberships to authenticated;

create or replace function private.is_member(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
    where m.user_id = uid and (m.valid_until is null or m.valid_until > now())
  )
$$;

create or replace function private.can_interact(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select uid is not null and (
    not coalesce((select members_only from public.community_settings), false)
    or private.is_member(uid)
  )
$$;
grant usage on schema private to authenticated;
grant execute on function private.can_interact(uuid) to authenticated;
revoke execute on function private.is_member(uuid) from public;

-- -------------------------------------------------------------- itinerários

create table if not exists public.itineraries (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles (id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  destination text check (char_length(destination) <= 120),
  summary text check (char_length(summary) <= 2000),
  day_count int not null check (day_count between 1 and 60),
  stop_count int not null check (stop_count between 1 and 500),
  travelled_month text check (travelled_month ~ '^\d{4}-\d{2}$'),
  -- O plano no formato de importação do Plan-ish, já sem dados pessoais.
  plan jsonb not null check (octet_length(plan::text) <= 512000),
  -- O id da viagem na app, para voltar a publicar atualizar em vez de duplicar.
  source_trip_id text check (char_length(source_trip_id) <= 200),
  hidden boolean not null default false,   -- moderação
  like_count int not null default 0,
  comment_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (author_id, source_trip_id)
);
create index if not exists itineraries_feed on public.itineraries (created_at desc) where not hidden;
alter table public.itineraries enable row level security;
drop policy if exists "itineraries: toda a gente lê os visíveis" on public.itineraries;
create policy "itineraries: toda a gente lê os visíveis" on public.itineraries
  for select to anon, authenticated
  using (not hidden or author_id = (select auth.uid()));
drop policy if exists "itineraries: o autor publica" on public.itineraries;
create policy "itineraries: o autor publica" on public.itineraries
  for insert to authenticated
  with check (author_id = (select auth.uid()) and private.can_interact((select auth.uid())));
drop policy if exists "itineraries: o autor muda" on public.itineraries;
create policy "itineraries: o autor muda" on public.itineraries
  for update to authenticated
  using (author_id = (select auth.uid())) with check (author_id = (select auth.uid()));
drop policy if exists "itineraries: o autor apaga" on public.itineraries;
create policy "itineraries: o autor apaga" on public.itineraries
  for delete to authenticated using (author_id = (select auth.uid()));
grant select on public.itineraries to anon, authenticated;
grant insert (title, destination, summary, day_count, stop_count, travelled_month, plan, source_trip_id, author_id)
  on public.itineraries to authenticated;
grant update (title, destination, summary, day_count, stop_count, travelled_month, plan, updated_at)
  on public.itineraries to authenticated;
grant delete on public.itineraries to authenticated;

-- -------------------------------------------------------------------- likes

create table if not exists public.likes (
  itinerary_id uuid not null references public.itineraries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (itinerary_id, user_id)
);
alter table public.likes enable row level security;
drop policy if exists "likes: cada um vê os seus" on public.likes;
create policy "likes: cada um vê os seus" on public.likes
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "likes: cada um dá os seus" on public.likes;
create policy "likes: cada um dá os seus" on public.likes
  for insert to authenticated
  with check (user_id = (select auth.uid()) and private.can_interact((select auth.uid())));
drop policy if exists "likes: cada um tira os seus" on public.likes;
create policy "likes: cada um tira os seus" on public.likes
  for delete to authenticated using (user_id = (select auth.uid()));
grant select, insert (itinerary_id, user_id), delete on public.likes to authenticated;

create or replace function private.count_likes()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.itineraries i
     set like_count = (select count(*) from public.likes l where l.itinerary_id = i.id)
   where i.id = coalesce(new.itinerary_id, old.itinerary_id);
  return null;
end $$;
drop trigger if exists likes_count on public.likes;
create trigger likes_count after insert or delete on public.likes
  for each row execute function private.count_likes();

-- --------------------------------------------------------------- comentários

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  itinerary_id uuid not null references public.itineraries (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  hidden boolean not null default false,   -- moderação
  created_at timestamptz not null default now()
);
create index if not exists comments_by_itinerary on public.comments (itinerary_id, created_at);
alter table public.comments enable row level security;
drop policy if exists "comments: toda a gente lê os visíveis" on public.comments;
create policy "comments: toda a gente lê os visíveis" on public.comments
  for select to anon, authenticated
  using (
    (not hidden and exists (select 1 from public.itineraries i where i.id = itinerary_id and not i.hidden))
    or author_id = (select auth.uid())
  );
drop policy if exists "comments: quem tem conta comenta" on public.comments;
create policy "comments: quem tem conta comenta" on public.comments
  for insert to authenticated
  with check (author_id = (select auth.uid()) and private.can_interact((select auth.uid())));
-- Apaga o autor do comentário, ou o autor do itinerário (modera o que é seu).
drop policy if exists "comments: autor ou dono do itinerário apaga" on public.comments;
create policy "comments: autor ou dono do itinerário apaga" on public.comments
  for delete to authenticated
  using (
    author_id = (select auth.uid())
    or exists (select 1 from public.itineraries i where i.id = itinerary_id and i.author_id = (select auth.uid()))
  );
grant select on public.comments to anon, authenticated;
grant insert (itinerary_id, author_id, body) on public.comments to authenticated;
grant delete on public.comments to authenticated;

create or replace function private.count_comments()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.itineraries i
     set comment_count = (select count(*) from public.comments c where c.itinerary_id = i.id and not c.hidden)
   where i.id = coalesce(new.itinerary_id, old.itinerary_id);
  return null;
end $$;
drop trigger if exists comments_count on public.comments;
create trigger comments_count after insert or delete or update of hidden on public.comments
  for each row execute function private.count_comments();

-- ---------------------------------------------------------------- denúncias

-- Qualquer pessoa pode denunciar, com ou sem conta (a Play exige-o na app).
-- Ninguém as lê pela API: vêem-se no painel do Supabase.
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  itinerary_id uuid references public.itineraries (id) on delete cascade,
  comment_id uuid references public.comments (id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 500),
  reporter_id uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (itinerary_id is not null or comment_id is not null)
);
alter table public.reports enable row level security;
drop policy if exists "reports: qualquer pessoa denuncia" on public.reports;
create policy "reports: qualquer pessoa denuncia" on public.reports
  for insert to anon, authenticated
  with check (reporter_id is null or reporter_id = (select auth.uid()));
grant insert (itinerary_id, comment_id, reason) on public.reports to anon, authenticated;

-- ---------------------------------------------------- ligar a app a uma conta
--
--  1. A app chama app_begin_link(nome do telemóvel) e recebe um pedido e um
--     segredo. O segredo fica no telemóvel; o servidor guarda só o seu hash.
--  2. A app abre o site em ligar.html?pedido=<id>. A pessoa entra na conta no
--     site e confirma (confirm_app_link).
--  3. O site devolve a pessoa à app com o id do pedido. A app troca o pedido
--     e o segredo por uma chave da ligação (app_redeem_link). Quem apanhar só
--     o id do pedido não consegue nada sem o segredo.
--  4. Daí em diante a app usa essa chave nas funções app_*. O servidor guarda
--     só o hash da chave.

create table if not exists private.app_link_requests (
  id uuid primary key default gen_random_uuid(),
  secret_hash bytea not null,
  device_label text not null check (char_length(device_label) between 1 and 60),
  user_id uuid references auth.users (id) on delete cascade,
  confirmed_at timestamptz,
  expires_at timestamptz not null default now() + interval '15 minutes',
  created_at timestamptz not null default now()
);

create table if not exists public.app_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  token_hash bytea not null unique,
  device_label text not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);
alter table public.app_links enable row level security;
drop policy if exists "app_links: cada um vê as suas" on public.app_links;
create policy "app_links: cada um vê as suas" on public.app_links
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "app_links: cada um desliga as suas" on public.app_links;
create policy "app_links: cada um desliga as suas" on public.app_links
  for delete to authenticated using (user_id = (select auth.uid()));
grant select (id, device_label, created_at, last_used_at), delete on public.app_links to authenticated;

create or replace function private.hash(value text)
returns bytea language sql immutable set search_path = '' as $$
  select extensions.digest(convert_to(value, 'UTF8'), 'sha256')
$$;

create or replace function private.random_secret()
returns text language sql volatile set search_path = '' as $$
  select encode(extensions.gen_random_bytes(32), 'hex')
$$;

-- A conta por trás de uma chave da ligação; null se a chave não vale.
create or replace function private.user_for_token(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid;
begin
  if p_token is null or char_length(p_token) <> 64 then return null; end if;
  update public.app_links set last_used_at = now()
   where token_hash = private.hash(p_token)
  returning user_id into uid;
  return uid;
end $$;

create or replace function private.require_user(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.user_for_token(p_token);
begin
  if uid is null then
    raise exception 'link_invalid' using errcode = '28000',
      hint = 'A ligação a esta conta já não é válida. Liga a app outra vez.';
  end if;
  return uid;
end $$;

create or replace function private.require_interaction(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  if not private.can_interact(uid) then
    raise exception 'members_only' using errcode = '42501',
      hint = 'Disponível para membros da Comunidade.';
  end if;
  return uid;
end $$;

-- 1. A app pede uma ligação.
create or replace function public.app_begin_link(p_device_label text)
returns table (request_id uuid, secret text)
language plpgsql security definer set search_path = '' as $$
declare s text := private.random_secret(); rid uuid;
begin
  delete from private.app_link_requests where expires_at < now() - interval '1 day';
  insert into private.app_link_requests (secret_hash, device_label)
  values (private.hash(s), left(coalesce(nullif(btrim(p_device_label), ''), 'Telemóvel'), 60))
  returning id into rid;
  return query select rid, s;
end $$;

-- 2a. O site mostra de que telemóvel é o pedido, antes de confirmar.
create or replace function public.get_app_link_request(p_request_id uuid)
returns table (device_label text, expires_at timestamptz, confirmed boolean)
language sql stable security definer set search_path = '' as $$
  select r.device_label, r.expires_at, r.user_id is not null
    from private.app_link_requests r
   where r.id = p_request_id and r.expires_at > now()
$$;

-- 2b. A pessoa, com sessão iniciada no site, confirma.
create or replace function public.confirm_app_link(p_request_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare label text;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  update private.app_link_requests
     set user_id = auth.uid(), confirmed_at = now()
   where id = p_request_id and user_id is null and expires_at > now()
  returning device_label into label;
  if label is null then
    raise exception 'request_invalid' using errcode = '22023',
      hint = 'Este pedido já foi usado ou expirou. Volta a carregar em "Ligar" na app.';
  end if;
  return label;
end $$;

-- 3. A app troca o pedido confirmado e o seu segredo pela chave da ligação.
create or replace function public.app_redeem_link(p_request_id uuid, p_secret text)
returns table (token text, display_name text, member boolean, can_interact boolean)
language plpgsql security definer set search_path = '' as $$
declare r private.app_link_requests; t text := private.random_secret();
begin
  select * into r from private.app_link_requests
   where id = p_request_id and expires_at > now() for update;
  if r.id is null or r.secret_hash <> private.hash(p_secret) then
    raise exception 'request_invalid' using errcode = '22023';
  end if;
  if r.user_id is null then
    raise exception 'not_confirmed' using errcode = '22023',
      hint = 'Ainda não confirmaste no site.';
  end if;
  delete from private.app_link_requests where id = r.id;
  insert into public.app_links (user_id, token_hash, device_label)
  values (r.user_id, private.hash(t), r.device_label);
  return query
    select t, p.display_name, private.is_member(r.user_id), private.can_interact(r.user_id)
      from public.profiles p where p.id = r.user_id;
end $$;

-- 4. O que a app faz com a ligação.
create or replace function public.app_whoami(p_token text)
returns table (display_name text, member boolean, can_interact boolean)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select p.display_name, private.is_member(uid), private.can_interact(uid)
    from public.profiles p where p.id = uid;
end $$;

create or replace function public.app_unlink(p_token text)
returns void language sql security definer set search_path = '' as $$
  delete from public.app_links where token_hash = private.hash(p_token)
$$;

create or replace function public.app_publish(
  p_token text, p_title text, p_destination text, p_summary text,
  p_day_count int, p_stop_count int, p_travelled_month text,
  p_plan jsonb, p_source_trip_id text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token); iid uuid;
begin
  insert into public.itineraries
    (author_id, title, destination, summary, day_count, stop_count, travelled_month, plan, source_trip_id)
  values
    (uid, p_title, nullif(btrim(p_destination), ''), nullif(btrim(p_summary), ''),
     p_day_count, p_stop_count, p_travelled_month, p_plan, p_source_trip_id)
  on conflict (author_id, source_trip_id) do update set
    title = excluded.title, destination = excluded.destination, summary = excluded.summary,
    day_count = excluded.day_count, stop_count = excluded.stop_count,
    travelled_month = excluded.travelled_month, plan = excluded.plan, updated_at = now()
  returning id into iid;
  return iid;
end $$;

create or replace function public.app_unpublish(p_token text, p_itinerary_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  delete from public.itineraries where id = p_itinerary_id and author_id = uid;
end $$;

-- O que esta conta publicou a partir desta app, para saber se já está publicado.
create or replace function public.app_my_itineraries(p_token text)
returns table (id uuid, source_trip_id text, title text, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select i.id, i.source_trip_id, i.title, i.updated_at
    from public.itineraries i where i.author_id = uid order by i.updated_at desc;
end $$;

create or replace function public.app_set_like(p_token text, p_itinerary_id uuid, p_liked boolean)
returns int language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token); n int;
begin
  if p_liked then
    insert into public.likes (itinerary_id, user_id) values (p_itinerary_id, uid)
    on conflict do nothing;
  else
    delete from public.likes where itinerary_id = p_itinerary_id and user_id = uid;
  end if;
  select like_count into n from public.itineraries where id = p_itinerary_id;
  return coalesce(n, 0);
end $$;

create or replace function public.app_liked(p_token text, p_itinerary_ids uuid[])
returns setof uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select l.itinerary_id from public.likes l
    where l.user_id = uid and l.itinerary_id = any (p_itinerary_ids);
end $$;

create or replace function public.app_comment(p_token text, p_itinerary_id uuid, p_body text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token); cid uuid;
begin
  insert into public.comments (itinerary_id, author_id, body)
  values (p_itinerary_id, uid, btrim(p_body)) returning id into cid;
  return cid;
end $$;

-- ------------------------------------------------------------ apagar conta

-- No site. Apaga a conta e, em cascata, tudo o que publicou.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ------------------------------------------------------------- permissões

-- Funções novas no Supabase ficam executáveis por toda a gente; aqui só por
-- quem precisa delas.
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;

revoke execute on function
  public.app_begin_link(text), public.get_app_link_request(uuid), public.confirm_app_link(uuid),
  public.app_redeem_link(uuid, text), public.app_whoami(text), public.app_unlink(text),
  public.app_publish(text, text, text, text, int, int, text, jsonb, text),
  public.app_unpublish(text, uuid), public.app_my_itineraries(text),
  public.app_set_like(text, uuid, boolean), public.app_liked(text, uuid[]),
  public.app_comment(text, uuid, text), public.delete_my_account()
  from public, anon, authenticated;

-- A app não tem sessão: fala como anon, com a chave da ligação.
grant execute on function
  public.app_begin_link(text), public.app_redeem_link(uuid, text), public.app_whoami(text),
  public.app_unlink(text), public.app_publish(text, text, text, text, int, int, text, jsonb, text),
  public.app_unpublish(text, uuid), public.app_my_itineraries(text),
  public.app_set_like(text, uuid, boolean), public.app_liked(text, uuid[]),
  public.app_comment(text, uuid, text)
  to anon, authenticated;

-- O site, com sessão iniciada.
grant execute on function
  public.get_app_link_request(uuid), public.confirm_app_link(uuid), public.delete_my_account()
  to authenticated;
