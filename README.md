# Comunidade Plan-ish

Itinerários partilhados por quem viajou com o [Plan-ish](https://jrafael-rep.github.io/plan-ish-releases/).
Site estático (GitHub Pages) sobre uma base de dados Supabase.

- **Sem conta**: ver o feed (procurar por destino ou título, filtrar por GPS verificado / feitas /
  roteiros, ordenar por mais recentes ou mais gostadas), abrir itinerários, perfis, abrir no Plan-ish.
- **Com conta** (email, sem password): gostar, comentar e responder, gostar de comentários, gerir
  telemóveis ligados, apagar a conta.
- **A app** lê o feed sem conta e, depois de **ligada** a uma conta (confirmado aqui, em `ligar.html`),
  publica viagens concluídas (com orçamento e fotografias, se quiser), comenta e gosta. A app nunca
  inicia sessão nem vê passwords.
- **Planos partilhados** (só membros): um plano editado por várias pessoas ao mesmo tempo, na app e
  aqui (`plano.html`). As alterações vão campo a campo; no mesmo campo, fica a última. O site vê-as
  ao vivo (Supabase Realtime) e mostra quem está na página; a app pergunta a cada 2 s enquanto o
  plano está aberto. Vai o plano completo, incluindo casa e ponto de partida; o GPS nunca.

O cartão de uma viagem (`assets/card.js`) é o mesmo no feed, no itinerário e no perfil, e a app
desenha o mesmo no separador Comunidade. Ver `DESIGN.md`.

## Páginas

| Página | Para quê |
|---|---|
| `index.html` | Explorar: o feed de viagens, com pesquisa, filtros, ordem e "Ver mais viagens" |
| `itinerario.html?id=…` | Uma viagem: fotografias, dia a dia, quem também a fez, conversa com respostas |
| `viajante.html?id=…` | Perfil público: estatísticas e grelha das viagens publicadas e feitas |
| `entrar.html` | Entrar com um link por email |
| `ligar.html?pedido=…` | Confirmar a ligação da app (só "Entrar" e "Ligar"; sem planos nem preços) |
| `plano.html?id=…` | Editar um plano partilhado ao vivo: dias, paragens, durações, horas, notas; quem está na página; convidar; sair |
| `convite.html?c=…` | Aceitar um convite para um plano partilhado (ou abri-lo na app) |
| `conta.html` | O teu nome (e quem o escolheu), o nome do próximo viajante, itinerários, telemóveis ligados, sair, apagar conta |
| `privacidade.html` | O que a Comunidade guarda, o que é público e como se apaga |

## Configurar (uma vez)

1. **Base de dados**: no Supabase, *SQL Editor* → colar `supabase/001_community.sql` → *Run*;
   depois `supabase/002_names.sql`, `supabase/003_originals_and_replies.sql`,
   `supabase/004_budget_and_photos.sql`, `supabase/005_shared_plans.sql` e
   `supabase/006_private_rls.sql`, por esta ordem. (Na base de dados da Comunidade já estão os seis.) Podem correr outra vez sem estragar nada.
   O 004 cria no Storage o bucket público `itinerary-photos` (fotografias até 700 KB, só JPEG).
   O 005 junta a tabela dos planos partilhados à publicação `supabase_realtime`; confirmar em
   *Database → Publications* que ela lá está (sem ela, o site pergunta a cada 3 s em vez de ao vivo).
   No telemóvel, colar ficheiros grandes corta o texto: usar as versões em partes.
2. **Autenticação**: *Authentication → URL Configuration*
   - Site URL: `https://jrafael-rep.github.io/plan-ish-community/`
   - Redirect URLs: `https://jrafael-rep.github.io/plan-ish-community/**`
3. **GitHub Pages**: *Settings → Pages* → *Deploy from a branch* → `main` / `(root)`.
4. **Emails para outras pessoas**: o envio de email incluído no Supabase só chega aos membros da
   equipa do projeto. Para testers, configurar um SMTP próprio em *Authentication → Emails → SMTP*
   (por exemplo Resend, com plano grátis).

## Nomes

Ninguém escolhe o próprio nome. Há uma lista de 100 nomes a brincar (`name_pool`, em
`002_names.sql`). Cada conta nova recebe o nome que alguém lhe deixou há mais tempo ou, se não
houver, um ao acaso. Cada pessoa, uma vez, escolhe entre 4 nomes da lista o nome da próxima pessoa
que chegar; as 4 hipóteses não mudam ao recarregar. Quem apaga a conta devolve o nome à lista.

Acrescentar nomes: `insert into public.name_pool (name) values ('Chinelo Filósofo');`

## Membros

Durante a prova de conceito, qualquer conta pode interagir (`community_settings.members_only = false`).
Marcar um membro à mão, no *SQL Editor*:

```sql
insert into public.memberships (user_id, note)
select id, 'prova de conceito' from auth.users where email = 'pessoa@exemplo.pt'
on conflict (user_id) do nothing;
```

Só membros a interagir: `update public.community_settings set members_only = true;`

Os **planos partilhados** são sempre só para membros, mesmo na prova de conceito: para os
experimentar, as duas pessoas precisam da linha em `memberships` acima.

## Moderação

- Denúncias: tabela `reports` (painel do Supabase).
- Esconder um itinerário: `update public.itineraries set hidden = true where id = '…';`
- Esconder um comentário: `update public.comments set hidden = true where id = '…';`

## Segurança

- A chave em `assets/config.js` é **pública por natureza** (chave "publishable"). Quem protege os
  dados são as regras de acesso por linha em `supabase/001_community.sql`.
- A chave secreta e a password da base de dados **nunca** entram neste repositório.
- Testar as regras num Postgres 16 local que imita o Supabase: `sudo bash supabase/test/run.sh`
  (86 verificações: ligar a app, publicar, likes, comentários e respostas, denúncias, membros, nomes,
  viagens originais, "feita por", orçamento, fotografias, apagar conta).
- Fotografias: a app reduz cada uma para 1280 px e grava-a de novo antes de a enviar, por isso não
  leva a localização nem outros dados que vêm dentro da foto. Quem as envia é a app, com um bilhete
  de 30 minutos para um itinerário seu; ao trocar as fotografias, as antigas ficam no Storage sem
  uso (limpar à mão no painel, se o espaço apertar: 1 GB no plano grátis).
