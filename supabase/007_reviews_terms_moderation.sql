-- Comunidade Plan-ish — esquema 7: avaliações, termos, moderação e bloqueios.
--
-- Correr depois dos esquemas 1 a 6. Pode correr mais do que uma vez.
--
-- Avaliações. Cada conta tem, no máximo, uma avaliação por itinerário: estrelas
-- (1 a 5), um comentário, ou os dois. Há duas categorias, e quem decide é o
-- servidor, nunca quem escreve:
--
--   "de quem fez"  a conta fez este itinerário e o GPS confirmou-o
--                  (itinerary_completions com evidence = 'original');
--   geral          qualquer outra conta.
--
-- As estrelas mostram-se em destaque só as de quem fez; a média de todas vai
-- ao lado, mais pequena. A app escreve avaliações mas, por agora, não mostra as
-- dos outros: só os números (ver CONVERSATION_IN_APP na app).
--
-- Termos. Publicar, comentar e avaliar pedem a aceitação da versão em vigor dos
-- termos de utilização (a Play exige-o antes de alguém criar conteúdo). Gostar
-- não cria conteúdo e não os pede. A regra está em gatilhos nas tabelas, por
-- isso vale para a app e para o site.
--
-- Moderação. Quem está em private.admins vê as denúncias no site
-- (moderacao.html), esconde ou volta a mostrar itinerários, comentários e
-- avaliações, e bloqueia contas. Uma conta bloqueada não publica, não comenta,
-- não avalia nem dá likes, e o que já tinha publicado fica escondido.
--
-- Bloqueios pessoais. Cada conta pode bloquear outra: deixa de ver o que ela
-- escreve (o site filtra). Não esconde nada a mais ninguém.

-- ------------------------------------------------------------------ termos

alter table public.community_settings add column if not exists terms_version text;
-- A versão em vigor. Mudar isto pede a toda a gente que aceite outra vez.
update public.community_settings set terms_version = '2026-09-27' where terms_version is null;

create table if not exists private.terms_acceptances (
  user_id uuid not null references auth.users (id) on delete cascade,
  version text not null check (char_length(version) between 1 and 40),
  accepted_at timestamptz not null default now(),
  primary key (user_id, version)
);

alter table private.terms_acceptances enable row level security;

create or replace function private.terms_version()
returns text language sql stable security definer set search_path = '' as $$
  select terms_version from public.community_settings
$$;

create or replace function private.accepted_terms(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.terms_version() is null or exists (
    select 1 from private.terms_acceptances t
     where t.user_id = uid and t.version = private.terms_version())
$$;

create or replace function private.accept_terms(uid uuid, p_version text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_version is distinct from private.terms_version() then
    raise exception 'terms_outdated' using errcode = '22023',
      hint = 'Os termos mudaram entretanto. Lê a versão nova e aceita outra vez.';
  end if;
  insert into private.terms_acceptances (user_id, version) values (uid, p_version)
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------- bloqueios

create table if not exists private.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);

create table if not exists private.blocked_accounts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  reason text check (char_length(reason) <= 500),
  blocked_at timestamptz not null default now()
);

alter table private.admins enable row level security;
alter table private.blocked_accounts enable row level security;

