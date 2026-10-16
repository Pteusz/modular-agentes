# Estado
VPS: vps2 (194.163.134.245), usuario pteuz. Projeto em /opt/modular-agentes.
Etapa atual: primeira sessao concluida; aguardando aprovacao para etapa 0 (Canal).

## Portas
Faixa reservada: 4100-4119 (verificada livre em 2026-10-16). Em uso na VPS: 22 53 80 81 443 631 5432 5499.

## Ambiente (2026-10-16)
Presentes: git 2.43.0, postgres 16.15 (servico ativo, 5432).
Ausentes: elixir, erlang/OTP, rust/cargo, go. Sem sudo sem senha: instalar exige o Mateus.
Banco dedicado do projeto: ainda nao criado.

## Decisoes fechadas
Nenhuma ainda (pilha Elixir/OTP + Postgres + Oban e recomendacao, a confirmar na etapa 0).

## Em aberto
Ver docs/modelo.txt, secao EM ABERTO.

## Proximo passo
Etapa 0: resolver como obter Elixir/OTP (e rust/Go se preciso) sem apt, depois testar BaileysEx e Amarula.
