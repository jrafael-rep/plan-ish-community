# Design — feed social de viagens

A Comunidade é uma rede social de viagens, não uma montra. Quem entra vê
**pessoas e viagens**: quem foi, as fotografias, se o GPS confirmou, quanto
custou, e o que os outros dizem. O site e o separador Comunidade da app
desenham o mesmo cartão.

## O cartão (a peça central)

1. **Cabeçalho** — avatar redondo, nome (liga ao perfil), há quanto tempo.
2. **Imagem 4:3** — as fotografias de quem publicou, a deslizar (pontos por
   baixo; setas no computador). Sem fotografias: uma capa com o traçado das
   paragens publicadas sobre a cor da viagem e o destino em grande. Por cima,
   à esquerda, o selo: **GPS verificado** (verde), **Viagem feita** (azul),
   **Roteiro** (neutro). Em baixo, "3 dias · 9 paragens".
3. **Corpo** — título, destino e mês; fichas de **orçamento** ("250–400 € por
   pessoa") e de **quem também fez**; resumo cortado a 3 linhas.
4. **Ações** — ♥ gostos, 💬 conversa, partilhar, e **Ver roteiro ▾** à direita.
5. **Expandido, no sítio** — a nota da prova, o dia a dia (linha do percurso;
   ponto verde = GPS, contorno azul = à mão, riscado = ficou de fora), e
   "Abrir no Plan-ish" + "Conversa".

Na página do itinerário o cartão aparece já aberto, seguido de "Também feita
por" e da conversa (respostas num nível, gostos em comentários).

O perfil tem cabeçalho com estatísticas e uma grelha de quadrados (capa +
título), com separadores Publicadas / Também fez.

## Tokens

As cores escuras são as do tema **Oceano** da app; o site segue o tema do
sistema e tem uma versão clara da mesma família.

| token | claro | escuro (Oceano) |
|---|---|---|
| bg | #F2F5F8 | #0A1420 |
| surface | #FFFFFF | #12202F |
| surface-2 | #EDF2F6 | #1A2C3F |
| line | #DCE4EC | #27405A |
| text | #0C1B2A | #EAF3FA |
| muted | #4A5F72 | #9FB6C9 |
| accent | #0B7A84 | #3FD0D8 |
| verified | #0E7A4E | #3DDC97 |
| like | #D6245C | #FF6B8B |

- Letra: Figtree (400–800), uma só família.
- Cantos: 18 px nos cartões, pílulas nos botões e fichas.
- Sombra suave em vez de contorno.
- Movimento: só o ♥ (salta) e o abrir do roteiro (desliza 4 px). Nada se mexe
  com "reduzir movimento".

## Recusas

- Nada de postais, carimbos, papel creme ou rotações.
- Nada que pareça loja: sem preços em destaque, sem "comprar", sem banners.
  O orçamento é uma margem por pessoa, numa ficha discreta.
- Nada inventado: a capa sem fotos usa só as coordenadas que o itinerário já
  mostra; nenhuma fotografia de banco de imagens.
