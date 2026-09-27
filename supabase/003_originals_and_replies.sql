-- Comunidade Plan-ish — esquema 3: viagens originais, "feita por", respostas
-- a comentários, likes em comentários.
--
-- Correr depois dos esquemas 1 e 2. Pode correr mais do que uma vez.
--
-- Viagens originais: cada itinerário diz quantas paragens foram visitadas,
-- quantas o GPS confirmou e quantos pontos tem o percurso gravado. O servidor
-- decide o nível a partir desses números (não aceita o nível que a app diz):
--   original  pelo menos 2 paragens visitadas, 60% delas confirmadas pelo GPS
--             e pelo menos 20 pontos de GPS
--   done      alguma paragem visitada, marcada à mão
--   plan      nada registado: é um roteiro
-- Depois de publicado, só a app o pode mudar, publicando outra vez.

-- ------------------------------------------------------------ originais

alter table public.itineraries add column if not exists evidence text not null default 'plan';
alter table public.itineraries add column if not exists visited_stops int not null default 0;
alter table public.itineraries add column if not exists gps_stops int not null default 0;
alter table public.itineraries add column if not exists gps_points int not null default 0;
alter table public.itineraries add column if not exists app_version text;
alter table public.itineraries add column if not exists done_count int not null default 0;
alter table public.itineraries add column if not exists original_done_count int not null default 0;
alter table public.itineraries drop constraint if exists itineraries_evidence_check;
alter table public.itineraries add constraint itineraries_evidence_check
  check (evidence in ('original', 'done', 'plan'));

-- Ninguém muda um itinerário publicado pelo site ou pela API: nem o texto,
-- nem o plano, nem a prova, nem os contadores. Só publicar de novo, na app.
drop policy if exists "itineraries: o autor muda" on public.itineraries;
revoke update on public.itineraries from authenticated;
drop policy if exists "itineraries: o autor publica" on public.itineraries;
revoke insert on public.itineraries from authenticated;

create or replace function private.evidence_level(visited int, gps int, points int)
returns text language sql immutable set search_path = '' as $$
  select case
    when visited >= 2 and gps >= 2 and gps >= visited * 0.6 and points >= 20 then 'original'
    when visited >= 1 then 'done'
    else 'plan'
  end
$$;

create or replace function public.app_publish_v2(
  p_token text, p_title text, p_destination text, p_summary text,
  p_day_count int, p_stop_count int, p_travelled_month text,
  p_plan jsonb, p_source_trip_id text,
  p_visited_stops int, p_gps_stops int, p_gps_points int, p_app_version text
) returns table (id uuid, evidence text)
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_interaction(p_token);
  v int := greatest(0, least(coalesce(p_visited_stops, 0), p_stop_count));
  g int := greatest(0, least(coalesce(p_gps_stops, 0), v));
  pts int := greatest(0, coalesce(p_gps_points, 0));
  lvl text := private.evidence_level(v, g, pts);
  iid uuid;
begin
  insert into public.itineraries as i
    (author_id, title, destination, summary, day_count, stop_count, travelled_month, plan,
     source_trip_id, evidence, visited_stops, gps_stops, gps_points, app_version)
  values
    (uid, p_title, nullif(btrim(p_destination), ''), nullif(btrim(p_summary), ''),
     p_day_count, p_stop_count, p_travelled_month, p_plan, p_source_trip_id,
     lvl, v, g, pts, left(p_app_version, 40))
  on conflict (author_id, source_trip_id) do update set
    title = excluded.title, destination = excluded.destination, summary = excluded.summary,
    day_count = excluded.day_count, stop_count = excluded.stop_count,
    travelled_month = excluded.travelled_month, plan = excluded.plan,
    evidence = excluded.evidence, visited_stops = excluded.visited_stops,
    gps_stops = excluded.gps_stops, gps_points = excluded.gps_points,
    app_version = excluded.app_version, updated_at = now()
  returning i.id into iid;
  return query select iid, lvl;
