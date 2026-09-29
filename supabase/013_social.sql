-- Comunidade Plan-ish — esquema 13: guardar e seguir.
--
-- Correr depois dos esquemas 1 a 12. Pode correr mais do que uma vez.
--
-- 1. Guardar (saves): "quero fazer isto". Cada um vê só os seus; o total
--    (save_count) é público, como os gostos. Guardar é privado e não escreve
--    nada a ninguém, por isso uma conta bloqueada pela moderação continua a
--    poder guardar.
-- 2. Seguir (follows): o feed "A seguir" mostra o que publicam as pessoas
--    que sigo. Cada um vê quem segue e quem o segue; os totais
--    (follower_count, following_count) são públicos no perfil. Não se segue
--    a si próprio, e seguir pede uma conta que pode interagir.
-- 3. feed_page ganha os separadores "following" e "saved" (só com sessão).
-- 4. Para a app, pelo token da ligação: app_set_save, app_saved,
--    app_set_follow, app_following.

-- ---------------------------------------------------------------- guardar
create table if not exists public.saves (
  itinerary_id uuid not null references public.itineraries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (itinerary_id, user_id)
);
create index if not exists saves_by_user on public.saves (user_id, created_at desc);
alter table public.saves enable row level security;
drop policy if exists "saves: cada um vê os seus" on public.saves;
create policy "saves: cada um vê os seus" on public.saves
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "saves: cada um guarda" on public.saves;
create policy "saves: cada um guarda" on public.saves
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists "saves: cada um tira" on public.saves;
create policy "saves: cada um tira" on public.saves
  for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.saves from anon, authenticated;
grant select, insert (itinerary_id, user_id), delete on public.saves to authenticated;

alter table public.itineraries add column if not exists save_count int not null default 0;

create or replace function private.count_saves()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.itineraries i
     set save_count = (select count(*) from public.saves s where s.itinerary_id = i.id)
   where i.id = coalesce(new.itinerary_id, old.itinerary_id);
  return null;
end $$;
drop trigger if exists saves_count on public.saves;
create trigger saves_count after insert or delete on public.saves
  for each row execute function private.count_saves();

-- ----------------------------------------------------------------- seguir
create table if not exists public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index if not exists follows_followee on public.follows (followee_id);
alter table public.follows enable row level security;
drop policy if exists "follows: cada um vê os seus" on public.follows;
create policy "follows: cada um vê os seus" on public.follows
  for select to authenticated
  using (follower_id = (select auth.uid()) or followee_id = (select auth.uid()));
drop policy if exists "follows: cada um segue" on public.follows;
create policy "follows: cada um segue" on public.follows
  for insert to authenticated
  with check (follower_id = (select auth.uid()) and private.can_interact((select auth.uid())));
drop policy if exists "follows: cada um deixa de seguir" on public.follows;
create policy "follows: cada um deixa de seguir" on public.follows
  for delete to authenticated using (follower_id = (select auth.uid()));
revoke all on public.follows from anon, authenticated;
grant select, insert (follower_id, followee_id), delete on public.follows to authenticated;

alter table public.profiles add column if not exists follower_count int not null default 0;
alter table public.profiles add column if not exists following_count int not null default 0;

create or replace function private.count_follows()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  a uuid := coalesce(new.follower_id, old.follower_id);
  b uuid := coalesce(new.followee_id, old.followee_id);
begin
  update public.profiles p set following_count = (select count(*) from public.follows f where f.follower_id = p.id) where p.id = a;
  update public.profiles p set follower_count = (select count(*) from public.follows f where f.followee_id = p.id) where p.id = b;
  return null;
end $$;
drop trigger if exists follows_count on public.follows;
create trigger follows_count after insert or delete on public.follows
  for each row execute function private.count_follows();

-- --------------------------------------------------------- feed: separadores
create or replace function public.feed_page(
  p_tab text default 'popular',
  p_level text default null,
  p_search text default null,
  p_offset int default 0,
  p_limit int default 20,
  p_days text default null,
  p_month int default null
) returns setof public.itineraries
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  tab text := coalesce(nullif(btrim(p_tab), ''), 'popular');
  lvl text := nullif(btrim(p_level), '');
  words text := nullif(lower(btrim(left(p_search, 60))), '');
  lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
  off int := least(greatest(coalesce(p_offset, 0), 0), 5000);
  span text := nullif(btrim(p_days), '');
  lo int;
  hi int;
