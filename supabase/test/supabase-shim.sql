-- O mínimo do Supabase para testar o esquema num Postgres local.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
create schema extensions; create extension pgcrypto with schema extensions;
grant usage on schema extensions to anon, authenticated;
create schema auth; grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant execute on function auth.uid() to anon, authenticated;
grant usage on schema public to anon, authenticated;
-- O Storage: só as duas tabelas que as regras usam.
create schema storage; grant usage on schema storage to anon, authenticated;
create table storage.buckets (id text primary key, name text not null, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id),
  name text not null, unique (bucket_id, name));
alter table storage.objects enable row level security;
grant insert (bucket_id, name) on storage.objects to anon, authenticated;
-- O Realtime: só a função que manda avisos, a registar o que mandaria.
create schema realtime;
create table realtime.sent (id bigserial primary key, payload jsonb, event text, topic text, private boolean);
create function realtime.send(payload jsonb, event text, topic text, private boolean default true)
returns void language sql as $$ insert into realtime.sent (payload, event, topic, private) values (payload, event, topic, private) $$;
