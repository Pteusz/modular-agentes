# Estado
VPS: vps2 (194.163.134.245), usuario pteuz. Projeto: /opt/modular-agentes. Ferramentas em .tools/ (fora do git); `source env.sh`.
Etapa atual: 3.1 EM ANDAMENTO (branch etapa-3-1; etapas 0-3 aprovadas e na main). Parte A e B.1 prontas; B.2 (init) aguarda proposta/aprovacao.
Faixa reservada: 4100-4119. Em uso na VPS: 22 53 80 81 443 631 5432 5499.
Sem sudo: OTP 28.5.0.8, Elixir 1.19.6-otp-28, Hex 2.5.3. Postgres 16.15; banco modular_agentes (papel modular), URL em /opt/modular-agentes-data/db.env.
Canal: Amarula 0.5.10 (puro Elixir), sessao em /opt/modular-agentes-data/amarula/mateus. ~35 MB/sessao; 50 tenants ~1,8 GB (estimativa). Risco: rota nao oficial.
Teste: `set -a; source /opt/modular-agentes-data/db.env; set +a; MIX_ENV=test mix test` (etapas 1, 2, 3, 3.1; etapa 0 por `elixir test/etapa0_test.exs`).
## Decisoes fechadas
- Contrato Nucleo.Automacao 1.0: oferece/exige, MAJOR igual e MINOR fornecido >= exigido; Nucleo.Passo separado do contrato. Verificador so :decidivel.
- 3.1 A: pacotes Mix packages/nucleo e packages/eco no mesmo repo; raiz = projeto-hospedeiro (path). Cliente: git + sparse + tag (nucleo-X.Y.Z, eco-X.Y.Z), SEM override: tags divergentes tem de ser alinhadas. Dev local: NUCLEO_LOCAL=1 (posto pelo mix.exs da raiz) troca git por path; NUCLEO_GIT muda a URL.
- REGRA: modulo de projeto com nome unico por pacote (PNucleo.MixProject, PEco.MixProject); senao o Mix colide na mesma VM.
- Manifesto: Nucleo.Manifesto.validar(%{app => vsn}) compara com Application.spec; divergencia = erro. Pacote se declara com env nucleo_pacote: true.
- 3.1 B.1: Vincular.atualizar(nome, modulo, camada) reverifica vinculos de todos os tenants (oferta e exigencia; contrato guardado em vinculos.contrato); quebra = recusa total + evento atualizacao_recusada.
## Em aberto
- B.2: na inicializacao validar vinculos contra versoes carregadas (inativo_incompativel). Proposta enviada ao Mateus; nada implementado.
- Tags nucleo-1.0.0/eco-1.0.0: criar e dar push so ao fechar a etapa, sem mover tags. Remover /opt/modular-agentes-cliente-exemplo/spike e t31 ao fim.
