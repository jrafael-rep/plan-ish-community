-- Comunidade Plan-ish — esquema 14: notificações no site.
--
-- Correr depois dos esquemas 1 a 13. Pode correr mais do que uma vez.
--
-- "Alguém gostou, comentou, avaliou ou fez a tua viagem, ou começou a
-- seguir-te." Preenchidas pelo servidor (triggers), nunca escritas por
-- ninguém. Não levam o texto de um comentário ou avaliação: só quem, o quê e
-- em que itinerário, para a moderação não ter de as apagar.
--
-- Uma notificação por (quem recebe, tipo, quem fez, itinerário): repetir um
-- gosto depois de o tirar não enche a lista, só a traz para cima e volta a
-- marcá-la por ler. Ninguém é notificado do que fez a si próprio, nem do que
-- faz quem bloqueou. Cada conta guarda no máximo as 200 mais recentes.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('like', 'comment', 'review', 'done', 'follow')),
  actor_id uuid not null references public.profiles (id) on delete cascade,
  itinerary_id uuid references public.itineraries (id) on delete cascade,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create unique index if not exists notifications_once
  on public.notifications (user_id, kind, actor_id, coalesce(itinerary_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index if not exists notifications_by_user on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;
drop policy if exists "notifications: cada um vê as suas" on public.notifications;
create policy "notifications: cada um vê as suas" on public.notifications
  for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;

/* Escreve uma notificação, se fizer sentido escrevê-la. */
create or replace function private.notify(p_user uuid, p_kind text, p_actor uuid, p_itinerary uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or p_actor is null or p_user = p_actor then return; end if;
  if exists (select 1 from public.user_blocks b where b.blocker_id = p_user and b.blocked_id = p_actor) then return; end if;
  insert into public.notifications (user_id, kind, actor_id, itinerary_id)
  values (p_user, p_kind, p_actor, p_itinerary)
  on conflict (user_id, kind, actor_id, coalesce(itinerary_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set created_at = now(), read_at = null;
  -- As 200 mais recentes chegam.
  delete from public.notifications n
   where n.user_id = p_user
     and n.id in (select id from public.notifications where user_id = p_user order by created_at desc offset 200);
end $$;

create or replace function private.notify_itinerary_author()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  author uuid;
  -- tg_argv: o tipo e a coluna de quem fez (user_id ou author_id, conforme a tabela).
  kind text := tg_argv[0];
  actor uuid := (to_jsonb(new) ->> tg_argv[1])::uuid;
begin
  select i.author_id into author from public.itineraries i where i.id = new.itinerary_id;
  perform private.notify(author, kind, actor, new.itinerary_id);
  return null;
end $$;

create or replace function private.notify_follow()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.notify(new.followee_id, 'follow', new.follower_id, null);
  return null;
end $$;

drop trigger if exists notify_like on public.likes;
create trigger notify_like after insert on public.likes
  for each row execute function private.notify_itinerary_author('like', 'user_id');
drop trigger if exists notify_comment on public.comments;
create trigger notify_comment after insert on public.comments
  for each row execute function private.notify_itinerary_author('comment', 'author_id');
drop trigger if exists notify_review on public.reviews;
create trigger notify_review after insert on public.reviews
  for each row execute function private.notify_itinerary_author('review', 'author_id');
drop trigger if exists notify_done on public.itinerary_completions;
create trigger notify_done after insert on public.itinerary_completions
  for each row execute function private.notify_itinerary_author('done', 'user_id');
drop trigger if exists notify_follow on public.follows;
create trigger notify_follow after insert on public.follows
  for each row execute function private.notify_follow();

/* Quantas estão por ler (o número no sino). */
create or replace function public.my_unread_count()
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications where user_id = auth.uid() and read_at is null
$$;

/* Marca todas como lidas; devolve quantas eram. */
create or replace function public.mark_notifications_read()
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  update public.notifications set read_at = now() where user_id = auth.uid() and read_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.my_unread_count(), public.mark_notifications_read() from public, anon, authenticated;
grant execute on function public.my_unread_count(), public.mark_notifications_read() to authenticated;
revoke execute on function private.notify(uuid, text, uuid, uuid), private.notify_itinerary_author(), private.notify_follow()
  from public, anon, authenticated;
