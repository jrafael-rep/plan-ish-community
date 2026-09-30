-- Comunidade Plan-ish — esquema 17: roteiros feitos com IA.
--
-- Correr depois dos esquemas 1 a 16. Pode correr mais do que uma vez.
--
-- O dono publica, a partir da página de administração, planos escritos com a
-- ajuda de uma IA (um JSON no formato de importação da app). Ficam marcados
-- (origin = 'ai'), aparecem num carrossel próprio e nunca no feed das viagens
-- de pessoas, e são sempre "Roteiro" (evidence = 'plan'): nada neles diz que
-- alguém os fez.

alter table public.itineraries add column if not exists origin text not null default 'trip';
alter table public.itineraries drop constraint if exists itineraries_origin_check;
alter table public.itineraries add constraint itineraries_origin_check check (origin in ('trip', 'ai'));
create index if not exists itineraries_ai on public.itineraries (created_at desc) where origin = 'ai' and not hidden;

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
  if tab not in ('popular', 'recent', 'mine', 'following', 'saved', 'ai') then
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
       -- Os feitos com IA vivem no seu carrossel ('ai'); nos pessoais aparecem.
       and (tab in ('mine', 'saved', 'ai') or i.origin <> 'ai')
       and (tab <> 'ai' or i.origin = 'ai')
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

-- Publicar um plano a partir do painel. Só para quem gere a Comunidade.
-- O plano vai tal como a app o importa, sem os campos pessoais.
create or replace function public.admin_publish_plan(
  p_title text,
  p_destination text,
  p_summary text,
  p_plan jsonb,
  p_ai boolean default true
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_admin();
  clean jsonb := coalesce(p_plan, '{}'::jsonb) - 'home' - 'participants' - 'responsibilities' - 'id';
  days int := case when jsonb_typeof(clean->'days') = 'array' then jsonb_array_length(clean->'days') else 0 end;
  stops int := (select coalesce(sum(case when jsonb_typeof(d->'stops') = 'array' then jsonb_array_length(d->'stops') else 0 end), 0)
                  from jsonb_array_elements(case when jsonb_typeof(clean->'days') = 'array' then clean->'days' else '[]'::jsonb end) d);
  new_id uuid;
begin
  if nullif(btrim(p_title), '') is null then raise exception 'title_required' using errcode = '22023'; end if;
  if days not between 1 and 60 then raise exception 'plan_days_invalid' using errcode = '22023', hint = 'O plano tem de ter entre 1 e 60 dias.'; end if;
  if stops < 1 then raise exception 'plan_stops_invalid' using errcode = '22023', hint = 'O plano não tem paragens.'; end if;
  insert into public.itineraries (author_id, title, destination, summary, day_count, stop_count, plan, evidence, origin)
  values (uid, left(btrim(p_title), 120), nullif(left(btrim(p_destination), 120), ''), nullif(left(btrim(p_summary), 2000), ''),
          days, least(stops, 500), clean, 'plan', case when p_ai then 'ai' else 'trip' end)
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.admin_publish_plan(text, text, text, jsonb, boolean) from public, anon;
grant execute on function public.admin_publish_plan(text, text, text, jsonb, boolean) to authenticated;
revoke execute on function private.feed_rows(uuid, text, text, text, int, int, text, int) from public, anon, authenticated;
