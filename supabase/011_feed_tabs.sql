-- Comunidade Plan-ish — esquema 11: separadores do feed.
--
-- Correr depois dos esquemas 1 a 10. Pode correr mais do que uma vez.
--
-- Uma página do feed, por separador:
--   popular  o que teve mais gostos e mais "feita por" nos últimos 30 dias
--            (a app não diz ao servidor quem copia um itinerário: quem o faz
--            depois e o regista em itinerary_completions é o sinal que há);
--            empata pelos gostos de sempre e depois pelo mais recente;
--   recent   o mais recente primeiro;
--   mine     os meus e os que gostei (só com sessão; sem sessão, vazio).
-- Os filtros de antes continuam: o nível da prova (original, done, plan) e a
-- procura no título ou no destino.
--
-- Como a leitura direta da tabela: nunca o que a moderação escondeu. E, com
-- sessão, nunca o que publicou quem a pessoa bloqueou.
--
-- Devolve linhas de public.itineraries, por isso o site pede as colunas e o
-- autor como antes: rpc('feed_page', …).select('…, author:profiles!…(display_name)').

create index if not exists likes_recent on public.likes (itinerary_id, created_at);
create index if not exists itinerary_completions_recent on public.itinerary_completions (itinerary_id, completed_at);

create or replace function public.feed_page(
  p_tab text default 'popular',
  p_level text default null,
  p_search text default null,
  p_offset int default 0,
  p_limit int default 20
) returns setof public.itineraries
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  tab text := coalesce(nullif(btrim(p_tab), ''), 'popular');
  lvl text := nullif(btrim(p_level), '');
  words text := nullif(lower(btrim(left(p_search, 60))), '');
  lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
  off int := least(greatest(coalesce(p_offset, 0), 0), 5000);
begin
  if tab not in ('popular', 'recent', 'mine') then
    raise exception 'tab_invalid' using errcode = '22023';
  end if;
  if tab = 'mine' and uid is null then return; end if;
  return query
    select i.*
      from public.itineraries i
     where not i.hidden
       and (lvl is null or i.evidence = lvl)
       and (words is null
            or strpos(lower(i.title), words) > 0
            or strpos(lower(coalesce(i.destination, '')), words) > 0)
       and (uid is null or not exists (
             select 1 from public.user_blocks b where b.blocker_id = uid and b.blocked_id = i.author_id))
       and (tab <> 'mine' or i.author_id = uid or exists (
             select 1 from public.likes l where l.itinerary_id = i.id and l.user_id = uid))
     order by
       case when tab = 'popular' then
         (select count(*) from public.likes l
           where l.itinerary_id = i.id and l.created_at > now() - interval '30 days')
         + (select count(*) from public.itinerary_completions c
             where c.itinerary_id = i.id and c.completed_at > now() - interval '30 days')
       end desc nulls last,
       case when tab = 'popular' then i.like_count end desc nulls last,
       i.created_at desc, i.id desc
     offset off limit lim;
end $$;

revoke execute on function public.feed_page(text, text, text, int, int) from public, anon, authenticated;
grant execute on function public.feed_page(text, text, text, int, int) to anon, authenticated;
