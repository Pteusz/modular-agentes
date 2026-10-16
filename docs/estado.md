# Estado
VPS: vps2 (194.163.134.245), usuario pteuz. Projeto: /opt/modular-agentes. Ferramentas em .tools/ (fora do git); `source env.sh`.
Etapa atual: 0 concluida (canal aprovado: Amarula, Elixir). Proxima: etapa 1 (nucleo minimo).

## Portas
Faixa reservada: 4100-4119 (livre em 2026-10-16). Em uso na VPS: 22 53 80 81 443 631 5432 5499.

## Ambiente
Sem sudo, SHA256 conferido: OTP 28.5.0.8, Elixir 1.19.6-otp-28, Hex 2.5.3, Rust 1.99.1 (so BaileysEx). Postgres 16.15 ativo; banco do projeto nao criado.

## Decisao do canal (APROVADA pelo Mateus, 2026-10-16)
Amarula 0.5.10 (puro Elixir, fixado com ==; deps transitivas so fixadas no mix.lock, nao auditadas). Pilha Elixir/OTP, sem Go.
Medido, 1 sessao: reconecta ~1 s sem QR; RSS 93-103 MB vs 65 MB do BEAM vazio (~30-38 MB/sessao); sessao ~150 KB; chat proprio detectado (own_chat?), terceiros ignorados.
ESTIMATIVA 50 tenants: 65 + 50x35 ~ 1,8 GB (1 sessao x 50; crescimento real nao medido).
Descartado: BaileysEx 0.1.0-alpha.12 (alpha, NIF Rust, reconecta ~3 s, RSS 100-112 MB, ~2,1 GB estimado; exige reconnect_policy e pre-carga de modulos; chat proprio vem como @lid).
Risco: rota nao oficial/banimento; a lib recebe msgs de terceiros, o filtro e nosso. Sessoes dos spikes sao de teste: na etapa 1 parear de novo (desvincular BaileysEx no celular).

## Em aberto
Ver docs/modelo.txt. Estabilidade de varios dias: verificar na etapa 1 (sem bloquear).

## Proximo passo
Etapa 1 em sessao nova: criar banco Postgres dedicado; umbrella; registro, vinculo, manifesto, laco, gancho, canal atras do contrato.
