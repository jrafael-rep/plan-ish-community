#!/usr/bin/env bash
# Testa os esquemas (001 a 015) num Postgres 16 local que imita o Supabase.
# Uso: sudo bash supabase/test/run.sh   (precisa do utilizador postgres)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=/var/tmp/pgsb; PORT=5499
if [ ! -d $S/data ]; then
  mkdir -p $S && chown postgres $S
  su postgres -c "/usr/lib/postgresql/16/bin/initdb -D $S/data -A trust >/dev/null"
fi
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $S/data -o '-p $PORT -k $S' -l $S/log status >/dev/null || /usr/lib/postgresql/16/bin/pg_ctl -D $S/data -o '-p $PORT -k $S' -l $S/log start >/dev/null"
cp "$HERE/supabase-shim.sql" "$HERE/../001_community.sql" "$HERE/../002_names.sql" "$HERE/../003_originals_and_replies.sql" "$HERE/../004_budget_and_photos.sql" "$HERE/../005_shared_plans.sql" "$HERE/../006_private_rls.sql" "$HERE/../007_reviews_terms_moderation.sql" "$HERE/../008_withdraw_and_photo_cleanup.sql" "$HERE/../009_record_seals.sql" "$HERE/../010_points.sql" "$HERE/../011_feed_tabs.sql" "$HERE/../012_explore.sql" "$HERE/../013_social.sql" "$HERE/../014_notifications.sql" "$HERE/../015_app_feed.sql" $S/ && chmod 644 $S/*.sql
PSQL="psql -h $S -p $PORT -U postgres"
su postgres -c "$PSQL -qc 'drop database if exists sb' -c 'create database sb'"
su postgres -c "$PSQL -d sb -q -v ON_ERROR_STOP=1 -f $S/supabase-shim.sql -f $S/001_community.sql -f $S/002_names.sql -f $S/003_originals_and_replies.sql -f $S/004_budget_and_photos.sql -f $S/005_shared_plans.sql -f $S/006_private_rls.sql -f $S/001_community.sql -f $S/002_names.sql -f $S/003_originals_and_replies.sql -f $S/004_budget_and_photos.sql -f $S/005_shared_plans.sql -f $S/006_private_rls.sql -f $S/007_reviews_terms_moderation.sql -f $S/007_reviews_terms_moderation.sql -f $S/008_withdraw_and_photo_cleanup.sql -f $S/008_withdraw_and_photo_cleanup.sql -f $S/009_record_seals.sql -f $S/009_record_seals.sql -f $S/010_points.sql -f $S/010_points.sql -f $S/011_feed_tabs.sql -f $S/011_feed_tabs.sql -f $S/012_explore.sql -f $S/012_explore.sql -f $S/013_social.sql -f $S/013_social.sql -f $S/014_notifications.sql -f $S/014_notifications.sql -f $S/015_app_feed.sql -f $S/015_app_feed.sql" 2>&1 | grep -v NOTICE

FAILS=0
# Os termos (esquema 7) só se exigem nos testes do fim; até lá, como antes.
su postgres -c "$PSQL -d sb -tAqc 'update public.community_settings set terms_version = null'"
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
expect "cada escrita avisa o canal do plano, só com a revisão" "^plan-poke:$SP\\|changed\\|false\\|rev\$" "$(adm "select topic||'|'||event||'|'||private||'|'||(select string_agg(k, ',') from jsonb_object_keys(payload) k) from realtime.sent order by id desc limit 1")"
expect "o aviso traz a revisão que foi escrita" '^t$' "$(adm "select (payload->>'rev')::bigint = (select max(rev) from public.shared_plan_fields) from realtime.sent order by id desc limit 1")"
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
q anon "" "select public.app_leave_plan('$TOK','$SP')" >/dev/null
expect "apagar o plano avisa quem o tem aberto" "^plan-poke:$SP\\|ended\$" "$(adm "select topic||'|'||event from realtime.sent order by id desc limit 1")"
expect "o dono apaga o plano ao sair" '^0$' "$(q anon '' "select public.app_leave_plan('$TOK','$SP')" >/dev/null; adm "select count(*) from public.shared_plans")"
adm "delete from public.memberships"

# ------------------------------------------------ 7: termos, avaliações, moderação
adm "update public.community_settings set terms_version = 't1'" >/dev/null
expect "publicar pede os termos" 'terms_required' "$(q anon '' "select id from public.app_publish_v2('$TOK','Minho','Minho','',1,2,'2026-07','{}'::jsonb,'trip-t', 0, 0, 0, 'test')")"
expect "a app sabe que faltam os termos" '^t1\|false$' "$(q anon '' "select version||'|'||accepted from public.app_terms('$TOK')")"
expect "não se aceita uma versão antiga" 'terms_outdated' "$(q anon '' "select public.app_accept_terms('$TOK','t0')")"
expect "aceitar os termos pela app" '^t$' "$(q anon '' "select public.app_accept_terms('$TOK','t1')" >/dev/null; q anon '' "select accepted from public.app_terms('$TOK')")"
expect "depois de aceitar, publica" '^[0-9a-f-]{36}$' "$(q anon '' "select id from public.app_publish_v2('$TOK','Minho','Minho','',1,2,'2026-07','{}'::jsonb,'trip-t', 0, 0, 0, 'test')")"
expect "gostar não pede os termos" '^[0-9]+$' "$(q anon '' "select public.app_set_like('$BTOK','$OID',true)")"
expect "avaliar pede os termos" 'terms_required' "$(q anon '' "select * from public.app_review('$BTOK','$OID',5,'Muito bom')")"
q anon "" "select public.app_accept_terms('$BTOK','t1')" >/dev/null
expect "quem fez com GPS avalia como quem fez" '^t$' "$(q anon '' "select verified from public.app_review('$BTOK','$OID',5,'  Muito bom  ')")"
expect "médias: de quem fez e de todas" '^1\|5.0\|1\|5.0\|1$' "$(q anon '' "select verified_rating_count||'|'||verified_rating_avg||'|'||rating_count||'|'||rating_avg||'|'||review_count from public.itineraries where id = '$OID'")"
expect "o comentário guarda-se sem espaços à volta" '^5\|Muito bom\|true$' "$(q anon '' "select stars||'|'||body||'|'||verified from public.app_my_review('$BTOK','$OID')")"
expect "não se avalia o próprio itinerário" 'own_itinerary' "$(q anon '' "select * from public.app_review('$TOK','$OID',5,null)")"
expect "avaliação vazia recusada" 'review_empty' "$(q anon '' "select * from public.app_review('$BTOK','$OID',null,'   ')")"
expect "estrelas fora de 1 a 5 recusadas" 'review_invalid' "$(q anon '' "select * from public.app_review('$BTOK','$OID',6,null)")"
expect "ninguém escreve avaliações direto" 'permission denied' "$(q authenticated $B "insert into public.reviews(itinerary_id, author_id, stars, verified) values ('$OID','$B',5,true)")"
expect "ninguém se marca como quem fez" 'permission denied' "$(q authenticated $B "update public.reviews set verified = true")"
D=$(adm "insert into auth.users(email) values ('d@example.org') returning id" | head -1)
expect "comentar no site também pede os termos" 'terms_required' "$(q authenticated $D "insert into public.comments(itinerary_id, author_id, body) values ('$OID','$D','Olá')")"
expect "aceitar os termos no site" '^t1\|true$' "$(q authenticated $D "select public.accept_terms('t1')" >/dev/null; q authenticated $D "select version||'|'||accepted from public.my_terms()")"
expect "quem não fez avalia como geral" '^f$' "$(q authenticated $D "select verified from public.review_itinerary('$OID',3,null)")"
expect "a média de todas conta a geral, a de quem fez não" '^1\|5.0\|2\|4.0$' "$(q anon '' "select verified_rating_count||'|'||verified_rating_avg||'|'||rating_count||'|'||rating_avg from public.itineraries where id = '$OID'")"
expect "só comentário: sai das médias, fica na contagem" '^1\|5.0\|2$' "$(q authenticated $D "select * from public.review_itinerary('$OID',null,'Gostei do percurso')" >/dev/null; q anon '' "select rating_count||'|'||rating_avg||'|'||review_count from public.itineraries where id = '$OID'")"
expect "as avaliações leem-se sem conta" '^2$' "$(q anon '' "select count(*) from public.reviews where itinerary_id = '$OID'")"
DR=$(q anon "" "select request_id||' '||secret from public.app_begin_link('D')"); q authenticated $D "select public.confirm_app_link('${DR%% *}')" >/dev/null
DTOK=$(q anon "" "select token from public.app_redeem_link('${DR%% *}','${DR##* }')")
expect "fazer a viagem depois torna a avaliação de quem fez" '^t$' "$(q anon '' "select public.app_record_completion('$DTOK','$OID', 4, 4, 200)" >/dev/null; q anon '' "select verified from public.app_my_review('$DTOK','$OID')")"
RV=$(q anon "" "select id from public.reviews where author_id = '$D'")
expect "denunciar uma avaliação sem conta" '^ok$' "$(q anon '' "insert into public.reports(review_id, reason) values ('$RV','ofensivo'); select 'ok'")"
expect "sem conta não se modera" 'permission denied' "$(q anon '' 'select count(*) from public.admin_reports()')"
expect "quem não modera não vê denúncias" 'not_admin' "$(q authenticated $B 'select count(*) from public.admin_reports()')"
adm "insert into private.admins(user_id) values ('$A') on conflict do nothing" >/dev/null
expect "o site sabe quem modera" '^t f$' "$(q authenticated $A 'select public.am_i_admin()') $(q authenticated $B 'select public.am_i_admin()')"
expect "quem modera vê a denúncia e o que foi denunciado" '^review\|Gostei do percurso\|false$' "$(q authenticated $A "select kind||'|'||excerpt||'|'||target_hidden from public.admin_reports() where target_id = '$RV'")"
expect "esconder uma avaliação resolve a denúncia" '^1\|hidden$' "$(q authenticated $A "select public.admin_set_hidden('review','$RV',true)" >/dev/null; q anon '' "select count(*) from public.reviews where itinerary_id = '$OID'")|$(adm "select resolution from public.reports where review_id = '$RV'")"
expect "o escondido sai das contas" '^1$' "$(q anon '' "select review_count from public.itineraries where id = '$OID'")"
expect "o autor ainda vê a sua" '^t$' "$(q anon '' "select hidden from public.app_my_review('$DTOK','$OID')")"
expect "quem modera não se bloqueia" 'self_block' "$(q authenticated $A "select public.admin_set_blocked('$A', true, 'teste')")"
expect "conta bloqueada não avalia" 'account_blocked' "$(q authenticated $A "select public.admin_set_blocked('$D', true, 'spam')" >/dev/null; q anon '' "select * from public.app_review('$DTOK','$OID',1,null)")"
expect "conta bloqueada não dá likes" 'row-level|account_blocked' "$(q authenticated $D "insert into public.likes(itinerary_id, user_id) values ('$OID','$D')")"
expect "desbloquear devolve a voz, não o conteúdo" '^t\|0$' "$(q authenticated $A "select public.admin_set_blocked('$D', false)" >/dev/null; q anon '' "select * from public.app_review('$DTOK','$OID',4,null)" >/dev/null; q anon '' "select hidden from public.app_my_review('$DTOK','$OID')")|$(adm "select count(*) from private.blocked_accounts")"
expect "bloquear alguém só para mim" "^$D\$" "$(q anon '' "select public.app_set_user_block('$BTOK','$D',true)" >/dev/null; q anon '' "select * from public.app_user_blocks('$BTOK')")"
expect "não me bloqueio a mim" 'self_block' "$(q anon '' "select public.app_set_user_block('$BTOK','$B',true)")"
expect "cada um só vê os seus bloqueios" '^0$' "$(q authenticated $A 'select count(*) from public.user_blocks')"
expect "apagar a própria avaliação" '^0$' "$(q anon '' "select public.app_delete_review('$BTOK','$OID')" >/dev/null; q anon '' "select count(*) from public.app_my_review('$BTOK','$OID')")"
adm "update public.community_settings set terms_version = null" >/dev/null

# ------------------------------------------------ esquema 8: retirar de verdade
adm "update private.photo_tickets set created_at = now()" >/dev/null
adm "update public.itineraries set hidden = true where id = '$IID'" >/dev/null
expect "a lista mostra os meus, com fotos e contas" '^2\|[0-9]+\|[0-9]+$' "$(q anon '' "select photo_count||'|'||like_count||'|'||review_count from public.app_my_published('$TOK') where id = '$OID'")"
expect "o escondido pela moderação também aparece ao autor" '^t$' "$(q anon '' "select hidden from public.app_my_published('$TOK') where id = '$IID'")"
expect "B não vê os de A na sua lista" '^0$' "$(q anon '' "select count(*) from public.app_my_published('$BTOK') where id = '$OID'")"
expect "o site lista os meus com sessão" '^t$' "$(q authenticated $A "select hidden from public.my_published() where id = '$IID'")"
expect "anon não pede a lista do site" 'permission denied' "$(q anon '' 'select count(*) from public.my_published()')"
expect "listar o bucket não mostra nada" '^0$' "$(q anon '' 'select count(*) from storage.objects')"
TK2=$(q anon "" "select public.app_photo_ticket('$TOK','$OID')")
q anon '' "insert into storage.objects(bucket_id,name) values ('itinerary-photos','$TK2/1.jpg')" >/dev/null
expect "trocar as fotos põe as antigas no lixo" "^$TK/1.jpg,$TK/2.jpg\$" "$(q anon '' "select public.app_set_photos('$TOK','$OID','$TK2',1)" >/dev/null; q anon '' "select array_to_string(public.app_photo_trash('$TOK'), ',')")"
expect "o lixo de A não é dado a B" '^$' "$(q anon '' "select array_to_string(public.app_photo_trash('$BTOK'), ',')")"
expect "fora da operação de apagar, o lixo não se vê" '^0$' "$(q anon '' 'select count(*) from storage.objects')"
expect "na operação de apagar, vê-se só o lixo" '^2$' "$(q anon '' "set local storage.operation = 'storage.object.delete_many'; select count(*) from storage.objects")"
expect "apagar o que não é lixo não apaga nada" '^0$' "$(q anon '' "set local storage.operation = 'storage.object.delete_many'; with d as (delete from storage.objects where name = '$TK2/1.jpg' returning 1) select count(*) from d")"
expect "apagar o lixo apaga" '^2$' "$(q anon '' "set local storage.operation = 'storage.object.delete_many'; with d as (delete from storage.objects where name like '$TK/%' returning 1) select count(*) from d")"
expect "o que já saiu do bucket sai do lixo" '^\|0$' "$(q anon '' "select array_to_string(public.app_photo_trash('$TOK'), ',')")|$(adm 'select count(*) from private.photo_trash')"
expect "B não retira o itinerário de A" '^1$' "$(q anon '' "select public.app_withdraw('$BTOK','$OID')" >/dev/null; q anon '' "select count(*) from public.itineraries where id = '$OID'")"
expect "retirar devolve as fotos a apagar" "^$TK2/1.jpg\$" "$(q anon '' "select array_to_string(public.app_withdraw('$TOK','$OID'), ',')")"
expect "o itinerário sai, com os comentários e as avaliações" '^0 0 0$' "$(q anon '' "select count(*) from public.itineraries where id = '$OID'; select count(*) from public.comments where itinerary_id = '$OID'; select count(*) from public.reviews where itinerary_id = '$OID'")"
adm "insert into storage.objects(bucket_id,name) values ('itinerary-photos','orfa/1.jpg'); insert into private.photo_trash(path,user_id) values ('orfa/1.jpg', gen_random_uuid())" >/dev/null
expect "fotos de contas apagadas: quem limpa a seguir leva-as" '^orfa/1.jpg$' "$(q anon '' "select array_to_string(public.app_photo_trash('$BTOK'), ',')")"
BIID=$(q anon "" "select public.app_publish('$BTOK','Do B','Porto','s',1,1,null,'{}'::jsonb,'trip-b')")
expect "no site, antes de apagar a conta, retira-se tudo" '^0$' "$(q authenticated $B 'select public.withdraw_all_mine()' >/dev/null; q anon '' "select count(*) from public.itineraries where author_id = '$B'")"
expect "anon não retira pelo site" 'permission denied' "$(q anon '' "select public.withdraw_itinerary('$IID')")"
expect "B não retira pelo site o de A" '^1$' "$(q authenticated $B "select public.withdraw_itinerary('$IID')" >/dev/null; adm "select count(*) from public.itineraries where id = '$IID'")"

# ------------------------------------------------ esquema 9: selos do registo real
H1=$(printf 'ab%.0s' {1..32})
expect "selo: impressão com a forma errada recusada" 'seal_invalid' "$(q anon '' "select public.app_register_seal('$TOK','xyz')")"
expect "selo: 63 caracteres recusados" 'seal_invalid' "$(q anon '' "select public.app_register_seal('$TOK','${H1:1}')")"
expect "selo: sem ligação válida não se sela" 'link_invalid' "$(q anon '' "select public.app_register_seal('$(printf 'a%.0s' {1..64})','$H1')")"
expect "selo: registar devolve a data" '^t$' "$(q anon '' "select public.app_register_seal('$TOK','$H1') <= now()")"
adm "update private.record_seals set sealed_at = '2026-01-02 03:04:05+00' where hash = '$H1'" >/dev/null
expect "selo: o primeiro ganha, outra conta recebe a data original" '^t$' "$(q anon '' "select public.app_register_seal('$BTOK', upper('$H1')) = '2026-01-02 03:04:05+00'::timestamptz")"
expect "selo: a data e a conta não mudam" "^1\|$A\|true\$" "$(adm "select count(*)||'|'||min(user_id::text)||'|'||(min(sealed_at) = '2026-01-02 03:04:05+00') from private.record_seals where hash = '$H1'")"
expect "selo: sem conta, pergunta-se a data" '^t$' "$(q anon '' "select public.seal_check('$H1') = '2026-01-02 03:04:05+00'::timestamptz")"
expect "selo: impressão desconhecida não tem data" '^t$' "$(q anon '' "select public.seal_check('$(printf 'cd%.0s' {1..32})') is null")"
expect "selo: anon não lê a tabela" 'permission denied' "$(q anon '' 'select count(*) from private.record_seals')"
expect "selo: com sessão também não" 'permission denied' "$(q authenticated $A 'select count(*) from private.record_seals')"
expect "selo: só a impressão, a conta e a data" '^hash,sealed_at,user_id$' "$(adm "select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_schema = 'private' and table_name = 'record_seals'")"
expect "selo: a verificação só devolve a data" '^timestamp with time zone$' "$(adm "select format_type(prorettype, null) from pg_proc where proname = 'seal_check'")"
adm "insert into private.record_seals(hash, user_id) select encode(extensions.digest(g::text, 'sha256'), 'hex'), '$B' from generate_series(1, 49) g" >/dev/null
expect "selo: o 50.º do dia passa" '^t$' "$(q anon '' "select public.app_register_seal('$BTOK','$(printf 'ef%.0s' {1..32})') is not null")"
expect "selo: o 51.º fica para amanhã" 'seal_limit' "$(q anon '' "select public.app_register_seal('$BTOK','$(printf '12%.0s' {1..32})')")"
expect "selo: o que já está selado responde sempre" '^t$' "$(q anon '' "select public.app_register_seal('$BTOK','$H1') is not null")"

adm "update public.itineraries set hidden = true where id = '$IID'"
expect "escondido some do feed" '^0$' "$(q anon '' "select count(*) from public.itineraries where id = '$IID'")"
expect "o autor ainda o vê" '^1$' "$(q authenticated $A "select count(*) from public.itineraries where id = '$IID'")"
expect "desligar invalida a chave" 'link_invalid' "$(q anon '' "select public.app_unlink('$TOK')" >/dev/null; q anon '' "select * from public.app_whoami('$TOK')")"
expect "anon não apaga contas" 'permission denied' "$(q anon '' 'select public.delete_my_account()')"
q authenticated $A "select public.delete_my_account()" >/dev/null
expect "apagar a conta leva tudo" '^0 3$' "$(q anon '' 'select count(*) from public.itineraries; select count(*) from public.profiles')"
expect "apagar a conta leva os selos" '^0$' "$(adm "select count(*) from private.record_seals where user_id = '$A'")"

# ------------------------------------------------ esquema 10: pontos
link() { local r; r=$(q anon "" "select request_id||' '||secret from public.app_begin_link('$2')"); q authenticated $1 "select public.confirm_app_link('${r%% *}')" >/dev/null; q anon "" "select token from public.app_redeem_link('${r%% *}','${r##* }')"; }
newuser() { adm "insert into auth.users(email) values ('$1@example.org') returning id" | head -1; }
pts() { adm "select coalesce(sum(delta), 0) from private.points_ledger where user_id = '$1'${2:+ and reason = '$2'}"; }
like() { adm "insert into public.likes(itinerary_id, user_id) select '$1', id from auth.users where email ~ '$2' on conflict do nothing" >/dev/null; }
E=$(newuser e); ETOK=$(link $E 'E')
F=$(newuser f); FTOK=$(link $F 'F')
EIID=$(q anon "" "select id from public.app_publish_v2('$ETOK','Serra da Estrela','Serra da Estrela','',2,4,'2026-06','{}'::jsonb,'trip-e1', 4, 4, 100, 'test')")
E2ID=$(q anon "" "select id from public.app_publish_v2('$ETOK','Beira Baixa','Beira Baixa','',1,3,'2026-05','{}'::jsonb,'trip-e2', 0, 0, 0, 'test')")
adm "insert into public.itinerary_completions(itinerary_id, user_id, evidence, visited_stops, gps_stops) values ('$EIID','$E','original',4,4)" >/dev/null
expect "pontos: nada pelo próprio itinerário" '^0$' "$(pts $E)"
adm "delete from public.itinerary_completions where user_id = '$E'" >/dev/null
q anon "" "select public.app_record_completion('$FTOK','$EIID', 2, 0, 0)" >/dev/null
expect "pontos: feita sem GPS não conta" '^0$' "$(pts $E)"
q anon "" "select public.app_record_completion('$FTOK','$EIID', 4, 4, 200)" >/dev/null
expect "pontos: feita com GPS dá 50 ao autor" '^50$' "$(pts $E trip_done)"
q anon "" "select public.app_record_completion('$FTOK','$EIID', 4, 4, 200)" >/dev/null
adm "delete from public.itinerary_completions where user_id = '$F'; insert into public.itinerary_completions(itinerary_id, user_id, evidence, visited_stops, gps_stops) values ('$EIID','$F','original',4,4)" >/dev/null
expect "pontos: a mesma conclusão nunca paga duas vezes" '^50$' "$(pts $E trip_done)"
q anon "" "select * from public.app_review('$FTOK','$EIID',2,null)" >/dev/null
expect "pontos: avaliação de quem fez dá 10, mesmo com poucas estrelas" '^10$' "$(pts $E review_from_doer)"
q anon "" "select * from public.app_review('$FTOK','$EIID',5,'Mudei de ideias')" >/dev/null
q anon "" "select * from public.app_review('$BTOK','$EIID',5,null)" >/dev/null
expect "pontos: mudar a avaliação ou avaliar sem ter feito não dá mais" '^10$' "$(pts $E review_from_doer)"
for n in $(seq 1 12); do q anon "" "select public.app_comment_v2('$FTOK','$EIID','Comentário $n', null)" >/dev/null; done
expect "pontos: comentários dão no máximo 10 por dia" '^10$' "$(pts $F comment)"
q anon "" "select public.app_comment_v2('$ETOK','$EIID','Obrigado a todos', null)" >/dev/null
expect "pontos: comentar no próprio itinerário não dá" '^0$' "$(pts $E comment)"
FC1=$(adm "select c.id from public.comments c join private.points_ledger l on l.reason = 'comment' and l.ref_id = c.id::text where c.author_id = '$F' order by c.created_at limit 1")
FC2=$(adm "select c.id from public.comments c join private.points_ledger l on l.reason = 'comment' and l.ref_id = c.id::text where c.author_id = '$F' order by c.created_at desc limit 1")
q authenticated $F "delete from public.comments where id = '$FC1'" >/dev/null
expect "pontos: comentário apagado perde o ponto" '^9$' "$(pts $F)"
adm "insert into private.admins(user_id) values ('$B') on conflict do nothing" >/dev/null
q authenticated $B "select public.admin_set_hidden('comment','$FC2',true)" >/dev/null
expect "pontos: comentário escondido pela moderação perde o ponto" '^8$' "$(pts $F)"
q authenticated $B "select public.admin_set_hidden('comment','$FC2',false)" >/dev/null
expect "pontos: voltar a mostrar o comentário devolve o ponto" '^9$' "$(pts $F)"
adm "insert into auth.users(email) select 'fa' || g || '@example.org' from generate_series(1, 30) g" >/dev/null
adm "update public.profiles set created_at = now() - interval '8 days' where id in (select id from auth.users where email ~ '^fa([1-9]|1[0-9]|2[0-5])@')" >/dev/null
like $EIID '^fa[1-9]@'
expect "pontos: 9 gostos ainda não dão" '^0$' "$(pts $E likes)"
like $EIID '^fa(2[6-9]|30)@'
expect "pontos: gostos de contas com menos de 7 dias não contam" '^0$' "$(pts $E likes)"
like $EIID '^fa10@'
expect "pontos: 10 gostos dão 1" '^1$' "$(pts $E likes)"
adm "delete from public.likes where itinerary_id = '$EIID' and user_id = (select id from auth.users where email = 'fa10@example.org')" >/dev/null
like $EIID '^fa10@'
expect "pontos: tirar e voltar a gostar não paga outra vez" '^1$' "$(pts $E likes)"

# ------------------------------------------------ esquema 11: separadores do feed
expect "feed: recentes, o mais novo primeiro" "^$E2ID $EIID\$" "$(q anon '' "select id from public.feed_page('recent')")"
expect "feed: popular, o mais gostado e feito" "^$EIID $E2ID\$" "$(q anon '' "select id from public.feed_page('popular')")"
adm "update public.likes set created_at = now() - interval '40 days' where itinerary_id = '$EIID'; update public.itinerary_completions set completed_at = now() - interval '40 days' where itinerary_id = '$EIID'" >/dev/null
like $E2ID '^fa11@'
expect "feed: popular conta só os últimos 30 dias" "^$E2ID $EIID\$" "$(q anon '' "select id from public.feed_page('popular')")"
expect "feed: página seguinte" "^$EIID\$" "$(q anon '' "select id from public.feed_page('recent', null, null, 1, 1)")"
expect "feed: o filtro da prova continua" "^$EIID\$" "$(q anon '' "select id from public.feed_page('popular', 'original')")"
expect "feed: a procura continua" "^$E2ID\$" "$(q anon '' "select id from public.feed_page('recent', null, 'BEIRA')")"
expect "feed: meus, sem sessão, vazio" '^$' "$(q anon '' "select id from public.feed_page('mine')")"
q authenticated $F "insert into public.likes(itinerary_id, user_id) values ('$E2ID','$F')" >/dev/null
expect "feed: meus, os que gostei" "^$E2ID\$" "$(q authenticated $F "select id from public.feed_page('mine')")"
expect "feed: meus, os que publiquei" "^$E2ID $EIID\$" "$(q authenticated $E "select id from public.feed_page('mine')")"
q authenticated $F "insert into public.user_blocks(blocker_id, blocked_id) values ('$F','$E')" >/dev/null
expect "feed: quem bloqueei não aparece" '^0\|2$' "$(q authenticated $F "select count(*) from public.feed_page('recent')")|$(q anon '' "select count(*) from public.feed_page('recent')")"
q authenticated $F "delete from public.user_blocks where blocker_id = '$F'" >/dev/null
expect "feed: separador inventado recusado" 'tab_invalid' "$(q anon '' "select id from public.feed_page('tudo')")"

# ------------------------------------------------ esquema 12: explorar com filtros
adm "update public.itineraries set day_count = 3, travelled_month = '2026-09' where id = '$EIID'; update public.itineraries set day_count = 1, travelled_month = '2025-07', destination = 'gerês' where id = '$E2ID'" >/dev/null
expect "feed: a app continua a chamar com os cinco de antes" "^$E2ID $EIID\$" "$(q anon '' "select id from public.feed_page(p_tab => 'recent', p_level => null, p_search => null, p_offset => 0, p_limit => 20)")"
expect "feed: filtro de dias 2-3" "^$EIID\$" "$(q anon '' "select id from public.feed_page('recent', p_days => '2-3')")"
expect "feed: filtro de dias 1" "^$E2ID\$" "$(q anon '' "select id from public.feed_page('recent', p_days => '1')")"
expect "feed: filtro de dias 8+ vazio" '^$' "$(q anon '' "select id from public.feed_page('recent', p_days => '8+')")"
expect "feed: filtro do mês" "^$E2ID\$" "$(q anon '' "select id from public.feed_page('recent', p_month => 7)")"
expect "feed: dias inventados recusados" 'days_invalid' "$(q anon '' "select id from public.feed_page('recent', p_days => '3-9')")"
expect "feed: mês 13 recusado" 'month_invalid' "$(q anon '' "select id from public.feed_page('recent', p_month => 13)")"
expect "filtros: contagens por prova e ao todo" '^2\|1$' "$(q anon '' "select (f->'levels'->>'all')||'|'||(f->'levels'->>'original') from public.explore_facets() f")"
expect "filtros: contagens por dias" '^1\|1\|0$' "$(q anon '' "select (f->'days'->>'1')||'|'||(f->'days'->>'2-3')||'|'||(f->'days'->>'8+') from public.explore_facets() f")"
expect "filtros: meses com viagens" '^1\|1\|$' "$(q anon '' "select (f->'months'->>'7')||'|'||(f->'months'->>'9')||'|'||coalesce(f->'months'->>'1','') from public.explore_facets() f")"
expect "filtros: destinos juntam maiúsculas" '^1$' "$(q anon '' "select count(*) from jsonb_array_elements((select f->'destinations' from public.explore_facets() f)) d where lower(d->>'name') = 'gerês'")"
expect "filtros: a procura também conta" '^1$' "$(q anon '' "select f->'levels'->>'all' from public.explore_facets('BEIRA') f")"
q authenticated $F "insert into public.user_blocks(blocker_id, blocked_id) values ('$F','$E')" >/dev/null
expect "filtros: quem bloqueei não conta" '^0$' "$(q authenticated $F "select f->'levels'->>'all' from public.explore_facets() f")"
q authenticated $F "delete from public.user_blocks where blocker_id = '$F'" >/dev/null

# ------------------------------------------------ esquema 13: guardar e seguir
H=$(newuser h)
q authenticated $F "insert into public.saves(itinerary_id, user_id) values ('$EIID','$F')" >/dev/null
expect "guardar: conta no itinerário" '^1$' "$(adm "select save_count from public.itineraries where id = '$EIID'")"
expect "guardar: ninguém guarda por outro" 'row-level security|violates' "$(q authenticated $F "insert into public.saves(itinerary_id, user_id) values ('$E2ID','$E')")"
expect "guardar: cada um vê só os seus" '^0$' "$(q authenticated $E "select count(*) from public.saves")"
expect "guardar: anon não lê" 'permission denied' "$(q anon '' "select count(*) from public.saves")"
expect "feed: guardados, com sessão" "^$EIID\$" "$(q authenticated $F "select id from public.feed_page('saved')")"
expect "feed: guardados, sem sessão, vazio" '^$' "$(q anon '' "select id from public.feed_page('saved')")"
q authenticated $F "insert into public.follows(follower_id, followee_id) values ('$F','$E')" >/dev/null
expect "seguir: contagens no perfil" '^1\|1$' "$(adm "select (select follower_count from public.profiles where id = '$E')||'|'||(select following_count from public.profiles where id = '$F')")"
expect "seguir: não se segue a si próprio" 'check|violates' "$(q authenticated $F "insert into public.follows(follower_id, followee_id) values ('$F','$F')")"
expect "seguir: quem é seguido vê" '^1$' "$(q authenticated $E "select count(*) from public.follows")"
expect "seguir: terceiros não veem" '^0$' "$(q authenticated $H "select count(*) from public.follows")"
expect "feed: a seguir mostra quem sigo" "^2\$" "$(q authenticated $F "select count(*) from public.feed_page('following')")"
expect "feed: a seguir, sem ninguém, vazio" '^0$' "$(q authenticated $H "select count(*) from public.feed_page('following')")"
q authenticated $F "delete from public.follows where follower_id = '$F'" >/dev/null
expect "deixar de seguir desconta" '^0$' "$(adm "select follower_count from public.profiles where id = '$E'")"
q authenticated $F "delete from public.saves where user_id = '$F'" >/dev/null
expect "tirar dos guardados desconta" '^0$' "$(adm "select save_count from public.itineraries where id = '$EIID'")"
expect "app: guardar pela ligação" '^1$' "$(q anon '' "select public.app_set_save('$ETOK', '$E2ID', true)")"
expect "app: o que guardei" "^$E2ID\$" "$(q anon '' "select public.app_saved('$ETOK', array['$E2ID','$EIID']::uuid[])")"
expect "app: não se segue a si próprio" 'follow_self' "$(q anon '' "select public.app_set_follow('$ETOK', '$E', true)")"

# ------------------------------------------------ esquema 15: separadores pessoais na app
expect "app: guardados pela ligação" "^$E2ID\$" "$(q anon '' "select id from public.app_feed_page('$ETOK', 'saved')")"
X=$(newuser x); XTOK=$(link $X 'X')
FN=$(adm "select count(*) from public.itineraries where author_id = '$E' and not hidden")
expect "app: quem sigo tem viagens (senão o teste seguinte não mede nada)" '^[1-9]' "$FN"
q anon '' "select public.app_set_follow('$XTOK', '$E', true)" >/dev/null
expect "app: a seguir mostra quem sigo" "^$FN\$" "$(q anon '' "select count(*) from public.app_feed_page('$XTOK', 'following')")"
expect "app: a seguir, sem seguir ninguém, vazio" '^0$' "$(q anon '' "select count(*) from public.app_feed_page('$ETOK', 'following')")"
expect "app: sem ligação válida, recusa" 'link_invalid' "$(q anon '' "select count(*) from public.app_feed_page('não-é-um-token', 'saved')")"
expect "app: separador desconhecido recusado" 'tab_invalid' "$(q anon '' "select count(*) from public.app_feed_page('$ETOK', 'tudo')")"
expect "app: populares também pela ligação" '^[1-9][0-9]*$' "$(q anon '' "select count(*) from public.app_feed_page('$ETOK', 'popular')")"
expect "feed do site continua igual" '^[1-9][0-9]*$' "$(q anon '' "select count(*) from public.feed_page('recent')")"
expect "feed_rows não se chama de fora" 'permission denied' "$(q anon '' "select count(*) from private.feed_rows(null, 'recent', null, null, 0, 20, null, null)")"
q anon '' "select public.app_set_follow('$XTOK', '$E', false)" >/dev/null
q anon '' "select public.app_set_save('$ETOK', '$E2ID', false)" >/dev/null

# ------------------------------------------------ esquema 14: notificações
N0=$(adm "select count(*) from public.notifications where user_id = '$E'")
q authenticated $H "insert into public.likes(itinerary_id, user_id) values ('$E2ID','$H')" >/dev/null
expect "notificação: gosto chega ao autor" "^$((N0 + 1))\$" "$(adm "select count(*) from public.notifications where user_id = '$E'")"
q authenticated $H "delete from public.likes where itinerary_id = '$E2ID' and user_id = '$H'" >/dev/null
q authenticated $H "insert into public.likes(itinerary_id, user_id) values ('$E2ID','$H')" >/dev/null
expect "notificação: tirar e voltar a gostar não repete" "^$((N0 + 1))\$" "$(adm "select count(*) from public.notifications where user_id = '$E'")"
q authenticated $H "insert into public.follows(follower_id, followee_id) values ('$H','$E')" >/dev/null
expect "notificação: novo seguidor" '^1$' "$(adm "select count(*) from public.notifications where user_id = '$E' and kind = 'follow' and actor_id = '$H'")"
q anon '' "select public.app_set_like('$ETOK', '$E2ID', true)" >/dev/null
expect "notificação: nada do que se faz a si próprio" '^0$' "$(adm "select count(*) from public.notifications where user_id = '$E' and actor_id = '$E'")"
expect "notificação: só o destinatário lê" '^0$' "$(q authenticated $H "select count(*) from public.notifications")"
expect "notificação: anon não lê" 'permission denied' "$(q anon '' "select count(*) from public.notifications")"
expect "notificação: ninguém escreve" 'permission denied' "$(q authenticated $E "insert into public.notifications(user_id, kind, actor_id) values ('$E','follow','$H')")"
expect "notificação: por ler" "^$((N0 + 2))\$" "$(q authenticated $E "select public.my_unread_count()")"
expect "notificação: marcar como lidas" "^$((N0 + 2))\$" "$(q authenticated $E "select public.mark_notifications_read()")"
expect "notificação: nada por ler" '^0$' "$(q authenticated $E "select public.my_unread_count()")"
q authenticated $E "insert into public.user_blocks(blocker_id, blocked_id) values ('$E','$H')" >/dev/null
q authenticated $H "delete from public.follows where follower_id = '$H'" >/dev/null
q authenticated $H "insert into public.follows(follower_id, followee_id) values ('$H','$E')" >/dev/null
expect "notificação: de quem bloqueei não chega" '^0$' "$(q authenticated $E "select public.my_unread_count()")"
q authenticated $E "delete from public.user_blocks where blocker_id = '$E'" >/dev/null
q authenticated $H "delete from public.follows where follower_id = '$H'; delete from public.likes where user_id = '$H'" >/dev/null

# ------------------------------------------------ pontos: máximos, moderação, gastar
adm "update private.points_rules set every = 1 where reason = 'likes'" >/dev/null
like $E2ID '^fa([1-9]|1[0-9]|2[0-5])@'
expect "pontos: as regras mudam-se sem código; gostos no máximo 20 por dia" '^20$' "$(pts $E likes)"
adm "update private.points_rules set every = 10 where reason = 'likes'" >/dev/null
expect "pontos: o saldo é a soma" '^80$' "$(pts $E)"
q authenticated $B "select public.admin_set_hidden('itinerary','$EIID',true)" >/dev/null
expect "pontos: itinerário escondido tira o que ganhou com ele" '^19$' "$(pts $E)"
expect "feed: o escondido não aparece" "^$E2ID\$" "$(q anon '' "select id from public.feed_page('recent')")"
q authenticated $B "select public.admin_set_hidden('itinerary','$EIID',true)" >/dev/null
expect "pontos: esconder outra vez não tira outra vez" '^19$' "$(pts $E)"
q authenticated $B "select public.admin_set_hidden('itinerary','$EIID',false)" >/dev/null
expect "pontos: voltar a mostrar devolve-os" '^80$' "$(pts $E)"
FRV=$(adm "select id from public.reviews where author_id = '$F' and itinerary_id = '$EIID'")
q authenticated $B "select public.admin_set_hidden('review','$FRV',true)" >/dev/null
expect "pontos: avaliação escondida tira os 10" '^70$' "$(pts $E)"
q authenticated $B "select public.admin_set_hidden('review','$FRV',false)" >/dev/null
G=$(newuser g)
expect "pontos: sem pontos não se troca" 'points_insufficient' "$(q authenticated $G 'select * from public.redeem_points_for_month()')"
expect "pontos: sem pontos não se cria código" 'points_insufficient' "$(q authenticated $G 'select public.create_gift_code()')"
expect "pontos: anon não troca" 'permission denied' "$(q anon '' 'select * from public.redeem_points_for_month()')"
adm "insert into private.points_ledger(user_id, delta, reason, ref_id) values ('$E', 2000, 'test', 'e')" >/dev/null
expect "trocar 500 pontos por 1 mês de membro" '^extended\|true\|1580$' "$(q authenticated $E "select outcome||'|'||(abs(extract(epoch from member_until - (now() + interval '1 month'))) < 60)||'|'||points_left from public.redeem_points_for_month()")"
V1=$(adm "select valid_until from public.memberships where user_id = '$E'")
q authenticated $E 'select * from public.redeem_points_for_month()' >/dev/null
expect "o segundo mês soma ao fim do primeiro" '^t$' "$(adm "select valid_until = '$V1'::timestamptz + interval '1 month' from public.memberships where user_id = '$E'")"
adm "update public.memberships set valid_until = now() - interval '10 days' where user_id = '$E'" >/dev/null
q authenticated $E 'select * from public.redeem_points_for_month()' >/dev/null
expect "membro que já tinha acabado conta a partir de hoje" '^t$' "$(adm "select abs(extract(epoch from valid_until - (now() + interval '1 month'))) < 60 from public.memberships where user_id = '$E'")"
adm "update public.memberships set valid_until = null where user_id = '$E'" >/dev/null
expect "membro sem fim não gasta pontos" '^no_end\|580\|t$' "$(q authenticated $E "select outcome||'|'||points_left from public.redeem_points_for_month()")|$(adm "select valid_until is null from public.memberships where user_id = '$E'")"
CODE1=$(q authenticated $E 'select public.create_gift_code()')
expect "código de oferta com a forma certa" '^PLAN-[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$' "$CODE1"
expect "o código custa 500" '^80$' "$(pts $E)"
expect "o código aparece a quem o criou" "^$CODE1\|false\$" "$(q authenticated $E "select code||'|'||redeemed from public.my_gift_codes()")"
expect "usar um código dá 1 mês" '^extended\|true$' "$(q authenticated $G "select outcome||'|'||(member_until > now() + interval '27 days') from public.redeem_gift_code(lower(replace('$CODE1', '-', ' ')))")"
expect "o código só se usa uma vez" 'gift_invalid' "$(q authenticated $F "select * from public.redeem_gift_code('$CODE1')")"
expect "nem por quem já o usou" 'gift_invalid' "$(q authenticated $G "select * from public.redeem_gift_code('$CODE1')")"
expect "código inventado recusado" 'gift_invalid' "$(q authenticated $F "select * from public.redeem_gift_code('PLAN-AAAA-AAAA')")"
adm "insert into private.gift_codes(code, created_by, expires_at) values ('PLAN-2222-3333', '$E', now() - interval '1 day'), ('PLAN-4444-5555', '$E', default)" >/dev/null
expect "código expirado recusado" 'gift_invalid' "$(q authenticated $F "select * from public.redeem_gift_code('PLAN-2222-3333')")"
expect "membro sem fim não gasta o código" '^no_end\|f$' "$(q authenticated $E "select outcome from public.redeem_gift_code('PLAN-4444-5555')")|$(adm "select redeemed_at is not null from private.gift_codes where code = 'PLAN-4444-5555'")"
expect "ninguém lê os movimentos nem os códigos pela API" 'permission denied.*permission denied.*permission denied' "$(q authenticated $E 'select count(*) from private.points_ledger') $(q authenticated $E 'select count(*) from private.gift_codes') $(q anon '' 'select count(*) from private.points_rules')"
REF=$(q authenticated $E 'select public.my_ref_code()')
expect "cada conta tem um código de convite" '^[A-HJKMNP-Z2-9]{8}$' "$REF"
expect "o código de convite não muda" "^$REF\$" "$(q authenticated $E 'select public.my_ref_code()')"
H=$(newuser h); HTOK=$(link $H 'H')
I=$(newuser i); ITOK=$(link $I 'I')
expect "convidar-se a si próprio recusado" 'ref_self' "$(q authenticated $E "select public.claim_ref('$REF')")"
expect "convite inventado recusado" 'ref_invalid' "$(q authenticated $H "select public.claim_ref('ZZZZZZZZ')")"
adm "update public.profiles set created_at = now() - interval '30 days' where id = '$B'" >/dev/null
expect "contas antigas não dizem quem as convidou" 'ref_too_late' "$(q authenticated $B "select public.claim_ref('$REF')")"
expect "quem chegou pelo convite diz quem convidou" '^ok$' "$(q authenticated $H "select 'ok' from public.claim_ref(lower('$REF'))")"
expect "só uma vez" 'ref_already' "$(q authenticated $H "select public.claim_ref('$REF')")"
expect "o convite sozinho não dá pontos" '^0$' "$(pts $E invite)"
adm "insert into public.memberships(user_id, valid_until) values ('$H', now() + interval '1 month')" >/dev/null
expect "convidado tornou-se membro: 100 para quem convidou" '^100$' "$(pts $E invite)"
q anon "" "select public.app_record_completion('$HTOK','$EIID', 4, 4, 200)" >/dev/null
expect "o convite paga uma vez por convidado" '^100$' "$(pts $E invite)"
q authenticated $I "select public.claim_ref('$REF')" >/dev/null
q anon "" "select public.app_record_completion('$ITOK','$E2ID', 3, 3, 50)" >/dev/null
expect "convidado fez uma viagem com GPS: mais 100" '^200$' "$(pts $E invite)"
expect "o saldo no site: soma, custos e 20 movimentos" "^$(pts $E)\|500\|500\|20\$" "$(q authenticated $E "select balance||'|'||month_cost||'|'||gift_cost||'|'||jsonb_array_length(movements) from public.my_points()")"
expect "os movimentos não dizem quem" '^$' "$(q authenticated $E "select string_agg(k, ',') from public.my_points(), jsonb_array_elements(movements) m, jsonb_object_keys(m) k where k not in ('delta', 'reason', 'created_at', 'about')")"
expect "anon não vê pontos" 'permission denied' "$(q anon '' 'select * from public.my_points()')"
expect "a app não tem funções de pontos" '^0$' "$(adm "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and left(p.proname, 4) = 'app_' and p.proname ~ '(point|gift|ref)'")"
FP=$(pts $F)
q authenticated $E "select public.delete_my_account()" >/dev/null
expect "apagar a conta leva os pontos e os convites" '^0\|0\|0$' "$(adm "select (select count(*) from private.points_ledger where user_id = '$E')||'|'||(select count(*) from private.ref_codes where user_id = '$E')||'|'||(select count(*) from private.referrals where inviter_id = '$E')")"
expect "quem comentou não perde pontos quando o itinerário sai" "^$FP\$" "$(pts $F)"
expect "um código por usar sobrevive a quem o criou" '^extended$' "$(q authenticated $F "select outcome from public.redeem_gift_code('PLAN-4444-5555')")"

echo; [ $FAILS -eq 0 ] && echo "Tudo certo." || { echo "$FAILS falhas."; exit 1; }
