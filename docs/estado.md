# Estado
VPS: vps2 (194.163.134.245), usuario pteuz. Projeto: /opt/modular-agentes. Ferramentas: .tools/ (ignorado no git); `source env.sh`.
Etapa atual: 0 (Canal), branch etapa-0. Amarula e BaileysEx testados. DECISAO PROPOSTA: Amarula, canal em Elixir (aguarda aprovacao).

## Portas
Faixa reservada: 4100-4119 (livre em 2026-10-16). Em uso na VPS: 22 53 80 81 443 631 5432 5499.

## Ambiente
Instalados sem sudo (hashes SHA256 conferidos com builds.hex.pm): OTP 28.5.0.8, Elixir 1.19.6-otp-28, Hex 2.5.3.
Postgres 16.15 ativo. Rust 1.99.1 em .tools (so BaileysEx exige). Ausente: go. Banco do projeto: nao criado.

## Etapa 0 - Amarula 0.5.10 (puro Elixir, fixado com ==; deps transitivas fixadas em spike/amarula/mix.lock, nao auditadas)
Codigo lido: so conecta a hosts do WhatsApp, sem shell/eval/phone-home; sessao em AMARULA_DATA_DIR (term files).
Medido (1 sessao, 2026-10-16): pareamento por QR ok; envio ao proprio chat ok; reconecta apos reiniciar processo em ~1 s sem QR;
chat proprio detectado (own_chat?) e msg de terceiro ignorada; RSS 93-103 MB vs 65 MB do BEAM vazio (~30-38 MB por sessao); sessao em disco ~150 KB.
ESTIMATIVA 50 tenants: 65 + 50x35 ~ 1,8 GB (multiplicacao de 1 sessao; crescimento real nao medido).
Ressalva: a biblioteca recebe tambem mensagens de terceiros e guarda chaves de grupos; o filtro do chat proprio e nosso (own_chat?).
Estabilidade de varios dias: verificar na etapa 1.

## Etapa 0 - BaileysEx 0.1.0-alpha.12 (NIF Rustler, alpha, fixado; fonte lida, sem achados)
Medido (1 sessao, 2026-10-16): pareamento ok so apos ligar reconnect_policy: :restart_required (padrao :disabled trava em 'conectando');
reconecta apos reiniciar em ~3 s sem QR; envio ao proprio chat ok; chat proprio chega como @lid (filtro precisa aceitar numero e LID); terceiros ignorados;
RSS 100-112 MB (~35-47 MB por sessao); exige Rust para compilar; carregar sessao do disco falha (binary_to_term :safe) sem pre-carregar os modulos.
ESTIMATIVA 50 tenants: 65 + 50x40 ~ 2,1 GB (1 sessao x 50; nao medido).

## Decisao do canal (proposta)
Amarula: puro Elixir, sem Rust, API estavel no teste, reconecta em ~1 s, ~10% menos memoria, menos armadilhas. Mantem pilha Elixir/OTP (sem Go).
Risco comum: rota nao oficial, banimento; ambas recebem msgs de terceiros, o filtro e nosso. Dependencias transitivas nao auditadas.

## Em aberto
Ver docs/modelo.txt. Estabilidade de varios dias: etapa 1. Banco do projeto: criar na etapa 1.

## Proximo passo
Aprovacao do canal (Amarula), merge etapa-0 na main, etapa 1. Falta o teste geral da etapa 0 em test/ (nao escrito).
