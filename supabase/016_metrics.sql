-- Comunidade Plan-ish — esquema 16: métricas para a administração.
--
-- Correr depois dos esquemas 1 a 15. Pode correr mais do que uma vez.
--
-- O que se guarda é só contagem: quantas vezes, por dia, alguém abriu o
-- feed, viu um itinerário ou o copiou. Nunca quem, nunca de onde, nunca
-- localização. Não há ids de pessoas, de aparelhos nem endereços IP nestas
-- tabelas; por itinerário guarda-se só o total. O resto do painel conta o que
-- já existe nas outras tabelas (contas, publicações, gostos, guardados…).
--
-- count_event() é aberta a toda a gente (a app não tem sessão e o site pode
-- não ter), por isso os números podem ser inflacionados por quem quiser: são
-- para o dono ter uma ideia, não entram em nenhuma ordenação nem em pontos.

create table if not exists private.daily_counts (
  day date not null,
  kind text not null,
  n int not null default 0,
  primary key (day, kind)
);
alter table private.daily_counts enable row level security;

create table if not exists private.itinerary_counts (
  itinerary_id uuid not null references public.itineraries (id) on delete cascade,
  kind text not null,
  n int not null default 0,
  primary key (itinerary_id, kind)
);
alter table private.itinerary_counts enable row level security;

-- Os acontecimentos que se contam, e se levam um itinerário.
--   app_open_feed        a Comunidade aberta na app
--   app_view_itinerary   um itinerário aberto na app
--   app_copy             um itinerário copiado para o planeamento, na app
--   site_open_feed       o feed aberto no site
--   site_view_itinerary  um itinerário aberto no site
create or replace function private.metric_kinds()
returns text[] language sql immutable set search_path = '' as $$
  select array['app_open_feed', 'app_view_itinerary', 'app_copy', 'site_open_feed', 'site_view_itinerary']
$$;

create or replace function public.count_event(p_kind text, p_itinerary_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  today date := (now() at time zone 'Europe/Lisbon')::date;
begin
  if p_kind is null or not (p_kind = any (private.metric_kinds())) then
    raise exception 'unknown_metric' using errcode = '22023';
  end if;
  insert into private.daily_counts (day, kind, n) values (today, p_kind, 1)
  on conflict (day, kind) do update set n = private.daily_counts.n + 1;
  -- Só itinerários visíveis; um id inventado não cria nada.
  if p_itinerary_id is not null
     and exists (select 1 from public.itineraries i where i.id = p_itinerary_id and not i.hidden) then
    insert into private.itinerary_counts (itinerary_id, kind, n) values (p_itinerary_id, p_kind, 1)
    on conflict (itinerary_id, kind) do update set n = private.itinerary_counts.n + 1;
  end if;
end $$;
revoke all on function public.count_event(text, uuid) from public;
grant execute on function public.count_event(text, uuid) to anon, authenticated;

-- Tudo o que o painel mostra, numa chamada. Só para quem modera.
create or replace function public.admin_metrics(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  days int := least(greatest(coalesce(p_days, 30), 7), 365);
  today date := (now() at time zone 'Europe/Lisbon')::date;
  since date := today - (days - 1);
  result jsonb;
begin
  perform private.require_admin();

  with span as (
    select d::date as day from generate_series(since, today, interval '1 day') d
  ),
  local_day as (
    -- O dia de Lisboa de cada acontecimento que já existe noutras tabelas.
    select 'accounts' as kind, (created_at at time zone 'Europe/Lisbon')::date as day from public.profiles
    union all select 'apps_linked', (created_at at time zone 'Europe/Lisbon')::date from public.app_links
    union all select 'published', (created_at at time zone 'Europe/Lisbon')::date from public.itineraries
    union all select 'likes', (created_at at time zone 'Europe/Lisbon')::date from public.likes
    union all select 'saves', (created_at at time zone 'Europe/Lisbon')::date from public.saves
    union all select 'follows', (created_at at time zone 'Europe/Lisbon')::date from public.follows
    union all select 'reviews', (created_at at time zone 'Europe/Lisbon')::date from public.reviews
    union all select 'comments', (created_at at time zone 'Europe/Lisbon')::date from public.comments
    union all select 'completions', (completed_at at time zone 'Europe/Lisbon')::date from public.itinerary_completions
  ),
  per_day as (
    select kind, day, count(*)::int as n from local_day where day >= since group by kind, day
    union all
    select kind, day, n from private.daily_counts where day >= since
  ),
  series as (
    select k.kind, jsonb_agg(coalesce(p.n, 0) order by s.day) as values
      from (select distinct kind from per_day
            union select unnest(private.metric_kinds())
            union select unnest(array['accounts','apps_linked','published','likes','saves','follows','reviews','comments','completions'])) k
      cross join span s
      left join per_day p on p.kind = k.kind and p.day = s.day
     group by k.kind
  ),
  top_counts as (
    select c.kind, jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title, 'n', c.n) order by c.n desc) as items
      from (select *, row_number() over (partition by kind order by n desc) as r from private.itinerary_counts) c
      join public.itineraries i on i.id = c.itinerary_id
     where c.r <= 5
     group by c.kind
  )
  select jsonb_build_object(
    'since', since,
    'today', today,
    'days', days,
    'totals', jsonb_build_object(
      'accounts', (select count(*) from public.profiles),
      'members', (select count(*) from public.memberships m where m.valid_until is null or m.valid_until > now()),
      'apps_linked', (select count(*) from public.app_links),
      'accounts_with_app', (select count(distinct user_id) from public.app_links),
      'apps_active_30d', (select count(*) from public.app_links where last_used_at > now() - interval '30 days'),
      'itineraries', (select count(*) from public.itineraries where not hidden),
      'itineraries_hidden', (select count(*) from public.itineraries where hidden),
      'authors', (select count(distinct author_id) from public.itineraries where not hidden),
      'by_evidence', (select coalesce(jsonb_object_agg(evidence, n), '{}'::jsonb)
                        from (select coalesce(evidence, 'plan') as evidence, count(*) as n
                                from public.itineraries where not hidden group by 1) e),
      'likes', (select count(*) from public.likes),
      'saves', (select count(*) from public.saves),
      'follows', (select count(*) from public.follows),
      'reviews', (select count(*) from public.reviews where not hidden),
      'comments', (select count(*) from public.comments where not hidden),
      'completions', (select count(*) from public.itinerary_completions),
      'shared_plans', (select count(*) from public.shared_plans),
      'seals', (select count(*) from private.record_seals),
      'reports_open', (select count(*) from public.reports where resolved_at is null),
      'copies', (select coalesce(sum(n), 0) from private.daily_counts where kind = 'app_copy'),
      'views', (select coalesce(sum(n), 0) from private.daily_counts where kind in ('app_view_itinerary', 'site_view_itinerary'))
    ),
    'series', (select coalesce(jsonb_object_agg(kind, values), '{}'::jsonb) from series),
    'top', (select coalesce(jsonb_object_agg(kind, items), '{}'::jsonb) from top_counts),
    'top_liked', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'n', like_count) order by like_count desc), '[]'::jsonb)
                    from (select id, title, like_count from public.itineraries
                           where not hidden and like_count > 0 order by like_count desc limit 5) t),
    'top_saved', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'n', save_count) order by save_count desc), '[]'::jsonb)
                    from (select id, title, save_count from public.itineraries
                           where not hidden and save_count > 0 order by save_count desc limit 5) t)
  ) into result;
  return result;
end $$;
revoke all on function public.admin_metrics(int) from public;
grant execute on function public.admin_metrics(int) to authenticated;
