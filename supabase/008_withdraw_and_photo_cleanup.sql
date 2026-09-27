-- 008 — Retirar um itinerário de verdade, e "Os meus itinerários".
--
-- Até aqui, retirar apagava a linha mas as fotografias ficavam no Storage,
-- públicas, e só se conseguia retirar a partir do telemóvel que tinha a
-- viagem. Agora:
--   * cada fotografia que deixa de pertencer a um itinerário (retirado, conta
--     apagada ou fotos trocadas) vai para private.photo_trash;
--   * quem retira recebe a lista e apaga os ficheiros pela API do Storage (o
--     Postgres não pode apagar ficheiros: só a API os tira do bucket);
--   * o Storage só deixa apagar, e só "vê" para apagar, o que está no lixo;
--   * a app e o site listam os itinerários da conta, escondidos incluídos,
--     com gostos, comentários e avaliações, e retiram qualquer um deles.

-- ------------------------------------------------------------ lixo de fotos

-- Sem chave estrangeira em user_id: quando se apaga a conta, as linhas entram
-- aqui durante a cascata, já sem perfil. Ficam como "órfãs" e quem limpar a
-- seguir leva-as.
create table if not exists private.photo_trash (
  path text primary key,
  user_id uuid,
  trashed_at timestamptz not null default now()
);
alter table private.photo_trash enable row level security;

create or replace function private.trash_photos()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    insert into private.photo_trash (path, user_id)
      select p, old.author_id from unnest(old.photos) p
      on conflict (path) do nothing;
    return old;
  end if;
  insert into private.photo_trash (path, user_id)
    select p, new.author_id from unnest(old.photos) p
     where not (p = any (new.photos))
    on conflict (path) do nothing;
  return new;
end $$;

drop trigger if exists trash_photos on public.itineraries;
create trigger trash_photos
  after delete or update of photos on public.itineraries
  for each row execute function private.trash_photos();

-- O que esta conta tem para apagar do Storage: o seu lixo e o de contas que já
-- não existem. Tira primeiro da lista o que já saiu do bucket.
create or replace function private.take_trash(uid uuid)
returns text[] language plpgsql security definer set search_path = '' as $$
begin
  delete from private.photo_trash t
   where not exists (select 1 from storage.objects o
                      where o.bucket_id = 'itinerary-photos' and o.name = t.path);
  return coalesce(array(
    select t.path from private.photo_trash t
     where t.user_id = uid
        or t.user_id is null
        or not exists (select 1 from public.profiles p where p.id = t.user_id)
     order by t.trashed_at
     limit 200), '{}');
end $$;

-- Para as regras do Storage (abaixo).
create or replace function public.photo_in_trash(p_name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.photo_trash where path = p_name)
$$;

-- Apagar pela API do Storage pede DELETE e, para devolver o que apagou, SELECT.
-- O SELECT só vale na operação de apagar: listar o bucket não mostra o lixo.
drop policy if exists "itinerary-photos: ver o lixo para o apagar" on storage.objects;
create policy "itinerary-photos: ver o lixo para o apagar" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'itinerary-photos'
         and storage.allow_any_operation(array['object.delete', 'object.delete_many'])
         and public.photo_in_trash(name));

drop policy if exists "itinerary-photos: apagar o lixo" on storage.objects;
create policy "itinerary-photos: apagar o lixo" on storage.objects
  for delete to anon, authenticated
  using (bucket_id = 'itinerary-photos' and public.photo_in_trash(name));

-- ------------------------------------------------------------ os meus itinerários

create or replace function private.published_by(uid uuid)
returns table (
  id uuid, source_trip_id text, title text, destination text,
  created_at timestamptz, updated_at timestamptz, hidden boolean,
  like_count int, comment_count int, review_count int,
  verified_rating_count int, verified_rating_avg numeric, rating_count int, rating_avg numeric,
  photo_count int
) language sql stable security definer set search_path = '' as $$
  select i.id, i.source_trip_id, i.title, i.destination, i.created_at, i.updated_at, i.hidden,
         i.like_count, i.comment_count, i.review_count,
         i.verified_rating_count, i.verified_rating_avg, i.rating_count, i.rating_avg,
         cardinality(i.photos)
    from public.itineraries i
   where i.author_id = uid
   order by i.updated_at desc
$$;

-- App: a lista, retirar (devolve as fotos a apagar) e o lixo pendente.
create or replace function public.app_my_published(p_token text)
returns table (
  id uuid, source_trip_id text, title text, destination text,
  created_at timestamptz, updated_at timestamptz, hidden boolean,
  like_count int, comment_count int, review_count int,
  verified_rating_count int, verified_rating_avg numeric, rating_count int, rating_avg numeric,
  photo_count int
) language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select * from private.published_by(uid);
end $$;

create or replace function public.app_withdraw(p_token text, p_itinerary_id uuid)
returns text[] language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  delete from public.itineraries where id = p_itinerary_id and author_id = uid;
  return private.take_trash(uid);
end $$;

create or replace function public.app_photo_trash(p_token text)
returns text[] language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return private.take_trash(uid);
end $$;

-- Site: o mesmo, com a sessão.
create or replace function public.my_published()
returns table (
  id uuid, source_trip_id text, title text, destination text,
  created_at timestamptz, updated_at timestamptz, hidden boolean,
  like_count int, comment_count int, review_count int,
  verified_rating_count int, verified_rating_avg numeric, rating_count int, rating_avg numeric,
  photo_count int
) language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return query select * from private.published_by(auth.uid());
end $$;

create or replace function public.withdraw_itinerary(p_itinerary_id uuid)
returns text[] language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  delete from public.itineraries where id = p_itinerary_id and author_id = auth.uid();
  return private.take_trash(auth.uid());
end $$;

-- Antes de apagar a conta: retira tudo e devolve as fotos, para o site as
-- apagar enquanto ainda tem sessão.
create or replace function public.withdraw_all_mine()
returns text[] language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  delete from public.itineraries where author_id = auth.uid();
  return private.take_trash(auth.uid());
end $$;

create or replace function public.my_photo_trash()
returns text[] language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return private.take_trash(auth.uid());
end $$;

-- ------------------------------------------------------------ permissões

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;
grant execute on function private.plan_role(uuid, uuid) to authenticated;

revoke execute on function
  public.photo_in_trash(text),
  public.app_my_published(text), public.app_withdraw(text, uuid), public.app_photo_trash(text),
  public.my_published(), public.withdraw_itinerary(uuid), public.withdraw_all_mine(), public.my_photo_trash()
  from public, anon, authenticated;
-- A regra do Storage chama-a com o papel de quem pede.
grant execute on function public.photo_in_trash(text) to anon, authenticated;
grant execute on function
  public.app_my_published(text), public.app_withdraw(text, uuid), public.app_photo_trash(text)
  to anon, authenticated;
grant execute on function
  public.my_published(), public.withdraw_itinerary(uuid), public.withdraw_all_mine(), public.my_photo_trash()
  to authenticated;
