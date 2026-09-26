-- Comunidade Plan-ish — esquema 2: nomes dados pela Comunidade
--
-- Ninguém escolhe o próprio nome. Cada conta recebe um nome de uma lista de
-- nomes a brincar; e cada pessoa, uma vez, escolhe entre 4 nomes da lista o
-- nome da próxima pessoa que se juntar. Quem chega recebe primeiro os nomes
-- que alguém lhe deixou; se não houver, um nome ao acaso.
--
-- Correr depois do esquema 1. Pode correr mais do que uma vez.

create table if not exists public.name_pool (
  name text primary key check (char_length(name) between 3 and 40),
  taken_by uuid unique references auth.users (id) on delete set null,
  gifted_by uuid references auth.users (id) on delete set null,
  gifted_at timestamptz
);
alter table public.name_pool enable row level security;

insert into public.name_pool (name) values
  ('Andorinha Distraída'),
  ('Andorinha Errante'),
  ('Balão Errante'),
  ('Balão Explorador'),
  ('Barco Bem-disposto'),
  ('Barco Descalço'),
  ('Barco Madrugador'),
  ('Bicicleta Distraída'),
  ('Bicicleta Feliz'),
  ('Bicicleta Nómada'),
  ('Boia Aventureira'),
  ('Bússola Aventureira'),
  ('Bússola Curiosa'),
  ('Bússola Saltitante'),
  ('Cabana Distraída'),
  ('Cabana Errante'),
  ('Cabana Gulosa'),
  ('Cacto Bem-disposto'),
  ('Canoa Curiosa'),
  ('Canoa Gulosa'),
  ('Canoa Risonha'),
  ('Cantil Curioso'),
  ('Cantil Explorador'),
  ('Cantil Sonhador'),
  ('Caracol Apressado'),
  ('Caracol Bem-disposto'),
  ('Caracol Explorador'),
  ('Carrinha Bem-disposta'),
  ('Carrinha Risonha'),
  ('Castanha Descalça'),
  ('Castanha Feliz'),
  ('Castanha Teimosa'),
  ('Cegonha Bem-disposta'),
  ('Cegonha Sonhadora'),
  ('Cegonha Teimosa'),
  ('Chapéu Destemido'),
  ('Chapéu Feliz'),
  ('Chapéu Veloz'),
  ('Chinelo Descalço'),
  ('Chinelo Teimoso'),
  ('Chinelo Veloz'),
  ('Comboio Destemido'),
  ('Comboio Explorador'),
  ('Comboio Risonho'),
  ('Esquilo Apressado'),
  ('Esquilo Destemido'),
  ('Esquilo Nómada'),
  ('Estrela Feliz'),
  ('Farol Aventureiro'),
  ('Farol Nómada'),
  ('Farol Tranquilo'),
  ('Gaivota Curiosa'),
  ('Gaivota Feliz'),
  ('Gaivota Saltitante'),
  ('Golfinho Curioso'),
  ('Golfinho Saltitante'),
  ('Golfinho Teimoso'),
  ('Lanterna Errante'),
  ('Lanterna Gulosa'),
  ('Lanterna Sonhadora'),
  ('Mapa Errante'),
  ('Mapa Guloso'),
  ('Mochila Distraída'),
  ('Mocho Descalço'),
  ('Mocho Saltitante'),
  ('Mocho Sonolento'),
  ('Ouriço Aventureiro'),
  ('Ouriço Tranquilo'),
  ('Ouriço Veloz'),
  ('Pastel Bem-disposto'),
  ('Pastel Curioso'),
  ('Pastel Madrugador'),
  ('Pinguim Apressado'),
  ('Pinguim Saltitante'),
  ('Pinha Aventureira'),
  ('Pinha Gulosa'),
  ('Postal Apressado'),
  ('Postal Descalço'),
  ('Postal Veloz'),
  ('Raposa Destemida'),
  ('Raposa Exploradora'),
  ('Raposa Nómada'),
  ('Sandália Apressada'),
  ('Sandália Sonhadora'),
  ('Sandália Veloz'),
  ('Sardinha Sonhadora'),
  ('Tartaruga Madrugadora'),
  ('Tartaruga Sonhadora'),
  ('Tartaruga Teimosa'),
  ('Tenda Risonha'),
  ('Tenda Saltitante'),
  ('Toalha Feliz'),
  ('Toalha Gulosa'),
  ('Toalha Teimosa'),
  ('Trilho Apressado'),
  ('Trilho Destemido'),
  ('Trilho Errante'),
  ('Veleiro Aventureiro'),
  ('Veleiro Destemido'),
  ('Veleiro Explorador')
on conflict (name) do nothing;

alter table public.profiles add column if not exists named_by uuid references public.profiles (id) on delete set null;