end $$;

-- ------------------------------------------------------------ feita por

-- Quem copiou um itinerário e o fez de verdade diz-o, a partir da app.
create table if not exists public.itinerary_completions (
  itinerary_id uuid not null references public.itineraries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  evidence text not null check (evidence in ('original', 'done')),
  visited_stops int not null,
  gps_stops int not null,
  completed_at timestamptz not null default now(),
  primary key (itinerary_id, user_id)
);
alter table public.itinerary_completions enable row level security;
drop policy if exists "completions: toda a gente lê" on public.itinerary_completions;
create policy "completions: toda a gente lê" on public.itinerary_completions
  for select to anon, authenticated using (true);
grant select on public.itinerary_completions to anon, authenticated;

create or replace function private.count_completions()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.itineraries i set
    done_count = (select count(*) from public.itinerary_completions c where c.itinerary_id = i.id),
    original_done_count = (select count(*) from public.itinerary_completions c
                            where c.itinerary_id = i.id and c.evidence = 'original')
   where i.id = coalesce(new.itinerary_id, old.itinerary_id);
  return null;
end $$;
drop trigger if exists completions_count on public.itinerary_completions;
create trigger completions_count after insert or update or delete on public.itinerary_completions
  for each row execute function private.count_completions();

create or replace function public.app_record_completion(
  p_token text, p_itinerary_id uuid, p_visited_stops int, p_gps_stops int, p_gps_points int
) returns text language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_interaction(p_token);
  v int := greatest(0, coalesce(p_visited_stops, 0));
  g int := greatest(0, least(coalesce(p_gps_stops, 0), v));
  lvl text := private.evidence_level(v, g, greatest(0, coalesce(p_gps_points, 0)));
begin
  if lvl = 'plan' then
    raise exception 'nothing_done' using errcode = '22023',
      hint = 'Nenhuma paragem ficou registada como visitada nesta viagem.';
  end if;
  if exists (select 1 from public.itineraries where id = p_itinerary_id and author_id = uid) then
    raise exception 'own_itinerary' using errcode = '22023',
      hint = 'Este itinerário é teu: já conta como feito por ti.';
  end if;
  insert into public.itinerary_completions (itinerary_id, user_id, evidence, visited_stops, gps_stops)
  values (p_itinerary_id, uid, lvl, v, g)
  on conflict (itinerary_id, user_id) do update set
    -- Uma segunda vez só sobe de nível, nunca desce.
    evidence = case when itinerary_completions.evidence = 'original' then 'original' else excluded.evidence end,
    visited_stops = greatest(itinerary_completions.visited_stops, excluded.visited_stops),
    gps_stops = greatest(itinerary_completions.gps_stops, excluded.gps_stops),
    completed_at = now();
  return lvl;
end $$;

-- ------------------------------------------------ respostas a comentários

alter table public.comments add column if not exists parent_id uuid references public.comments (id) on delete cascade;
alter table public.comments add column if not exists like_count int not null default 0;
create index if not exists comments_by_parent on public.comments (parent_id) where parent_id is not null;

-- Um nível só: responde-se a um comentário, não a uma resposta, e no mesmo itinerário.
create or replace function private.check_reply()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.comments;
begin
  if new.parent_id is null then return new; end if;
  select * into p from public.comments where id = new.parent_id;
  if p.id is null or p.itinerary_id <> new.itinerary_id then
    raise exception 'reply_invalid' using errcode = '22023';
  end if;
  if p.parent_id is not null then new.parent_id := p.parent_id; end if;
  return new;
end $$;
drop trigger if exists comments_reply_check on public.comments;
create trigger comments_reply_check before insert on public.comments
  for each row execute function private.check_reply();

grant insert (itinerary_id, author_id, body, parent_id) on public.comments to authenticated;