begin
  if tab not in ('popular', 'recent', 'mine', 'following', 'saved') then
    raise exception 'tab_invalid' using errcode = '22023';
  end if;
  if span is not null and span not in ('1', '2-3', '4-7', '8+') then
    raise exception 'days_invalid' using errcode = '22023';
  end if;
  if p_month is not null and p_month not between 1 and 12 then
    raise exception 'month_invalid' using errcode = '22023';
  end if;
  select b.lo, b.hi into lo, hi from private.day_bucket(span) b;
  if tab in ('mine', 'following', 'saved') and uid is null then return; end if;
  return query
    select i.*
      from public.itineraries i
     where not i.hidden
       and (lvl is null or i.evidence = lvl)
       and (words is null
            or strpos(lower(i.title), words) > 0
            or strpos(lower(coalesce(i.destination, '')), words) > 0)
       and (span is null or i.day_count between lo and hi)
       and (p_month is null or i.travelled_month like '____-' || lpad(p_month::text, 2, '0'))
       and (uid is null or not exists (
             select 1 from public.user_blocks b where b.blocker_id = uid and b.blocked_id = i.author_id))
       and (tab <> 'mine' or i.author_id = uid or exists (
             select 1 from public.likes l where l.itinerary_id = i.id and l.user_id = uid))
       and (tab <> 'following' or exists (
             select 1 from public.follows f where f.follower_id = uid and f.followee_id = i.author_id))
       and (tab <> 'saved' or exists (
             select 1 from public.saves s where s.itinerary_id = i.id and s.user_id = uid))
     order by
       case when tab = 'popular' then
         (select count(*) from public.likes l
           where l.itinerary_id = i.id and l.created_at > now() - interval '30 days')
         + (select count(*) from public.itinerary_completions c
             where c.itinerary_id = i.id and c.completed_at > now() - interval '30 days')
       end desc nulls last,
       case when tab = 'popular' then i.like_count end desc nulls last,
       case when tab = 'saved' then (select s.created_at from public.saves s where s.itinerary_id = i.id and s.user_id = uid) end desc nulls last,
       i.created_at desc, i.id desc
     offset off limit lim;
end $$;

-- ------------------------------------------------------------ para a app
create or replace function public.app_set_save(p_token text, p_itinerary_id uuid, p_saved boolean)
returns int language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token); n int;
begin
  if p_saved then
    insert into public.saves (itinerary_id, user_id) values (p_itinerary_id, uid) on conflict do nothing;
  else
    delete from public.saves where itinerary_id = p_itinerary_id and user_id = uid;
  end if;
  select save_count into n from public.itineraries where id = p_itinerary_id;
  return coalesce(n, 0);
end $$;

create or replace function public.app_saved(p_token text, p_itinerary_ids uuid[])
returns setof uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select s.itinerary_id from public.saves s
    where s.user_id = uid and s.itinerary_id = any (p_itinerary_ids);
end $$;

create or replace function public.app_set_follow(p_token text, p_user_id uuid, p_following boolean)
returns int language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token); n int;
begin
  if p_user_id = uid then raise exception 'follow_self' using errcode = '22023'; end if;
  if p_following then
    insert into public.follows (follower_id, followee_id) values (uid, p_user_id) on conflict do nothing;
  else
    delete from public.follows where follower_id = uid and followee_id = p_user_id;
  end if;
  select follower_count into n from public.profiles where id = p_user_id;
  return coalesce(n, 0);
end $$;

create or replace function public.app_following(p_token text)
returns setof uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select f.followee_id from public.follows f where f.follower_id = uid;
end $$;

revoke execute on function
  public.feed_page(text, text, text, int, int, text, int),
  public.app_set_save(text, uuid, boolean), public.app_saved(text, uuid[]),
  public.app_set_follow(text, uuid, boolean), public.app_following(text)
  from public, anon, authenticated;
grant execute on function public.feed_page(text, text, text, int, int, text, int) to anon, authenticated;
grant execute on function
  public.app_set_save(text, uuid, boolean), public.app_saved(text, uuid[]),
  public.app_set_follow(text, uuid, boolean), public.app_following(text)
  to anon, authenticated;
revoke execute on function private.count_saves(), private.count_follows() from public, anon, authenticated;
