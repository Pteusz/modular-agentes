# Nucleo.Passo: decisao proposta (fim da 4.5) - SO PROPOSTA, nada promovido

Pergunta: `Nucleo.Passo` (hoje `passo(entrada, retido) -> %{saida, retido, acoes}`) deve virar a interface de execucao do nucleo?

## Dois exemplos reais

1. **Eco** (`Nucleo.Automacoes.Eco`, implementa Passo): funcao pura. O laco le o estado (`retencao/0`), chama `passo/2`, passa o resultado pelo Verificador e pelo Gancho, grava o estado e responde. O laco faz TODA a E/S; a automacao so decide. Cabe no Passo.
2. **Trafego** (`conversar/2`, `midia/2`, e agora `Monitor.rodar/2`): nao cabe no Passo. A resposta depende de chamadas externas (IA, plataforma de anuncios), grava estado no meio do caminho (plano, proposta, evento de custo), tem estado proprio por tenant e, na 4.5, tambem age SEM mensagem: o monitor (Oban) dispara por horario e avisa o corretor (`Nucleo.Laco.avisar/2`). O laco hoje a chama por `function_exported?(mod, :conversar, 2)`, sem behaviour.

## O que os exemplos mostram
- Passo serve ao caso "decisao pura, laco faz a E/S". E um bom contrato para isso e nao deve mudar.
- Trafego precisa de outro formato: conversa com efeitos, midia e saida proativa. Forcar isso em `passo/2` empurraria IA, plataforma e gancho para dentro do laco (ou esconderia efeitos num "retido" que nao e estado).
- O disparo por horario (Oban) nao e preocupacao do laco: o monitor so precisa de um caminho de saida (`Laco.avisar/2`, que passa por prefixo, teto de envio e gancho, como qualquer resposta).

## Proposta (para decisao do Mateus)
1. **Manter** `Nucleo.Passo` como esta (Eco). Nao promover a interface unica.
2. **Formalizar o que ja existe** em um segundo behaviour no nucleo, `Nucleo.Conversa`: `conversar(tenant, texto) :: {:ok, String.t()} | {:error, term}` e `midia/2` opcional. Sem mudar comportamento: so troca `function_exported?` por `@behaviour`. Contrato do nucleo sobe MINOR (nucleo 1.4.0).
3. **Manter `Nucleo.Laco.avisar/2`** (ja no nucleo 1.3.0) como unica porta de saida proativa.
4. **Oban continua dentro de painel-base/trafego**; so sobe ao nucleo quando uma terceira automacao precisar de agenda (regra: nada no nucleo por antecipacao).

Nada disso foi implementado; depende da aprovacao.
