# Estado
VPS: vps2 (194.163.134.245), usuario pteuz. Projeto: /opt/modular-agentes. Ferramentas em .tools/ (fora do git); `source env.sh`.
Etapa atual: 2 construida, aguardando aprovacao do contrato (branch etapa-2; etapa 1 aprovada e na main). Proxima: etapa 3.

## Portas
Faixa reservada: 4100-4119 (livre em 2026-10-16). Em uso na VPS: 22 53 80 81 443 631 5432 5499.

## Ambiente
Sem sudo, SHA256 conferido: OTP 28.5.0.8, Elixir 1.19.6-otp-28, Hex 2.5.3, Rust 1.99.1 (so BaileysEx). Postgres 16.15 ativo; banco modular_agentes (papel modular), URL em /opt/modular-agentes-data/db.env.

## Decisao do canal (APROVADA pelo Mateus, 2026-10-16)
Amarula 0.5.10 (puro Elixir, fixado com ==; deps transitivas so fixadas no mix.lock, nao auditadas). Pilha Elixir/OTP, sem Go.
Medido, 1 sessao: reconecta ~1 s sem QR; RSS 93-103 MB vs 65 MB do BEAM vazio (~30-38 MB/sessao); sessao ~150 KB; chat proprio detectado (own_chat?), terceiros ignorados.
ESTIMATIVA 50 tenants: 65 + 50x35 ~ 1,8 GB (1 sessao x 50; crescimento real nao medido).
Descartado: BaileysEx 0.1.0-alpha.12 (alpha, NIF Rust, reconecta ~3 s, RSS 100-112 MB, ~2,1 GB estimado; exige reconnect_policy e pre-carga de modulos; chat proprio vem como @lid).
Risco: rota nao oficial/banimento; a lib recebe msgs de terceiros, o filtro e nosso. Sessoes dos spikes sao de teste: na etapa 1 parear de novo (desvincular BaileysEx no celular).

## Em aberto
Ver docs/modelo.txt. Estabilidade de varios dias: verificar na etapa 1 (sem bloquear).

## Etapa 1 (nucleo minimo) - pronta p/ aprovacao
App unico (mix.exs na raiz, sem umbrella/Oban ainda), Postgrex 0.22.4 + Jason 1.4.5 + Amarula 0.5.10 fixados com ==. lib/nucleo/: registro (estado so-insert versionado, eventos, vinculos), vincular (idempotente, evento), manifesto, canal (behaviour) + simulado + amarula, laco (1 processo/tenant), gancho. Teto de envio: config teto_por_min (padrao 10); respostas com prefixo "[agente] ".
Teste: `set -a; source /opt/modular-agentes-data/db.env; set +a; MIX_ENV=test mix test` (test/etapa1_test.exs; deixa tenants ta*/tb* no banco). Demo real: scripts/pareia.sh (QR) com tenant mateus (Amarula) + sim (simulado). Sessao Amarula em /opt/modular-agentes-data/amarula/mateus (re-pareada em 2026-10-16).
Gancho esqueleto so registra/bloqueia por config. Estabilidade de varios dias: nao medida ainda.
## Etapa 2 (contrato de automacao) - pronta p/ aprovacao
lib/nucleo/automacao.ex: behaviour Nucleo.Automacao (versao/0 do codigo; contrato/0 = %{versao MAJOR.MINOR, oferece, exige}; referencial/0; retencao/0; aprovacao/0). Nucleo fornece "registro","gancho","canal.texto" 1.0; a camada do cliente fornece o resto (mapa cap=>versao).
Decisoes (Mateus): compativel se MAJOR do contrato = MAJOR do nucleo (1) e, por exigencia, MAJOR igual e MINOR fornecido >= exigido; encaixe declarado, checado so em Vincular.vincular/4 (modulo, canal, camada) ANTES de gravar; recusa = evento vinculo_recusado + {:error,{:incompativel,motivos}}, vinculo anterior intacto. Verificador: so :decidivel (outros recusados). Vincular segue funcao chamada pelo Mateus.
Teste: test/etapa2_test.exs (mix test roda etapas 1 e 2; etapa 0 por `elixir test/etapa0_test.exs`).
## Proximo passo
Aprovar contrato (merge etapa-2) e iniciar etapa 3 (automacao de teste, verificador decidivel).
