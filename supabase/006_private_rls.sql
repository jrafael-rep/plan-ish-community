-- Comunidade Plan-ish — esquema 6: regras de acesso também nas tabelas privadas.
--
-- Correr depois dos esquemas 1 a 5. Pode correr mais do que uma vez.
--
-- O esquema private não está exposto pela API e ninguém tem permissão para o
-- ler; só as funções do servidor lhe tocam, e essas correm como dono das
-- tabelas, que não é travado pelas regras. Ligar o RLS sem regras nenhumas é
-- uma porta a mais fechada, caso alguma dessas permissões mude um dia.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'private' and not rowsecurity loop
    execute format('alter table private.%I enable row level security', t.tablename);
  end loop;
end $$;
