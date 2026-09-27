#!/usr/bin/env bash
# Testa 001_community.sql num Postgres 16 local que imita o Supabase.
# Uso: sudo bash supabase/test/run.sh   (precisa do utilizador postgres)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=/var/tmp/pgsb; PORT=5499
if [ ! -d $S/data ]; then
  mkdir -p $S && chown postgres $S
  su postgres -c "/usr/lib/postgresql/16/bin/initdb -D $S/data -A trust >/dev/null"
fi
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $S/data -o '-p $PORT -k $S' -l $S/log status >/dev/null || /usr/lib/postgresql/16/bin/pg_ctl -D $S/data -o '-p $PORT -k $S' -l $S/log start >/dev/null"
cp "$HERE/supabase-shim.sql" "$HERE/../001_community.sql" "$HERE/../002_names.sql" "$HERE/../003_originals_and_replies.sql" "$HERE/../004_budget_and_photos.sql" "$HERE/../005_shared_plans.sql" $S/ && chmod 644 $S/*.sql
PSQL="psql -h $S -p $PORT -U postgres"
su postgres -c "$PSQL -qc 'drop database if exists sb' -c 'create database sb'"
su postgres -c "$PSQL -d sb -q -v ON_ERROR_STOP=1 -f $S/supabase-shim.sql -f $S/001_community.sql -f $S/002_names.sql -f $S/003_originals_and_replies.sql -f $S/004_budget_and_photos.sql -f $S/005_shared_plans.sql -f $S/001_community.sql -f $S/002_names.sql -f $S/003_originals_and_replies.sql -f $S/004_budget_and_photos.sql -f $S/005_shared_plans.sql" 2>&1 | grep -v NOTICE

FAILS=0
q() { local role=$1 sub=$2; shift 2
  su postgres -c "$PSQL -d sb -X -q -t -A" <<SQL 2>&1 | sed 's/^psql:<stdin>:[0-9]*: //' | grep -v "^CONTEXT\|^PL/pgSQL\|^LINE\|^ *\^\|^HINT" | tr '\n' ' ' | sed 's/ *$//'
begin; set local role $role; set local "request.jwt.claim.sub" = '$sub'; $*; commit;
SQL
}
adm() { su postgres -c "$PSQL -d sb -tAq -c \"$1\""; }
# expect <description> <pattern> <actual>
expect() { if [[ "$3" =~ $2 ]]; then echo "ok   $1"; else echo "FAIL $1 — got: $3"; FAILS=$((FAILS+1)); fi; }

A=$(adm "insert into auth.users(email) values ('a@example.org') returning id" | head -1)
B=$(adm "insert into auth.users(email) values ('b@example.org') returning id" | head -1)
expect "perfis recebem um nome da lista" '^2$' "$(adm 'select count(*) from public.profiles p join public.name_pool n on n.name = p.display_name and n.taken_by = p.id')"
expect "ninguém muda o próprio nome" 'permission denied' "$(q authenticated $A "update public.profiles set display_name = 'Eu Mesmo' where id = '$A'")"
expect "a lista não se lê pela API" 'permission denied|^0$' "$(q anon '' 'select count(*) from public.name_pool')"
CH=$(q authenticated $A "select array_to_string(names, '|') from public.my_name_choices()")
expect "4 nomes propostos para o próximo" '^[^|]+\|[^|]+\|[^|]+\|[^|]+$' "$CH"
expect "as propostas não mudam ao recarregar" "^$CH\$" "$(q authenticated $A "select array_to_string(names, '|') from public.my_name_choices()")"
GIFT=${CH%%|*}
expect "não se escolhe um nome não proposto" 'name_not_offered' "$(q authenticated $A "select public.give_next_name('Nome Inventado')")"
expect "escolher o nome do próximo" "^$GIFT\$" "$(q authenticated $A "select public.give_next_name('$GIFT')")"
expect "só uma vez" 'name_not_offered' "$(q authenticated $A "select public.give_next_name('${CH##*|}')")"
C=$(adm "insert into auth.users(email) values ('c@example.org') returning id" | head -1)
expect "o próximo recebe o nome deixado, e sabe por quem" "^$GIFT\|" "$(q anon '' "select p.display_name||'|'||g.display_name from public.profiles p join public.profiles g on g.id = p.named_by where p.id = '$C'")"
expect "anon não pede propostas do site" 'permission denied' "$(q anon '' 'select * from public.my_name_choices()')"

R=$(q anon "" "select request_id||' '||secret from public.app_begin_link('Poco X5')"); RID=${R%% *}; SEC=${R##* }
expect "pedido de ligação com segredo de 64" '^[0-9a-f]{64}$' "$SEC"
expect "anon não lê pedidos" 'permission denied' "$(q anon '' 'select count(*) from private.app_link_requests')"
expect "anon não confirma" 'permission denied' "$(q anon '' "select public.confirm_app_link('$RID')")"
expect "o site vê o nome do telemóvel" 'Poco X5' "$(q authenticated $A "select device_label from public.get_app_link_request('$RID')")"
expect "trocar antes de confirmar falha" 'not_confirmed' "$(q anon '' "select token from public.app_redeem_link('$RID','$SEC')")"
expect "A confirma" 'Poco X5' "$(q authenticated $A "select public.confirm_app_link('$RID')")"
expect "B não confirma o mesmo pedido" 'request_invalid' "$(q authenticated $B "select public.confirm_app_link('$RID')")"
expect "segredo errado falha" 'request_invalid' "$(q anon '' "select token from public.app_redeem_link('$RID','$(printf '0%.0s' {1..64})')")"
TOK=$(q anon "" "select token from public.app_redeem_link('$RID','$SEC')")
expect "a app recebe a chave" '^[0-9a-f]{64}$' "$TOK"
expect "o pedido só se troca uma vez" 'request_invalid' "$(q anon '' "select token from public.app_redeem_link('$RID','$SEC')")"
expect "whoami" '^[^|]+ [^|]+\|false\|true$' "$(q anon '' "select display_name||'|'||member||'|'||can_interact from public.app_whoami('$TOK')")"

IID=$(q anon "" "select public.app_publish('$TOK','Gerês 3 dias','Gerês','Cascatas',3,9,'2026-09','{\"type\":\"trip_plan\"}'::jsonb,'trip-1')")
expect "publicar" '^[0-9a-f-]{36}$' "$IID"
expect "voltar a publicar atualiza o mesmo" '^t$' "$(q anon '' "select public.app_publish('$TOK','Gerês 3 dias v2','Gerês','',3,10,'2026-09','{}'::jsonb,'trip-1') = '$IID'")"
expect "feed sem conta" '^Gerês 3 dias v2\|0\|[^|]+ [^|]+$' "$(q anon '' "select i.title||'|'||i.like_count||'|'||p.display_name from public.itineraries i join public.profiles p on p.id = i.author_id")"
expect "anon não escreve direto" 'permission denied' "$(q anon '' "insert into public.itineraries(author_id,title,day_count,stop_count,plan) values ('$A','x',1,1,'{}')")"
expect "B não publica em nome de A" 'row-level security|permission denied' "$(q authenticated $B "insert into public.itineraries(author_id,title,day_count,stop_count,plan) values ('$A','x',1,1,'{}')")"
expect "ninguém mexe nos contadores" 'permission denied' "$(q authenticated $B 'update public.itineraries set like_count = 999')"
expect "chave inválida" 'link_invalid' "$(q anon '' "select public.app_set_like('$(printf 'a%.0s' {1..64})','$IID',true)")"
expect "like duas vezes conta um" '^1 1$' "$(q anon '' "select public.app_set_like('$TOK','$IID',true); select public.app_set_like('$TOK','$IID',true)")"
expect "a app sabe o que já gostou" '^1$' "$(q anon '' "select count(*) from public.app_liked('$TOK', array['$IID']::uuid[])")"
expect "tirar o like" '^0$' "$(q anon '' "select public.app_set_like('$TOK','$IID',false)")"
expect "comentar" '^t$' "$(q anon '' "select public.app_comment('$TOK','$IID','Que bom roteiro') is not null")"
expect "comentário vazio recusado" 'check constraint' "$(q anon '' "select public.app_comment('$TOK','$IID','   ')")"
expect "comentários e contador públicos" '^Que bom roteiro 1$' "$(q anon '' 'select body from public.comments; select comment_count from public.itineraries')"
expect "denunciar sem conta" '^ok$' "$(q anon '' "insert into public.reports(itinerary_id, reason) values ('$IID','spam'); select 'ok'")"
expect "denúncia não se faz passar por outro" 'permission denied|row-level' "$(q anon '' "insert into public.reports(itinerary_id, reason, reporter_id) values ('$IID','spam','$A')")"
expect "denúncias não se leem" 'permission denied' "$(q anon '' 'select count(*) from public.reports')"
expect "ligações não se leem sem conta" 'permission denied' "$(q anon '' 'select count(*) from public.app_links')"
expect "cada um vê as suas ligações" '^Poco X5 0$' "$(q authenticated $A 'select device_label from public.app_links') $(q authenticated $B 'select count(*) from public.app_links')"
expect "membros não se leem sem conta" 'permission denied' "$(q anon '' 'select count(*) from public.memberships')"

BR=$(q anon "" "select request_id||' '||secret from public.app_begin_link('Outro')"); q authenticated $B "select public.confirm_app_link('${BR%% *}')" >/dev/null
BTOK=$(q anon "" "select token from public.app_redeem_link('${BR%% *}','${BR##* }')")
expect "B não despublica o de A" '^ *1$' "$(q anon '' "select public.app_unpublish('$BTOK','$IID'); select count(*) from public.itineraries")"
expect "B não apaga comentários de A" '^1$' "$(q authenticated $B 'delete from public.comments; select count(*) from public.comments')"
expect "o autor do itinerário modera comentários" '^0$' "$(q authenticated $A 'delete from public.comments; select count(*) from public.comments')"

OID=$(q anon "" "select id from public.app_publish_v2('$TOK','Douro a pé','Douro','',2,4,'2026-08','{}'::jsonb,'trip-o', 4, 3, 150, 'test')")
expect "prova boa dá original" 'original' "$(q anon '' "select evidence from public.itineraries where source_trip_id = 'trip-o'")"
expect "o servidor não aceita mais GPS do que visitas" 'done' "$(q anon '' "select evidence from public.app_publish_v2('$TOK','Douro a pé','Douro','',2,4,'2026-08','{}'::jsonb,'trip-o', 1, 9, 150, 'test')")"
expect "sem nada registado é roteiro" 'plan' "$(q anon '' "select evidence from public.app_publish_v2('$TOK','Só plano','','',1,4,null,'{}'::jsonb,'trip-p', 0, 0, 0, 'test')")"
q anon "" "select public.app_publish_v2('$TOK','Douro a pé','Douro','',2,4,'2026-08','{}'::jsonb,'trip-o', 4, 3, 150, 'test')" >/dev/null
expect "a publicação antiga tira o selo de original" 'plan' "$(q anon '' "select public.app_publish('$TOK','Douro','Douro','',2,4,'2026-08','{}'::jsonb,'trip-o'); select evidence from public.itineraries where source_trip_id = 'trip-o'" | awk '{print $2}')"
q anon "" "select public.app_publish_v2('$TOK','Douro a pé','Douro','',2,4,'2026-08','{}'::jsonb,'trip-o', 4, 3, 150, 'test')" >/dev/null
expect "o autor não muda a prova pelo site" 'permission denied' "$(q authenticated $A "update public.itineraries set evidence = 'original', gps_stops = 99 where author_id = '$A'")"
expect "não se regista como feita a própria viagem" 'own_itinerary' "$(q anon '' "select public.app_record_completion('$TOK','$OID', 3, 3, 100)")"
expect "B fez a viagem de A, confirmada por GPS" '^original$' "$(q anon '' "select public.app_record_completion('$BTOK','$OID', 4, 4, 200)")"
expect "uma segunda vez não desce de nível" '^done$' "$(q anon '' "select public.app_record_completion('$BTOK','$OID', 1, 0, 0)")"
expect "contadores de feita por" '^1\|1$' "$(q anon '' "select done_count||'|'||original_done_count from public.itineraries where id = '$OID'")"
expect "ninguém regista uma viagem sem nada feito" 'nothing_done' "$(q anon '' "select public.app_record_completion('$BTOK','$OID', 0, 0, 0)")"
C1=$(q anon "" "select public.app_comment_v2('$TOK','$OID','Onde estacionaram?', null)")
R1=$(q anon "" "select public.app_comment_v2('$BTOK','$OID','No largo da igreja.', '$C1')")
R2=$(q anon "" "select public.app_comment_v2('$TOK','$OID','Obrigado!', '$R1')")
expect "respostas ficam num nível só" "^$C1\$" "$(q anon '' "select parent_id from public.comments where id = '$R2'")"
expect "não se responde noutro itinerário" 'reply_invalid' "$(q anon '' "select public.app_comment_v2('$TOK','$IID','x', '$C1')")"
expect "like num comentário conta um" '^1 1$' "$(q anon '' "select public.app_set_comment_like('$BTOK','$C1',true); select public.app_set_comment_like('$BTOK','$C1',true)")"
expect "a app sabe de que comentários gostou" '^1$' "$(q anon '' "select count(*) from public.app_liked_comments('$BTOK', array['$C1']::uuid[])")"
expect "o site responde com sessão" '^t$' "$(q authenticated $B "insert into public.comments(itinerary_id, author_id, body, parent_id) values ('$OID','$B','Pelo site','$C1'); select true")"
expect "feita por lê-se sem conta" '^1$' "$(q anon '' "select count(*) from public.itinerary_completions where itinerary_id = '$OID'")"
expect "orçamento numa margem" '^250-400$' "$(q anon '' "select public.app_set_budget('$TOK','$OID',250,400); select budget_min||'-'||budget_max from public.itineraries where id = '$OID'" | tr -d ' ')"
expect "mínimo acima do máximo recusado" 'budget_invalid' "$(q anon '' "select public.app_set_budget('$TOK','$OID',500,100)")"
expect "só um dos valores recusado" 'budget_invalid' "$(q anon '' "select public.app_set_budget('$TOK','$OID',100,null)")"
expect "B não mexe no orçamento de A" 'not_yours' "$(q anon '' "select public.app_set_budget('$BTOK','$OID',1,2)")"
expect "tirar o orçamento" '^t$' "$(q anon '' "select public.app_set_budget('$TOK','$OID',null,null); select budget_min is null from public.itineraries where id = '$OID'" | tr -d ' ')"
expect "B não pede bilhete para fotos de A" 'not_yours' "$(q anon '' "select public.app_photo_ticket('$BTOK','$OID')")"
TK=$(q anon "" "select public.app_photo_ticket('$TOK','$OID')")
expect "bilhete para fotos" '^[0-9a-f-]{36}$' "$TK"
expect "sem bilhete não se envia" 'row-level security' "$(q anon '' "insert into storage.objects(bucket_id,name) values ('itinerary-photos','$(cat /proc/sys/kernel/random/uuid)/1.jpg')")"
expect "nome fora da regra recusado" 'row-level security' "$(q anon '' "insert into storage.objects(bucket_id,name) values ('itinerary-photos','$TK/7.jpg')")"
expect "noutro bucket recusado" 'row-level security|foreign key' "$(q anon '' "insert into storage.objects(bucket_id,name) values ('outro','$TK/1.jpg')")"
expect "com bilhete envia" '^ok$' "$(q anon '' "insert into storage.objects(bucket_id,name) values ('itinerary-photos','$TK/1.jpg'),('itinerary-photos','$TK/2.jpg'); select 'ok'")"
expect "fotos que não chegaram recusadas" 'photo_missing' "$(q anon '' "select public.app_set_photos('$TOK','$OID','$TK',3)")"
expect "B não usa o bilhete de A" 'not_yours' "$(q anon '' "select public.app_set_photos('$BTOK','$OID','$TK',2)")"
expect "as fotos ficam no itinerário, à vista de todos" "^2 $TK/1.jpg\$" "$(q anon '' "select public.app_set_photos('$TOK','$OID','$TK',2)" >/dev/null; q anon '' "select cardinality(photos)||' '||photos[1] from public.itineraries where id = '$OID'")"
expect "sete fotos recusadas" 'photos_invalid' "$(q anon '' "select public.app_set_photos('$TOK','$OID','$TK',7)")"
adm "update private.photo_tickets set created_at = now() - interval '2 hours'"
expect "bilhete expirado não envia" 'row-level security' "$(q anon '' "insert into storage.objects(bucket_id,name) values ('itinerary-photos','$TK/3.jpg')")"
expect "ninguém muda as fotos pelo site" 'permission denied' "$(q authenticated $A "update public.itineraries set photos = '{}' where author_id = '$A'")"
adm "update public.community_settings set members_only = true"
expect "só membros: quem não é, não publica" 'members_only' "$(q anon '' "select public.app_publish('$TOK','t','d','s',1,1,null,'{}'::jsonb,'trip-2')")"
adm "insert into public.memberships(user_id) values ('$A')"
expect "só membros: membro publica" '^t$' "$(q anon '' "select public.app_publish('$TOK','t','d','s',1,1,null,'{}'::jsonb,'trip-2') is not null")"
expect "whoami diz membro" '\|true\|true$' "$(q anon '' "select display_name||'|'||member||'|'||can_interact from public.app_whoami('$TOK')")"
adm "update public.memberships set valid_until = now() - interval '1 day'"
expect "membro expirado deixa de o ser" '\|false\|false$' "$(q anon '' "select display_name||'|'||member||'|'||can_interact from public.app_whoami('$TOK')")"
adm "update public.community_settings set members_only = false"

# ---------------------------------------------------------- planos partilhados
adm "delete from public.memberships; insert into public.memberships(user_id) values ('$A')"
expect "quem não é membro não partilha" 'members_only' "$(q anon '' "select * from public.app_share_plan('$BTOK','Plano',  'c1', '[]'::jsonb)")"
SP=$(q anon "" "select plan_id from public.app_share_plan('$TOK','Algarve com amigos','dev-a','[{\"key\":\"trip:trip:name\",\"value\":\"Algarve\"},{\"key\":\"stop:s1:name\",\"value\":\"Sagres\"},{\"key\":\"stop:s1:durationMin\",\"value\":60}]'::jsonb)")
expect "o membro partilha um plano" '^[0-9a-f-]{36}$' "$SP"
expect "os campos ficam com revisões" '^3$' "$(q anon '' "select count(*) from public.app_plan_fields_since('$TOK','$SP',0)")"
expect "quem não está no plano não lê pela app" 'not_in_plan' "$(q anon '' "select * from public.app_plan_fields_since('$BTOK','$SP',0)")"
expect "quem não está no plano não lê pelo site" '^0$' "$(q authenticated $B "select count(*) from public.shared_plan_fields where plan_id = '$SP'")"
expect "anon não lê campos" 'permission denied' "$(q anon '' "select count(*) from public.shared_plan_fields")"
expect "ninguém escreve direto na tabela" 'permission denied' "$(q authenticated $A "insert into public.shared_plan_fields(plan_id,key,value,rev) values ('$SP','stop:x:name','\"x\"',1)")"
expect "chave de campo inválida recusada" 'fields_invalid' "$(q anon '' "select public.app_write_plan_fields('$TOK','$SP','dev-a','[{\"key\":\"drop table\",\"value\":1}]'::jsonb)")"
R0=$(q anon "" "select max(rev) from public.app_plan_fields_since('$TOK','$SP',0)")
CODE=$(q anon "" "select public.app_plan_invite('$TOK','$SP')")
expect "convite com 12 caracteres" '^[a-z2-9]{12}$' "$CODE"
expect "não membro não aceita convite" 'members_only' "$(q authenticated $B "select public.accept_plan_invite('$CODE')")"
adm "insert into public.memberships(user_id) values ('$B')"
expect "o convite mostra o plano e quem convida" '^Algarve\|' "$(q authenticated $B "select title||'|'||owner_name||'|'||already from public.plan_invite_info('$CODE')")"
expect "B aceita o convite" "^$SP\$" "$(q authenticated $B "select public.accept_plan_invite('$CODE')")"
expect "convite inventado recusado" 'invite_invalid' "$(q authenticated $B "select public.accept_plan_invite('zzzzzzzzzzzz')")"
expect "B vê o plano na app" '^Algarve\|editor\|2$' "$(q anon '' "select title||'|'||role||'|'||member_count from public.app_my_shared_plans('$BTOK')")"
expect "B, no site, muda a duração" '^[0-9]+$' "$(q authenticated $B "select public.write_plan_fields('$SP','web-b','[{\"key\":\"stop:s1:durationMin\",\"value\":90}]'::jsonb)")"
expect "A, na app, só recebe o que mudou depois" '^stop:s1:durationMin 90 web-b$' "$(q anon '' "select key||' '||value||' '||client_id from public.app_plan_fields_since('$TOK','$SP',$R0)")"
q anon "" "select public.app_write_plan_fields('$TOK','$SP','dev-a','[{\"key\":\"stop:s1:name\",\"value\":\"Sagres, o cabo\"}]'::jsonb)" >/dev/null
q authenticated $B "select public.write_plan_fields('$SP','web-b','[{\"key\":\"stop:s1:name\",\"value\":\"Cabo de São Vicente\"}]'::jsonb)" >/dev/null
expect "no mesmo campo, fica a última escrita" '^"Cabo de São Vicente"$' "$(q authenticated $A "select value from public.shared_plan_fields where plan_id = '$SP' and key = 'stop:s1:name'")"
expect "campos diferentes não se estragam" '^90$' "$(q authenticated $A "select value from public.shared_plan_fields where plan_id = '$SP' and key = 'stop:s1:durationMin'")"
expect "apagar é escrever deleted" '^true$' "$(q anon '' "select public.app_write_plan_fields('$TOK','$SP','dev-a','[{\"key\":\"stop:s1:deleted\",\"value\":true}]'::jsonb)" >/dev/null; q authenticated $B "select value from public.shared_plan_fields where plan_id = '$SP' and key = 'stop:s1:deleted'")"
expect "mudar o nome da viagem muda o nome do plano" '^Algarve e Alentejo$' "$(q anon '' "select public.app_write_plan_fields('$TOK','$SP','dev-a','[{\"key\":\"trip:trip:name\",\"value\":\"Algarve e Alentejo\"}]'::jsonb)" >/dev/null; q anon '' "select title from public.app_my_shared_plans('$TOK')")"
expect "a app vê quem está no plano" '^2$' "$(q anon '' "select count(*) from public.app_plan_members('$TOK','$SP')")"
expect "a app sabe qual dos membros é quem pergunta" '^owner$' "$(q anon '' "select role from public.app_plan_members('$TOK','$SP') where is_me")"
expect "B sai do plano" '^0$' "$(q authenticated $B "select public.leave_plan('$SP')" >/dev/null; q anon '' "select count(*) from public.app_my_shared_plans('$BTOK')")"
expect "quem não está no plano não vê os membros" 'not_in_plan' "$(q anon '' "select * from public.app_plan_members('$BTOK','$SP')")"
expect "B volta a entrar pela app com o código" "^$SP\$" "$(q anon '' "select public.app_accept_plan_invite('$BTOK',upper('$CODE'))")"
expect "o dono apaga o plano ao sair" '^0$' "$(q anon '' "select public.app_leave_plan('$TOK','$SP')" >/dev/null; adm "select count(*) from public.shared_plans")"
adm "delete from public.memberships"

adm "update public.itineraries set hidden = true where id = '$IID'"
expect "escondido some do feed" '^0$' "$(q anon '' "select count(*) from public.itineraries where id = '$IID'")"
expect "o autor ainda o vê" '^1$' "$(q authenticated $A "select count(*) from public.itineraries where id = '$IID'")"
expect "desligar invalida a chave" 'link_invalid' "$(q anon '' "select public.app_unlink('$TOK')" >/dev/null; q anon '' "select * from public.app_whoami('$TOK')")"
expect "anon não apaga contas" 'permission denied' "$(q anon '' 'select public.delete_my_account()')"
q authenticated $A "select public.delete_my_account()" >/dev/null
expect "apagar a conta leva tudo" '^0 2$' "$(q anon '' 'select count(*) from public.itineraries; select count(*) from public.profiles')"

echo; [ $FAILS -eq 0 ] && echo "Tudo certo." || { echo "$FAILS falhas."; exit 1; }
