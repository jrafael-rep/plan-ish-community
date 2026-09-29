-- Comunidade Plan-ish — esquema 15: os separadores pessoais na app.
--
-- Correr depois dos esquemas 1 a 14. Pode correr mais do que uma vez.
--
-- A app não tem sessão do Supabase: fala com o token da ligação. Para ter
-- "A seguir" e "Guardados", o feed passa a ser uma função privada que recebe
-- a pessoa (private.feed_rows), e há duas portas para ela:
--   feed_page(...)                a do site, com a sessão (auth.uid());
--   app_feed_page(p_token, ...)   a da app, com a ligação.
-- As regras são as mesmas nas duas: nunca o escondido, nunca quem a pessoa
-- bloqueou, e os separadores pessoais só com alguém do outro lado.

create or replace function private.feed_rows(
  p_uid uuid,
  p_tab text,
  p_level text,
  p_search text,
  p_offset int,
  p_limit int,
  p_days text,
  p_month int
) returns setof public.itineraries
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := p_uid;
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

create or replace function public.feed_page(
  p_tab text default 'popular',
  p_level text default null,
  p_search text default null,
  p_offset int default 0,
  p_limit int default 20,
  p_days text default null,
  p_month int default null
) returns setof public.itineraries
language sql stable security definer set search_path = '' as $$
  select * from private.feed_rows((select auth.uid()), p_tab, p_level, p_search, p_offset, p_limit, p_days, p_month)
$$;

create or replace function public.app_feed_page(
  p_token text,
  p_tab text default 'popular',
  p_level text default null,
  p_search text default null,
  p_offset int default 0,
  p_limit int default 20
) returns setof public.itineraries
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select * from private.feed_rows(uid, p_tab, p_level, p_search, p_offset, p_limit, null, null);
end $$;

revoke execute on function private.feed_rows(uuid, text, text, text, int, int, text, int) from public, anon, authenticated;
revoke execute on function public.feed_page(text, text, text, int, int, text, int) from public, anon, authenticated;
grant execute on function public.feed_page(text, text, text, int, int, text, int) to anon, authenticated;
revoke execute on function public.app_feed_page(text, text, text, text, int, int) from public, anon, authenticated;
grant execute on function public.app_feed_page(text, text, text, text, int, int) to anon, authenticated;
