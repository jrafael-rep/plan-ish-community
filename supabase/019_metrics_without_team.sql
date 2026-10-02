-- Comunidade Plan-ish — esquema 19: as métricas sem as contas da equipa.
--
-- Correr depois dos esquemas 1 a 18. Pode correr mais do que uma vez.
--
-- O dono, a 2 out 2026: "não contabilizar as minhas contas e as do sistema
-- para métricas, assim vejo os utilizadores reais". Ficam de fora das contagens
-- de pessoas: quem gere (private.admins), a AI-ish e qualquer conta posta em
-- private.metrics_excluded (uma conta de testes, por exemplo):
--
--   insert into private.metrics_excluded (user_id) values ('…');
--
-- Nada é apagado: as contas e o que fizeram continuam onde estão. As visitas,
-- o feed aberto e as cópias são contagens anónimas por dia, sem conta, e por
-- isso não se conseguem separar; continuam a contar tudo.

create table if not exists private.metrics_excluded (
  user_id uuid primary key references auth.users (id) on delete cascade
);
revoke all on private.metrics_excluded from public, anon, authenticated;

create or replace function private.is_team(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.admins where user_id = p_user)
      or exists (select 1 from private.ai_author where user_id = p_user)
      or exists (select 1 from private.metrics_excluded where user_id = p_user)
$$;
revoke all on function private.is_team(uuid) from public, anon, authenticated;

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
    select 'accounts' as kind, (created_at at time zone 'Europe/Lisbon')::date as day from public.profiles where not private.is_team(id)
    union all select 'apps_linked', (created_at at time zone 'Europe/Lisbon')::date from public.app_links where not private.is_team(user_id)
    union all select 'published', (created_at at time zone 'Europe/Lisbon')::date from public.itineraries where not private.is_team(author_id)
    union all select 'likes', (created_at at time zone 'Europe/Lisbon')::date from public.likes where not private.is_team(user_id)
    union all select 'saves', (created_at at time zone 'Europe/Lisbon')::date from public.saves where not private.is_team(user_id)
    union all select 'follows', (created_at at time zone 'Europe/Lisbon')::date from public.follows where not private.is_team(follower_id)
    union all select 'reviews', (created_at at time zone 'Europe/Lisbon')::date from public.reviews where not private.is_team(author_id)
    union all select 'comments', (created_at at time zone 'Europe/Lisbon')::date from public.comments where not private.is_team(author_id)
    union all select 'completions', (completed_at at time zone 'Europe/Lisbon')::date from public.itinerary_completions where not private.is_team(user_id)
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
      'accounts', (select count(*) from public.profiles where not private.is_team(id)),
      'team_excluded', (select count(*) from public.profiles where private.is_team(id)),
      'members', (select count(*) from public.memberships m where (m.valid_until is null or m.valid_until > now()) and not private.is_team(m.user_id)),
      'apps_linked', (select count(*) from public.app_links where not private.is_team(user_id)),
      'accounts_with_app', (select count(distinct user_id) from public.app_links where not private.is_team(user_id)),
      'apps_active_30d', (select count(*) from public.app_links where last_used_at > now() - interval '30 days' and not private.is_team(user_id)),
      'itineraries', (select count(*) from public.itineraries where not hidden and not private.is_team(author_id)),
      'itineraries_hidden', (select count(*) from public.itineraries where hidden and not private.is_team(author_id)),
      'authors', (select count(distinct author_id) from public.itineraries where not hidden and not private.is_team(author_id)),
      'by_evidence', (select coalesce(jsonb_object_agg(evidence, n), '{}'::jsonb)
                        from (select coalesce(evidence, 'plan') as evidence, count(*) as n
                                from public.itineraries where not hidden and not private.is_team(author_id) group by 1) e),
      'likes', (select count(*) from public.likes where not private.is_team(user_id)),
      'saves', (select count(*) from public.saves where not private.is_team(user_id)),
      'follows', (select count(*) from public.follows where not private.is_team(follower_id)),
      'reviews', (select count(*) from public.reviews where not hidden and not private.is_team(author_id)),
      'comments', (select count(*) from public.comments where not hidden and not private.is_team(author_id)),
      'completions', (select count(*) from public.itinerary_completions where not private.is_team(user_id)),
      'shared_plans', (select count(*) from public.shared_plans where not private.is_team(owner_id)),
      'seals', (select count(*) from private.record_seals where not private.is_team(user_id)),
      'reports_open', (select count(*) from public.reports where resolved_at is null),
      'copies', (select coalesce(sum(n), 0) from private.daily_counts where kind = 'app_copy'),
      'views', (select coalesce(sum(n), 0) from private.daily_counts where kind in ('app_view_itinerary', 'site_view_itinerary'))
    ),
    'series', (select coalesce(jsonb_object_agg(kind, values), '{}'::jsonb) from series),
    'top', (select coalesce(jsonb_object_agg(kind, items), '{}'::jsonb) from top_counts),
    -- Gostos e guardados de pessoas reais; os itinerários podem ser de quem for.
    'top_liked', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'n', n) order by n desc), '[]'::jsonb)
                    from (select i.id, i.title, count(*)::int as n from public.likes l
                            join public.itineraries i on i.id = l.itinerary_id
                           where not i.hidden and not private.is_team(l.user_id)
                           group by i.id, i.title order by n desc limit 5) t),
    'top_saved', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'n', n) order by n desc), '[]'::jsonb)
                    from (select i.id, i.title, count(*)::int as n from public.saves v
                            join public.itineraries i on i.id = v.itinerary_id
                           where not i.hidden and not private.is_team(v.user_id)
                           group by i.id, i.title order by n desc limit 5) t)
  ) into result;
  return result;
end $$;
revoke all on function public.admin_metrics(int) from public;
grant execute on function public.admin_metrics(int) to authenticated;