-- Ninguém muda o nome à mão: vem da lista.
drop policy if exists "profiles: cada um muda o seu" on public.profiles;
revoke update on public.profiles from authenticated;

create table if not exists private.name_offers (
  user_id uuid primary key references auth.users (id) on delete cascade,
  names text[] not null,
  chosen text,
  created_at timestamptz not null default now()
);

-- O nome para uma conta nova: o que alguém deixou há mais tempo, ou ao acaso.
create or replace function private.assign_name(uid uuid)
returns table (name text, giver uuid)
language plpgsql security definer set search_path = '' as $$
declare picked text; v_giver uuid;
begin
  select p.name, p.gifted_by into picked, v_giver from public.name_pool p
   where p.taken_by is null and p.gifted_by is not null
   order by p.gifted_at limit 1 for update skip locked;
  if picked is null then
    select p.name into picked from public.name_pool p
     where p.taken_by is null and p.gifted_by is null
       and not exists (select 1 from private.name_offers o where o.chosen is null and p.name = any (o.names))
     order by random() limit 1 for update skip locked;
  end if;
  if picked is null then
    return query select 'Viajante ' || upper(substr(replace(uid::text, '-', ''), 1, 4)), null::uuid;
    return;
  end if;
  update public.name_pool set taken_by = uid, gifted_by = null, gifted_at = null where name_pool.name = picked;
  return query select picked, v_giver;
end $$;

create or replace function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare n text; g uuid;
begin
  select a.name, a.giver into n, g from private.assign_name(new.id) a;
  insert into public.profiles (id, display_name, named_by)
  values (new.id, n, (select id from public.profiles where id = g))
  on conflict (id) do nothing;
  return new;
end $$;

-- Contas que já existiam com o nome provisório recebem um nome da lista.
do $$
declare r record; n text;
begin
  for r in select id from public.profiles
            where display_name like 'Viajante %'
              and not exists (select 1 from public.name_pool p where p.taken_by = profiles.id) loop
    select a.name into n from private.assign_name(r.id) a;
    update public.profiles set display_name = n where id = r.id;
  end loop;
end $$;

-- As 4 hipóteses que esta conta tem para o nome do próximo viajante.
-- Sempre as mesmas até escolher: recarregar a página não dá outras.
create or replace function private.name_choices(uid uuid)
returns table (names text[], chosen text, named_by text)
language plpgsql security definer set search_path = '' as $$
declare o private.name_offers;
begin
  select * into o from private.name_offers where user_id = uid;
  if o.user_id is null then
    insert into private.name_offers (user_id, names)
    select uid, coalesce(array_agg(x.name), '{}') from (
      select p.name from public.name_pool p
       where p.taken_by is null and p.gifted_by is null
         and not exists (select 1 from private.name_offers f where f.chosen is null and p.name = any (f.names))
       order by random() limit 4) x
    returning * into o;
  end if;
  return query select o.names, o.chosen,
    (select g.display_name from public.profiles me join public.profiles g on g.id = me.named_by where me.id = uid);
end $$;

create or replace function private.give_name(uid uuid, p_name text)
returns text language plpgsql security definer set search_path = '' as $$
declare o private.name_offers;
begin
  select * into o from private.name_offers where user_id = uid for update;
  if o.user_id is null or o.chosen is not null or not (p_name = any (o.names)) then
    raise exception 'name_not_offered' using errcode = '22023',
      hint = 'Só podes escolher um dos nomes que te foram propostos, uma vez.';
  end if;
  update public.name_pool set gifted_by = uid, gifted_at = now()
   where name = p_name and taken_by is null and gifted_by is null;
  if not found then
    -- Entretanto alguém ficou com ele: propõe outros.
    delete from private.name_offers where user_id = uid;
    raise exception 'name_taken' using errcode = '22023',
      hint = 'Esse nome acabou de ser atribuído. Escolhe entre os novos.';
  end if;
  update private.name_offers set chosen = p_name where user_id = uid;
  return p_name;
end $$;

-- No site, com sessão iniciada.
create or replace function public.my_name_choices()
returns table (names text[], chosen text, named_by text)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return query select * from private.name_choices(auth.uid());
end $$;

create or replace function public.give_next_name(p_name text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return private.give_name(auth.uid(), p_name);
end $$;

-- Na app, com a ligação.
create or replace function public.app_name_choices(p_token text)
returns table (names text[], chosen text, named_by text)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select * from private.name_choices(uid);
end $$;

create or replace function public.app_give_next_name(p_token text, p_name text)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return private.give_name(uid, p_name);
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;
revoke execute on function public.my_name_choices(), public.give_next_name(text),
  public.app_name_choices(text), public.app_give_next_name(text, text) from public, anon, authenticated;
grant execute on function public.my_name_choices(), public.give_next_name(text) to authenticated;
grant execute on function public.app_name_choices(text), public.app_give_next_name(text, text) to anon, authenticated;
