-- Comunidade Plan-ish — esquema 12: explorar com filtros.
--
-- Correr depois dos esquemas 1 a 11. Pode correr mais do que uma vez (mas não
-- voltar a correr o 11 depois deste: recriava a versão antiga ao lado).
--
-- 1. feed_page ganha dois filtros, os dois opcionais:
--      p_days   quantos dias: '1', '2-3', '4-7' ou '8+';
--      p_month  o mês em que a viagem foi feita (1 a 12), de travelled_month.
--    A app chama feed_page só com os cinco de antes, pelo nome: continua igual.
--
-- 2. explore_facets(p_search): o que o painel de filtros mostra ao lado de
--    cada opção, com as mesmas regras do feed (nunca o escondido; com sessão,
--    nunca quem a pessoa bloqueou):
--      levels        quantas há por prova (original, done, plan) e ao todo;
--      days          quantas por duração ('1', '2-3', '4-7', '8+');
--      months        quantas por mês de viagem (1 a 12), só os que têm;
--      destinations  os destinos mais publicados, no máximo 8, com a grafia
--                    mais usada. São os destinos que os cartões já mostram.

drop function if exists public.feed_page(text, text, text, int, int);

/* As durações do filtro, num só sítio. */
create or replace function private.day_bucket(p_span text)
returns table (lo int, hi int)
language sql immutable set search_path = '' as $$
  select case p_span when '1' then 1 when '2-3' then 2 when '4-7' then 4 when '8+' then 8 end,
         case p_span when '1' then 1 when '2-3' then 3 when '4-7' then 7 when '8+' then 100000 end
$$;

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
  if tab not in ('popular', 'recent', 'mine') then
    raise exception 'tab_invalid' using errcode = '22023';
  end if;
  if span is not null and span not in ('1', '2-3', '4-7', '8+') then
    raise exception 'days_invalid' using errcode = '22023';
  end if;
  if p_month is not null and p_month not between 1 and 12 then
    raise exception 'month_invalid' using errcode = '22023';
  end if;
  select b.lo, b.hi into lo, hi from private.day_bucket(span) b;
  if tab = 'mine' and uid is null then return; end if;
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
     order by
       case when tab = 'popular' then
         (select count(*) from public.likes l
           where l.itinerary_id = i.id and l.created_at > now() - interval '30 days')
         + (select count(*) from public.itinerary_completions c
             where c.itinerary_id = i.id and c.completed_at > now() - interval '30 days')
       end desc nulls last,
       case when tab = 'popular' then i.like_count end desc nulls last,
       i.created_at desc, i.id desc
     offset off limit lim;
end $$;

create or replace function public.explore_facets(p_search text default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  words text := nullif(lower(btrim(left(p_search, 60))), '');
  out jsonb;
begin
  with shown as (
    select i.evidence, i.day_count, i.travelled_month, nullif(btrim(i.destination), '') as destination
      from public.itineraries i
     where not i.hidden
       and (words is null
            or strpos(lower(i.title), words) > 0
            or strpos(lower(coalesce(i.destination, '')), words) > 0)
       and (uid is null or not exists (
             select 1 from public.user_blocks b where b.blocker_id = uid and b.blocked_id = i.author_id))
  ), places as (
    select lower(destination) as k, count(*) as n,
           mode() within group (order by destination) as label
      from shown where destination is not null
     group by lower(destination)
     order by count(*) desc, lower(destination)
     limit 8
  )
  select jsonb_build_object(
    'levels', jsonb_build_object(
      'all', (select count(*) from shown),
      'original', (select count(*) from shown where evidence = 'original'),
      'done', (select count(*) from shown where evidence = 'done'),
      'plan', (select count(*) from shown where coalesce(evidence, 'plan') = 'plan')),
    'days', jsonb_build_object(
      '1', (select count(*) from shown where day_count = 1),
      '2-3', (select count(*) from shown where day_count between 2 and 3),
      '4-7', (select count(*) from shown where day_count between 4 and 7),
      '8+', (select count(*) from shown where day_count >= 8)),
    'months', coalesce((select jsonb_object_agg(m, n) from (
        select substr(travelled_month, 6, 2)::int as m, count(*) as n
          from shown where travelled_month ~ '^\d{4}-(0[1-9]|1[0-2])$'
         group by 1) x), '{}'::jsonb),
    'destinations', coalesce((select jsonb_agg(jsonb_build_object('name', label, 'n', n) order by n desc, k) from places), '[]'::jsonb))
  into out;
  return out;
end $$;

revoke execute on function public.feed_page(text, text, text, int, int, text, int) from public, anon, authenticated;
grant execute on function public.feed_page(text, text, text, int, int, text, int) to anon, authenticated;
revoke execute on function public.explore_facets(text) from public, anon, authenticated;
grant execute on function public.explore_facets(text) to anon, authenticated;
revoke execute on function private.day_bucket(text) from public, anon, authenticated;
