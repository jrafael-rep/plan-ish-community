-- Comunidade Plan-ish — esquema 9: selos do registo real de uma viagem.
--
-- Correr depois dos esquemas 1 a 8. Pode correr mais do que uma vez.
--
-- Quando uma viagem acaba, a app pode "selar" o registo real (o percurso GPS
-- e as horas reais): calcula no telemóvel uma impressão digital SHA-256 desse
-- registo e, se estiver ligada a uma conta, manda para aqui SÓ essa impressão.
-- O servidor guarda a impressão, a conta e a data em que a recebeu pela
-- primeira vez. Nada mais: nem GPS, nem horas, nem o id da viagem, nem o
-- itinerário. A partir de uma impressão não se recupera o registo.
--
-- Serve para, mais tarde, a pessoa mostrar que o registo que tem no telemóvel
-- já existia naquela data: quem tiver o registo calcula a impressão e pergunta
-- a data (seal_check). Quem não o tiver não aprende nada.
--
-- Regras:
--   * o primeiro registo ganha: registar outra vez a mesma impressão, por
--     quem quer que seja, devolve a data original e não a muda;
--   * no máximo 50 impressões novas por conta em 24 horas, para não gastar os
--     limites do Supabase;
--   * perguntar a data não pede conta e não diz de quem é o selo;
--   * apagar a conta apaga os seus selos.

-- ------------------------------------------------------------------ selos

create table if not exists private.record_seals (
  hash text primary key check (hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references auth.users (id) on delete cascade,
  sealed_at timestamptz not null default now()
);
create index if not exists record_seals_by_user on private.record_seals (user_id, sealed_at desc);
alter table private.record_seals enable row level security;

-- A impressão como a app a manda: 64 caracteres hexadecimais. Aceita
-- maiúsculas e espaços à volta; guarda sempre em minúsculas.
create or replace function private.seal_hash(p_hash text)
returns text language plpgsql immutable set search_path = '' as $$
declare h text := lower(btrim(coalesce(p_hash, '')));
begin
  if h !~ '^[0-9a-f]{64}$' then
    raise exception 'seal_invalid' using errcode = '22023',
      hint = 'A impressão do registo tem de ser um SHA-256 em hexadecimal (64 caracteres).';
  end if;
  return h;
end $$;

-- A app, ligada a uma conta, sela um registo. Devolve a data do selo: a de
-- agora se é novo, a original se a impressão já cá estava.
create or replace function public.app_register_seal(p_token text, p_hash text)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := private.require_user(p_token);
  h text := private.seal_hash(p_hash);
  sealed timestamptz;
begin
  select s.sealed_at into sealed from private.record_seals s where s.hash = h;
  if sealed is not null then return sealed; end if;
  -- Uma conta de cada vez, para o limite não se contornar com pedidos em paralelo.
  perform pg_advisory_xact_lock(hashtextextended('record_seals:' || uid::text, 0));
  if (select count(*) from private.record_seals s
       where s.user_id = uid and s.sealed_at > now() - interval '24 hours') >= 50 then
    raise exception 'seal_limit' using errcode = '54000',
      hint = 'Já selaste muitos registos hoje. Tenta outra vez amanhã.';
  end if;
  insert into private.record_seals (hash, user_id) values (h, uid)
  on conflict (hash) do nothing
  returning sealed_at into sealed;
  if sealed is null then
    -- Outra conta selou a mesma impressão no mesmo instante: ganhou ela.
    select s.sealed_at into sealed from private.record_seals s where s.hash = h;
  end if;
  return sealed;
end $$;

-- Qualquer pessoa, com ou sem conta: a data do selo desta impressão, ou null.
create or replace function public.seal_check(p_hash text)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select s.sealed_at from private.record_seals s where s.hash = lower(btrim(p_hash))
$$;

-- ------------------------------------------------------------ permissões

revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_interact(uuid) to authenticated;
grant execute on function private.plan_role(uuid, uuid) to authenticated;

revoke execute on function public.app_register_seal(text, text), public.seal_check(text)
  from public, anon, authenticated;
-- A app não tem sessão: fala como anon, com a chave da ligação.
grant execute on function public.app_register_seal(text, text), public.seal_check(text)
  to anon, authenticated;