create or replace function private.is_admin(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select uid is not null and exists (select 1 from private.admins a where a.user_id = uid)
$$;

create or replace function private.is_blocked(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.blocked_accounts b where b.user_id = uid)
$$;

-- As mesmas regras de antes, mais: uma conta bloqueada não interage.
create or replace function private.can_interact(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select uid is not null and not private.is_blocked(uid) and (
    not coalesce((select members_only from public.community_settings), false)
    or private.is_member(uid)
  )
$$;

create or replace function private.require_interaction(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  if private.is_blocked(uid) then
    raise exception 'account_blocked' using errcode = '42501',
      hint = 'Esta conta foi bloqueada na Comunidade por não cumprir os termos de utilização.';
  end if;
  if not private.can_interact(uid) then
    raise exception 'members_only' using errcode = '42501',
      hint = 'Disponível para membros da Comunidade.';
  end if;
  return uid;
end $$;

-- Quem cria conteúdo tem de poder interagir e ter aceitado os termos.
create or replace function private.check_author()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
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

drop trigger if exists itineraries_author_check on public.itineraries;
create trigger itineraries_author_check
  before insert or update of title, destination, summary, plan on public.itineraries
  for each row execute function private.check_author();
drop trigger if exists comments_author_check on public.comments;
create trigger comments_author_check before insert on public.comments
  for each row execute function private.check_author();

-- Bloqueios pessoais: quem bloqueia deixa de ver quem bloqueou.
create table if not exists public.user_blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
alter table public.user_blocks enable row level security;
drop policy if exists "user_blocks: cada um vê os seus" on public.user_blocks;
create policy "user_blocks: cada um vê os seus" on public.user_blocks
  for select to authenticated using (blocker_id = (select auth.uid()));
drop policy if exists "user_blocks: cada um bloqueia" on public.user_blocks;
create policy "user_blocks: cada um bloqueia" on public.user_blocks
  for insert to authenticated with check (blocker_id = (select auth.uid()));
drop policy if exists "user_blocks: cada um desbloqueia" on public.user_blocks;
create policy "user_blocks: cada um desbloqueia" on public.user_blocks
  for delete to authenticated using (blocker_id = (select auth.uid()));
grant select, insert (blocker_id, blocked_id), delete on public.user_blocks to authenticated;

-- ---------------------------------------------------------------- avaliações

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  itinerary_id uuid not null references public.itineraries (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  stars int check (stars between 1 and 5),
  body text check (char_length(body) between 1 and 2000),
  -- Decide o servidor: a conta fez este itinerário e o GPS confirmou-o.
  verified boolean not null default false,
  hidden boolean not null default false,   -- moderação
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (itinerary_id, author_id),
  check (stars is not null or body is not null)
);
create index if not exists reviews_by_itinerary on public.reviews (itinerary_id, verified desc, updated_at desc);
alter table public.reviews enable row level security;
drop policy if exists "reviews: toda a gente lê as visíveis" on public.reviews;
create policy "reviews: toda a gente lê as visíveis" on public.reviews
  for select to anon, authenticated
  using (
    (not hidden and exists (select 1 from public.itineraries i where i.id = itinerary_id and not i.hidden))
    or author_id = (select auth.uid())
  );
-- Escrever e apagar só pelas funções (review_itinerary, app_review, …).
grant select on public.reviews to anon, authenticated;

alter table public.itineraries add column if not exists review_count int not null default 0;
alter table public.itineraries add column if not exists rating_count int not null default 0;
alter table public.itineraries add column if not exists rating_avg numeric(2,1);
alter table public.itineraries add column if not exists verified_rating_count int not null default 0;
alter table public.itineraries add column if not exists verified_rating_avg numeric(2,1);

create or replace function private.count_reviews()
returns trigger language plpgsql security definer set search_path = '' as $$
declare iid uuid := coalesce(new.itinerary_id, old.itinerary_id);
begin
  update public.itineraries i set
    review_count = s.n, rating_count = s.rn, rating_avg = s.ra,
    verified_rating_count = s.vn, verified_rating_avg = s.va
  from (
    select count(*) as n,
           count(r.stars) as rn, round(avg(r.stars), 1) as ra,
           count(r.stars) filter (where r.verified) as vn,
           round(avg(r.stars) filter (where r.verified), 1) as va
      from public.reviews r where r.itinerary_id = iid and not r.hidden
  ) s
  where i.id = iid;
  return null;
end $$;
drop trigger if exists reviews_count on public.reviews;
create trigger reviews_count after insert or delete or update of stars, verified, hidden on public.reviews
  for each row execute function private.count_reviews();

drop trigger if exists reviews_author_check on public.reviews;
create trigger reviews_author_check before insert or update of stars, body on public.reviews
  for each row execute function private.check_author();

-- Quando uma conclusão sobe para "original" (ou aparece), a avaliação dessa
-- conta passa a contar como de quem fez.
create or replace function private.verify_reviews()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.reviews r
     set verified = exists (select 1 from public.itinerary_completions c
                             where c.itinerary_id = r.itinerary_id and c.user_id = r.author_id
                               and c.evidence = 'original')
   where r.itinerary_id = coalesce(new.itinerary_id, old.itinerary_id)
     and r.author_id = coalesce(new.user_id, old.user_id);
  return null;
end $$;
drop trigger if exists completions_verify_reviews on public.itinerary_completions;
create trigger completions_verify_reviews after insert or update or delete on public.itinerary_completions
  for each row execute function private.verify_reviews();

create or replace function private.write_review(uid uuid, p_itinerary_id uuid, p_stars int, p_body text)
returns table (verified boolean)
language plpgsql security definer set search_path = '' as $$
declare
  b text := nullif(btrim(p_body), '');
  v boolean;
begin
  if not exists (select 1 from public.itineraries where id = p_itinerary_id and not hidden) then
    raise exception 'not_found' using errcode = 'P0002', hint = 'Este itinerário já não está publicado.';
  end if;
  if exists (select 1 from public.itineraries where id = p_itinerary_id and author_id = uid) then
    raise exception 'own_itinerary' using errcode = '22023', hint = 'Não se avalia o próprio itinerário.';
  end if;
  if p_stars is null and b is null then
    raise exception 'review_empty' using errcode = '22023', hint = 'Dá estrelas, escreve um comentário, ou as duas coisas.';
  end if;
  if p_stars is not null and p_stars not between 1 and 5 then
    raise exception 'review_invalid' using errcode = '22023', hint = 'As estrelas vão de 1 a 5.';
  end if;
  if char_length(b) > 2000 then
    raise exception 'review_invalid' using errcode = '22023', hint = 'O comentário tem no máximo 2000 caracteres.';
  end if;
  v := exists (select 1 from public.itinerary_completions c
                where c.itinerary_id = p_itinerary_id and c.user_id = uid and c.evidence = 'original');
  insert into public.reviews as r (itinerary_id, author_id, stars, body, verified)
  values (p_itinerary_id, uid, p_stars, b, v)
  on conflict (itinerary_id, author_id) do update set
    stars = excluded.stars, body = excluded.body, verified = excluded.verified, updated_at = now();
  return query select v;
end $$;

create or replace function private.delete_review(uid uuid, p_itinerary_id uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.reviews where itinerary_id = p_itinerary_id and author_id = uid
$$;

-- -------------------------------------------------------- denúncias (mais)

alter table public.reports add column if not exists review_id uuid references public.reviews (id) on delete cascade;
alter table public.reports add column if not exists resolved_at timestamptz;
alter table public.reports add column if not exists resolution text check (resolution in ('hidden', 'shown', 'dismissed', 'blocked'));
alter table public.reports drop constraint if exists reports_check;
alter table public.reports drop constraint if exists reports_target_check;
alter table public.reports add constraint reports_target_check
  check (itinerary_id is not null or comment_id is not null or review_id is not null);
grant insert (itinerary_id, comment_id, review_id, reason) on public.reports to anon, authenticated;
create index if not exists reports_open on public.reports (created_at desc) where resolved_at is null;

-- ------------------------------------------------------------ na app

create or replace function public.app_terms(p_token text)
returns table (version text, accepted boolean)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select private.terms_version(), private.accepted_terms(uid);
end $$;

create or replace function public.app_accept_terms(p_token text, p_version text)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  perform private.accept_terms(uid, p_version);
end $$;

create or replace function public.app_review(p_token text, p_itinerary_id uuid, p_stars int, p_body text)
returns table (verified boolean)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_interaction(p_token);
begin
  return query select w.verified from private.write_review(uid, p_itinerary_id, p_stars, p_body) w;
end $$;

create or replace function public.app_my_review(p_token text, p_itinerary_id uuid)
returns table (stars int, body text, verified boolean, hidden boolean, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select r.stars, r.body, r.verified, r.hidden, r.updated_at
    from public.reviews r where r.itinerary_id = p_itinerary_id and r.author_id = uid;
end $$;

create or replace function public.app_delete_review(p_token text, p_itinerary_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  perform private.delete_review(uid, p_itinerary_id);
end $$;

-- Preparado para quando a conversa passar para a app.
create or replace function public.app_set_user_block(p_token text, p_user_id uuid, p_blocked boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  if p_blocked then
    if p_user_id = uid then
      raise exception 'self_block' using errcode = '22023', hint = 'Não te podes bloquear a ti.';
    end if;
    insert into public.user_blocks (blocker_id, blocked_id) values (uid, p_user_id) on conflict do nothing;
  else
    delete from public.user_blocks where blocker_id = uid and blocked_id = p_user_id;
  end if;
end $$;

create or replace function public.app_user_blocks(p_token text)
returns setof uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := private.require_user(p_token);
begin
  return query select b.blocked_id from public.user_blocks b where b.blocker_id = uid;
end $$;

-- ------------------------------------------------------------ no site

create or replace function public.my_terms()
returns table (version text, accepted boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  return query select private.terms_version(), private.accepted_terms(auth.uid());
end $$;

create or replace function public.accept_terms(p_version text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  perform private.accept_terms(auth.uid(), p_version);
end $$;

create or replace function public.review_itinerary(p_itinerary_id uuid, p_stars int, p_body text)
returns table (verified boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  if not private.can_interact(auth.uid()) then
    raise exception 'members_only' using errcode = '42501', hint = 'Disponível para membros da Comunidade.';
  end if;
  return query select w.verified from private.write_review(auth.uid(), p_itinerary_id, p_stars, p_body) w;
end $$;

create or replace function public.delete_my_review(p_itinerary_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '28000'; end if;
  perform private.delete_review(auth.uid(), p_itinerary_id);
end $$;

-- ------------------------------------------------------------ moderação

create or replace function private.require_admin()
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin(auth.uid()) then
    raise exception 'not_admin' using errcode = '42501', hint = 'Só para quem modera a Comunidade.';
  end if;
  return auth.uid();
end $$;

create or replace function public.am_i_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_admin(auth.uid())
$$;

-- As denúncias, com o que foi denunciado ao lado. Abertas primeiro.
create or replace function public.admin_reports(p_include_resolved boolean default false)
returns table (
  report_id uuid, reported_at timestamptz, reason text, kind text, target_id uuid,
  itinerary_id uuid, itinerary_title text, excerpt text,
  author_id uuid, author_name text, target_hidden boolean, author_blocked boolean,
  resolved_at timestamptz, resolution text
) language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_admin();
  return query
  select r.id, r.created_at, r.reason,
         case when r.review_id is not null then 'review' when r.comment_id is not null then 'comment' else 'itinerary' end,
         coalesce(r.review_id, r.comment_id, r.itinerary_id),
         coalesce(rv.itinerary_id, c.itinerary_id, r.itinerary_id),
         i.title,
         left(coalesce(rv.body, c.body, i.summary, ''), 280),
         coalesce(rv.author_id, c.author_id, i.author_id),
         p.display_name,
         coalesce(rv.hidden, c.hidden, i.hidden),
         private.is_blocked(coalesce(rv.author_id, c.author_id, i.author_id)),
         r.resolved_at, r.resolution
    from public.reports r
    left join public.reviews rv on rv.id = r.review_id
    left join public.comments c on c.id = r.comment_id
    left join public.itineraries i on i.id = coalesce(rv.itinerary_id, c.itinerary_id, r.itinerary_id)
    left join public.profiles p on p.id = coalesce(rv.author_id, c.author_id, i.author_id)
   where p_include_resolved or r.resolved_at is null
   order by (r.resolved_at is null) desc, r.created_at desc
   limit 200;
end $$;

create or replace function public.admin_set_hidden(p_kind text, p_id uuid, p_hidden boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare res text := case when p_hidden then 'hidden' else 'shown' end;
begin
  perform private.require_admin();
  if p_kind = 'itinerary' then
    update public.itineraries set hidden = p_hidden where id = p_id;
  elsif p_kind = 'comment' then
    update public.comments set hidden = p_hidden where id = p_id;
  elsif p_kind = 'review' then
    update public.reviews set hidden = p_hidden where id = p_id;
  else
    raise exception 'kind_invalid' using errcode = '22023';
  end if;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  update public.reports set resolved_at = now(), resolution = res
   where resolved_at is null and case p_kind
     when 'itinerary' then itinerary_id = p_id and comment_id is null and review_id is null
     when 'comment' then comment_id = p_id
     else review_id = p_id end;
end $$;

create or replace function public.admin_dismiss_report(p_report_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  update public.reports set resolved_at = now(), resolution = 'dismissed'
   where id = p_report_id and resolved_at is null;
end $$;

-- Bloquear esconde tudo o que a conta escreveu; desbloquear não volta a mostrar
-- (isso decide-se caso a caso).
create or replace function public.admin_set_blocked(p_user_id uuid, p_blocked boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_admin();
  if p_blocked then
    if private.is_admin(p_user_id) then
      raise exception 'self_block' using errcode = '22023', hint = 'Não se bloqueia quem modera.';
    end if;
    insert into private.blocked_accounts (user_id, reason) values (p_user_id, left(p_reason, 500))
    on conflict (user_id) do update set reason = excluded.reason;
    update public.itineraries set hidden = true where author_id = p_user_id;
    update public.comments set hidden = true where author_id = p_user_id;
    update public.reviews set hidden = true where author_id = p_user_id;
    update public.reports r set resolved_at = now(), resolution = 'blocked'
     where r.resolved_at is null and (
       exists (select 1 from public.itineraries i where i.id = r.itinerary_id and i.author_id = p_user_id and r.comment_id is null and r.review_id is null)
       or exists (select 1 from public.comments c where c.id = r.comment_id and c.author_id = p_user_id)
       or exists (select 1 from public.reviews v where v.id = r.review_id and v.author_id = p_user_id));
  else
    delete from private.blocked_accounts where user_id = p_user_id;
  end if;
end $$;

-- ------------------------------------------------------------ permissões

revoke execute on all functions in schema private from public, anon, authenticated;
-- As regras de acesso (RLS) chamam estas duas; as outras só pelas funções.
grant execute on function private.can_interact(uuid) to authenticated;
grant execute on function private.plan_role(uuid, uuid) to authenticated;

revoke execute on function
  public.app_terms(text), public.app_accept_terms(text, text),
  public.app_review(text, uuid, int, text), public.app_my_review(text, uuid),
  public.app_delete_review(text, uuid),
  public.app_set_user_block(text, uuid, boolean), public.app_user_blocks(text),
  public.my_terms(), public.accept_terms(text),
  public.review_itinerary(uuid, int, text), public.delete_my_review(uuid),
  public.am_i_admin(), public.admin_reports(boolean), public.admin_set_hidden(text, uuid, boolean),
  public.admin_dismiss_report(uuid), public.admin_set_blocked(uuid, boolean, text)
  from public, anon, authenticated;
-- A app não tem sessão: fala como anon, com a chave da ligação.
grant execute on function
  public.app_terms(text), public.app_accept_terms(text, text),
  public.app_review(text, uuid, int, text), public.app_my_review(text, uuid),
  public.app_delete_review(text, uuid),
  public.app_set_user_block(text, uuid, boolean), public.app_user_blocks(text)
  to anon, authenticated;
grant execute on function
  public.my_terms(), public.accept_terms(text),
  public.review_itinerary(uuid, int, text), public.delete_my_review(uuid),
  public.am_i_admin(), public.admin_reports(boolean), public.admin_set_hidden(text, uuid, boolean),
  public.admin_dismiss_report(uuid), public.admin_set_blocked(uuid, boolean, text)
  to authenticated;
