# Estado
VPS: vps2 (194.163.134.245), usuario pteuz. Projeto: /opt/modular-agentes. Ferramentas: .tools/ (ignorado no git); `source env.sh`.
Etapa atual: 0 (Canal), branch etapa-0. Amarula testado; BaileysEx pendente.

## Portas
Faixa reservada: 4100-4119 (livre em 2026-10-16). Em uso na VPS: 22 53 80 81 443 631 5432 5499.

## Ambiente
Instalados sem sudo (hashes SHA256 conferidos com builds.hex.pm): OTP 28.5.0.8, Elixir 1.19.6-otp-28, Hex 2.5.3.
Postgres 16.15 ativo. Ausentes: rust/cargo (BaileysEx precisa, via NIF Rustler), go. Banco do projeto: nao criado.

## Etapa 0 - Amarula 0.5.10 (puro Elixir, fixado com ==; deps transitivas fixadas em spike/amarula/mix.lock, nao auditadas)
Codigo lido: so conecta a hosts do WhatsApp, sem shell/eval/phone-home; sessao em AMARULA_DATA_DIR (term files).
Medido (1 sessao, 2026-10-16): pareamento por QR ok; envio ao proprio chat ok; reconecta apos reiniciar processo em ~1 s sem QR;
chat proprio detectado (own_chat?) e msg de terceiro ignorada; RSS 93-103 MB vs 65 MB do BEAM vazio (~30-38 MB por sessao); sessao em disco ~150 KB.
ESTIMATIVA 50 tenants: 65 + 50x35 ~ 1,8 GB (multiplicacao de 1 sessao; crescimento real nao medido).
Ressalva: a biblioteca recebe tambem mensagens de terceiros e guarda chaves de grupos; o filtro do chat proprio e nosso (own_chat?).
Estabilidade de varios dias: verificar na etapa 1.

## Em aberto
Ver docs/modelo.txt. Etapa 0: testar BaileysEx (exige Rust e desvincular o aparelho) e decidir o canal.

## Proximo passo
Instalar Rust em .tools, ler fonte de baileys_ex 0.1.0-alpha.12, desvincular Amarula, testar BaileysEx, decidir. PARADA.