create or replace function public.app_comment_v2(p_token text, p_itinerary_id uuid, p_body text, p_parent_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token); cid uuid;
begin
  insert into public.comments (itinerary_id, author_id, body, parent_id)
  values (p_itinerary_id, uid, btrim(p_body), p_parent_id) returning id into cid;
  return cid;
end $$;

-- ------------------------------------------------ likes em comentários

create table if not exists public.comment_likes (
  comment_id uuid not null references public.comments (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
alter table public.comment_likes enable row level security;
drop policy if exists "comment_likes: cada um vê os seus" on public.comment_likes;
create policy "comment_likes: cada um vê os seus" on public.comment_likes
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "comment_likes: cada um dá os seus" on public.comment_likes;
create policy "comment_likes: cada um dá os seus" on public.comment_likes
  for insert to authenticated
  with check (user_id = (select auth.uid()) and private.can_interact((select auth.uid())));
drop policy if exists "comment_likes: cada um tira os seus" on public.comment_likes;
create policy "comment_likes: cada um tira os seus" on public.comment_likes
  for delete to authenticated using (user_id = (select auth.uid()));
grant select, insert (comment_id, user_id), delete on public.comment_likes to authenticated;

create or replace function private.count_comment_likes()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.comments c
     set like_count = (select count(*) from public.comment_likes l where l.comment_id = c.id)
   where c.id = coalesce(new.comment_id, old.comment_id);
  return null;
end $$;
drop trigger if exists comment_likes_count on public.comment_likes;
create trigger comment_likes_count after insert or delete on public.comment_likes
  for each row execute function private.count_comment_likes();

create or replace function public.app_set_comment_like(p_token text, p_comment_id uuid, p_liked boolean)
returns int language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token); n int;
begin
  if p_liked then
    insert into public.comment_likes (comment_id, user_id) values (p_comment_id, uid) on conflict do nothing;
  else
    delete from public.comment_likes where comment_id = p_comment_id and user_id = uid;
  end if;
  select like_count into n from public.comments where id = p_comment_id;
  return coalesce(n, 0);
end $$;

create or replace function public.app_liked_comments(p_token text, p_comment_ids uuid[])
returns setof uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select l.comment_id from public.comment_likes l
    where l.user_id = uid and l.comment_id = any (p_comment_ids);
end $$;

-- ------------------------------------------------------------ permissões

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;

revoke execute on function
  public.app_publish_v2(text, text, text, text, int, int, text, jsonb, text, int, int, int, text),
  public.app_record_completion(text, uuid, int, int, int),
  public.app_comment_v2(text, uuid, text, uuid),
  public.app_set_comment_like(text, uuid, boolean),
  public.app_liked_comments(text, uuid[])
  from public, anon, authenticated;
grant execute on function
  public.app_publish_v2(text, text, text, text, int, int, text, jsonb, text, int, int, int, text),
  public.app_record_completion(text, uuid, int, int, int),
  public.app_comment_v2(text, uuid, text, uuid),
  public.app_set_comment_like(text, uuid, boolean),
  public.app_liked_comments(text, uuid[])
  to anon, authenticated;

-- A publicação antiga (app 1.9.7 de teste) continua a funcionar, mas o que
-- publica fica como roteiro: não traz prova, e republicar por ela tira o selo
-- de original a um itinerário que o tinha.
create or replace function public.app_publish(
  p_token text, p_title text, p_destination text, p_summary text,
  p_day_count int, p_stop_count int, p_travelled_month text,
  p_plan jsonb, p_source_trip_id text
) returns uuid language sql security definer set search_path = '' as $$
  select v.id from public.app_publish_v2(p_token, p_title, p_destination, p_summary,
    p_day_count, p_stop_count, p_travelled_month, p_plan, p_source_trip_id, 0, 0, 0, 'v1') v
$$;
revoke execute on function public.app_publish(text, text, text, text, int, int, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.app_publish(text, text, text, text, int, int, text, jsonb, text) to anon, authenticated;
