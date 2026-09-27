-- Comunidade Plan-ish — esquema 4: orçamento e fotografias.
--
-- Correr depois dos esquemas 1, 2 e 3. Pode correr mais do que uma vez.
--
-- Orçamento: quem publica diz, se quiser, quanto custa por pessoa, numa
-- margem que escolhe à mão: "entre 250 e 400 €". Nunca um valor exato.
--
-- Fotografias: até 6 por itinerário, escolhidas na app, que as reduz e as
-- volta a gravar antes de as enviar (sai tudo o que vinha dentro da foto,
-- incluindo a localização). Ficam num bucket público do Storage. A app não
-- tem sessão no site: pede um bilhete (válido 30 minutos, para um itinerário
-- seu), envia as fotos para a pasta com o nome do bilhete e depois diz quais
-- ficam. Sem bilhete ninguém envia nada.

-- ------------------------------------------------------------ orçamento

alter table public.itineraries add column if not exists budget_min int;
alter table public.itineraries add column if not exists budget_max int;
alter table public.itineraries drop constraint if exists itineraries_budget_check;
alter table public.itineraries add constraint itineraries_budget_check check (
  (budget_min is null and budget_max is null)
  or (budget_min between 0 and 100000 and budget_max between budget_min and 100000)
);

create or replace function public.app_set_budget(p_token text, p_itinerary_id uuid, p_min int, p_max int)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token);
begin
  if (p_min is null) <> (p_max is null) then
    raise exception 'budget_invalid' using errcode = '22023', hint = 'Indica o valor mínimo e o máximo.';
  end if;
  update public.itineraries set budget_min = p_min, budget_max = p_max, updated_at = now()
   where id = p_itinerary_id and author_id = uid;
  if not found then
    raise exception 'not_yours' using errcode = '42501', hint = 'Este itinerário não é teu.';
  end if;
exception when check_violation then
  raise exception 'budget_invalid' using errcode = '22023',
    hint = 'O orçamento vai de 0 a 100 000 €, e o mínimo não passa o máximo.';
end $$;

-- ------------------------------------------------------------ fotografias

alter table public.itineraries add column if not exists photos text[] not null default '{}';
alter table public.itineraries drop constraint if exists itineraries_photos_check;
alter table public.itineraries add constraint itineraries_photos_check check (cardinality(photos) <= 6);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('itinerary-photos', 'itinerary-photos', true, 716800, array['image/jpeg'])
on conflict (id) do update set public = true,
  file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create table if not exists private.photo_tickets (
  ticket uuid primary key default gen_random_uuid(),
  itinerary_id uuid not null references public.itineraries (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create or replace function public.app_photo_ticket(p_token text, p_itinerary_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token); t uuid;
begin
  if not exists (select 1 from public.itineraries where id = p_itinerary_id and author_id = uid) then
    raise exception 'not_yours' using errcode = '42501', hint = 'Este itinerário não é teu.';
  end if;
  delete from private.photo_tickets where itinerary_id = p_itinerary_id or created_at < now() - interval '1 day';
  insert into private.photo_tickets (itinerary_id, user_id) values (p_itinerary_id, uid) returning ticket into t;
  return t;
end $$;

-- A regra do Storage: só se envia "<bilhete>/<1 a 6>.jpg", com um bilhete
-- válido. Os nomes não se repetem, por isso cada bilhete dá no máximo 6 fotos.
create or replace function public.photo_upload_allowed(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_name ~ '^[0-9a-f-]{36}/[1-6]\.jpg$' and exists (
    select 1 from private.photo_tickets t
     where t.ticket::text = split_part(p_name, '/', 1) and t.created_at > now() - interval '30 minutes')
$$;

drop policy if exists "itinerary-photos: envio com bilhete" on storage.objects;
create policy "itinerary-photos: envio com bilhete" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'itinerary-photos' and public.photo_upload_allowed(name));

create or replace function public.app_set_photos(p_token text, p_itinerary_id uuid, p_ticket uuid, p_count int)
returns text[] language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_interaction(p_token);
  paths text[];
begin
  if p_count is null or p_count < 0 or p_count > 6 then
    raise exception 'photos_invalid' using errcode = '22023', hint = 'Até 6 fotografias.';
  end if;
  if not exists (select 1 from private.photo_tickets t
                  where t.ticket = p_ticket and t.itinerary_id = p_itinerary_id and t.user_id = uid) then
    raise exception 'not_yours' using errcode = '42501', hint = 'Este itinerário não é teu.';
  end if;
  paths := coalesce(array(select p_ticket::text || '/' || n || '.jpg' from generate_series(1, p_count) n), '{}');
  if exists (select 1 from unnest(paths) p
              where not exists (select 1 from storage.objects o where o.bucket_id = 'itinerary-photos' and o.name = p)) then
    raise exception 'photo_missing' using errcode = '22023', hint = 'Uma das fotografias não chegou. Tenta outra vez.';
  end if;
  update public.itineraries set photos = paths, updated_at = now()
   where id = p_itinerary_id and author_id = uid;
  return paths;
end $$;

-- ------------------------------------------------------------ permissões

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;

revoke execute on function
  public.app_set_budget(text, uuid, int, int),
  public.app_photo_ticket(text, uuid),
  public.app_set_photos(text, uuid, uuid, int),
  public.photo_upload_allowed(text)
  from public, anon, authenticated;
grant execute on function
  public.app_set_budget(text, uuid, int, int),
  public.app_photo_ticket(text, uuid),
  public.app_set_photos(text, uuid, uuid, int),
  public.photo_upload_allowed(text)
  to anon, authenticated;
