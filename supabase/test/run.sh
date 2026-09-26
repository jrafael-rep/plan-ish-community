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
cp "$HERE/supabase-shim.sql" "$HERE/../001_community.sql" $S/ && chmod 644 $S/*.sql
PSQL="psql -h $S -p $PORT -U postgres"
su postgres -c "$PSQL -qc 'drop database if exists sb' -c 'create database sb'"
su postgres -c "$PSQL -d sb -q -v ON_ERROR_STOP=1 -f $S/supabase-shim.sql -f $S/001_community.sql -f $S/001_community.sql" 2>&1 | grep -v NOTICE

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
expect "perfis criados com nome neutro" '^Viajante [0-9A-F]{4} Viajante [0-9A-F]{4}$' "$(q anon '' 'select display_name from public.profiles')"

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
expect "whoami" '^Viajante [0-9A-F]{4}\|false\|true$' "$(q anon '' "select display_name||'|'||member||'|'||can_interact from public.app_whoami('$TOK')")"

IID=$(q anon "" "select public.app_publish('$TOK','Gerês 3 dias','Gerês','Cascatas',3,9,'2026-09','{\"type\":\"trip_plan\"}'::jsonb,'trip-1')")
expect "publicar" '^[0-9a-f-]{36}$' "$IID"
expect "voltar a publicar atualiza o mesmo" '^t$' "$(q anon '' "select public.app_publish('$TOK','Gerês 3 dias v2','Gerês','',3,10,'2026-09','{}'::jsonb,'trip-1') = '$IID'")"
expect "feed sem conta" '^Gerês 3 dias v2\|0\|Viajante' "$(q anon '' "select i.title||'|'||i.like_count||'|'||p.display_name from public.itineraries i join public.profiles p on p.id = i.author_id")"
expect "anon não escreve direto" 'permission denied' "$(q anon '' "insert into public.itineraries(author_id,title,day_count,stop_count,plan) values ('$A','x',1,1,'{}')")"
expect "B não publica em nome de A" 'row-level security' "$(q authenticated $B "insert into public.itineraries(author_id,title,day_count,stop_count,plan) values ('$A','x',1,1,'{}')")"
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

adm "update public.community_settings set members_only = true"
expect "só membros: quem não é, não publica" 'members_only' "$(q anon '' "select public.app_publish('$TOK','t','d','s',1,1,null,'{}'::jsonb,'trip-2')")"
adm "insert into public.memberships(user_id) values ('$A')"
expect "só membros: membro publica" '^t$' "$(q anon '' "select public.app_publish('$TOK','t','d','s',1,1,null,'{}'::jsonb,'trip-2') is not null")"
expect "whoami diz membro" '\|true\|true$' "$(q anon '' "select display_name||'|'||member||'|'||can_interact from public.app_whoami('$TOK')")"
adm "update public.memberships set valid_until = now() - interval '1 day'"
expect "membro expirado deixa de o ser" '\|false\|false$' "$(q anon '' "select display_name||'|'||member||'|'||can_interact from public.app_whoami('$TOK')")"
adm "update public.community_settings set members_only = false"

adm "update public.itineraries set hidden = true where id = '$IID'"
expect "escondido some do feed" '^1$' "$(q anon '' 'select count(*) from public.itineraries')"
expect "o autor ainda o vê" '^1$' "$(q authenticated $A "select count(*) from public.itineraries where id = '$IID'")"
expect "desligar invalida a chave" 'link_invalid' "$(q anon '' "select public.app_unlink('$TOK')" >/dev/null; q anon '' "select * from public.app_whoami('$TOK')")"
expect "anon não apaga contas" 'permission denied' "$(q anon '' 'select public.delete_my_account()')"
q authenticated $A "select public.delete_my_account()" >/dev/null
expect "apagar a conta leva tudo" '^0 1$' "$(q anon '' 'select count(*) from public.itineraries; select count(*) from public.profiles')"

echo; [ $FAILS -eq 0 ] && echo "Tudo certo." || { echo "$FAILS falhas."; exit 1; }
