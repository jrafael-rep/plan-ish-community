-- Comunidade Plan-ish — esquema 18: a conta "AI-ish", autora dos roteiros feitos com IA.
--
-- Correr depois dos esquemas 1 a 17. Pode correr mais do que uma vez.
--
-- Os roteiros feitos com IA saíam em nome de quem os publicava no painel. O
-- dono, a 1 out 2026: "não publiques com o meu nome, usa uma conta para a IA".
-- Passam a ter uma conta própria, "AI-ish", sem email, sem telefone e sem
-- password: ninguém entra com ela, só dá o nome aos cartões.
--
-- Uma conta nova recebe um nome da lista, e pode ser um que alguém deu ao
-- próximo viajante. A AI-ish não é ninguém: o nome que a criação lhe tirar
-- volta à lista tal como estava, e ela fica com o seu.

create table if not exists private.ai_author (
  only_one boolean primary key default true check (only_one),
  user_id uuid not null references auth.users(id) on delete cascade
);
revoke all on private.ai_author from public, anon, authenticated;

do $$
declare
  ai uuid;
begin
  select user_id into ai from private.ai_author;
  if ai is null then
    create temporary table name_pool_before on commit drop as
      select name, gifted_by, gifted_at from public.name_pool where taken_by is null;
    insert into auth.users (id) values (gen_random_uuid()) returning id into ai;
    update public.name_pool p set taken_by = null, gifted_by = b.gifted_by, gifted_at = b.gifted_at
      from name_pool_before b where p.taken_by = ai and p.name = b.name;
    insert into private.ai_author (user_id) values (ai);
  end if;
  insert into public.profiles (id, display_name) values (ai, 'AI-ish')
    on conflict (id) do update set display_name = 'AI-ish', named_by = null;
  -- Sem forma de entrar: no Supabase, também bloqueada.
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'banned_until') then
    execute 'update auth.users set banned_until = ''2999-01-01'' where id = $1' using ai;
  end if;
  -- Os que já estavam publicados passam para ela.
  update public.itineraries set author_id = ai where origin = 'ai' and author_id <> ai;
end $$;

-- Os termos de utilização são de pessoas. A AI-ish não os aceita porque não é
-- ninguém: quem responde pelo que ela publica é quem gere, e é a esse que
-- admin_publish_plan os pede. O resto da verificação fica igual.
create or replace function private.check_author()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.author_id = (select user_id from private.ai_author) then
    return new;
  end if;
  if private.is_blocked(new.author_id) then
    raise exception 'account_blocked' using errcode = '42501',
      hint = 'Esta conta foi bloqueada na Comunidade por não cumprir os termos de utilização.';
  end if;
  if not private.accepted_terms(new.author_id) then
    raise exception 'terms_required' using errcode = '42501',
      hint = 'Para publicar, comentar ou avaliar, aceita primeiro os termos de utilização da Comunidade.';
  end if;
  return new;
end $$;

-- Quem publica continua a ser quem gere a Comunidade; quem assina é a AI-ish.
create or replace function public.admin_publish_plan(
  p_title text,
  p_destination text,
  p_summary text,
  p_plan jsonb,
  p_ai boolean default true
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_admin();
  author uuid := case when p_ai then coalesce((select user_id from private.ai_author), uid) else uid end;
  clean jsonb := coalesce(p_plan, '{}'::jsonb) - 'home' - 'participants' - 'responsibilities' - 'id';
  days int := case when jsonb_typeof(clean->'days') = 'array' then jsonb_array_length(clean->'days') else 0 end;
  stops int := (select coalesce(sum(case when jsonb_typeof(d->'stops') = 'array' then jsonb_array_length(d->'stops') else 0 end), 0)
                from jsonb_array_elements(case when jsonb_typeof(clean->'days') = 'array' then clean->'days' else '[]'::jsonb end) d);
  new_id uuid;
begin
  if not private.accepted_terms(uid) then
    raise exception 'terms_required' using errcode = '42501',
      hint = 'Para publicar, comentar ou avaliar, aceita primeiro os termos de utilização da Comunidade.';
  end if;
  if nullif(btrim(p_title), '') is null then
    raise exception 'title_required' using errcode = '22023';
  end if;
  if days not between 1 and 60 then
    raise exception 'plan_days_invalid' using errcode = '22023', hint = 'O plano tem de ter entre 1 e 60 dias.';
  end if;
  if stops < 1 then
    raise exception 'plan_stops_invalid' using errcode = '22023', hint = 'O plano não tem paragens.';
  end if;
  insert into public.itineraries (author_id, title, destination, summary, day_count, stop_count, plan, evidence, origin)
  values (author, left(btrim(p_title), 120), nullif(left(btrim(p_destination), 120), ''),
          nullif(left(btrim(p_summary), 2000), ''), days, least(stops, 500), clean, 'plan',
          case when p_ai then 'ai' else 'trip' end)
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.admin_publish_plan(text, text, text, jsonb, boolean) from public, anon;
grant execute on function public.admin_publish_plan(text, text, text, jsonb, boolean) to authenticated;
