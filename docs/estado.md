# Estado
VPS: vps2 (194.163.134.245), usuario pteuz. Projeto: /opt/modular-agentes. Ferramentas em .tools/ (fora do git); `source env.sh`.
Etapa atual: 3.1 pronta, aguardando aprovacao (branch etapa-3-1; etapas 0-3 aprovadas e na main). Proxima: definida pelo Mateus.
Faixa reservada: 4100-4119. Em uso na VPS: 22 53 80 81 443 631 5432 5499.
Sem sudo: OTP 28.5.0.8, Elixir 1.19.6-otp-28, Hex 2.5.3. Postgres 16.15; banco modular_agentes (papel modular), URL em /opt/modular-agentes-data/db.env.
Canal: Amarula 0.5.10 (puro Elixir), sessao em /opt/modular-agentes-data/amarula/mateus. ~35 MB/sessao; 50 tenants ~1,8 GB (estimativa). Risco: rota nao oficial.
Teste: `set -a; source /opt/modular-agentes-data/db.env; set +a; MIX_ENV=test mix test` (etapas 1, 2, 3, 3.1; ~2 min; etapa 0 por `elixir test/etapa0_test.exs`).
## Decisoes fechadas
- Contrato Nucleo.Automacao 1.0: oferece/exige, MAJOR igual e MINOR fornecido >= exigido; Nucleo.Passo separado do contrato. Verificador so :decidivel.
- 3.1 A: pacotes Mix packages/nucleo e packages/eco no mesmo repo; raiz = projeto-hospedeiro (path). Cliente: git + sparse + tag (nucleo-X.Y.Z, eco-X.Y.Z), SEM override: tags divergentes devem ser alinhadas. Dev local: NUCLEO_LOCAL=1 (posto pelo mix.exs da raiz) troca git por path; NUCLEO_GIT muda a URL, NUCLEO_TAG a tag do nucleo.
- REGRA: modulo de projeto com nome unico por pacote (PNucleo.MixProject, PEco.MixProject); senao o Mix colide na mesma VM.
- Tags publicadas (nunca mover/apagar): nucleo-1.0.0-rc1, eco-1.0.0-rc1 (resolucao limpa do GitHub validada), nucleo-1.0.0, eco-1.0.0.
- Manifesto: Nucleo.Manifesto.validar(%{app => vsn}) compara com Application.spec; divergencia = erro. Pacote se declara com env nucleo_pacote: true.
- B.1: Vincular.atualizar(nome, modulo, camada) reverifica vinculos de TODOS os tenants (contrato guardado em vinculos.contrato). Um vinculo incompativel barra a atualizacao para todos os tenants da instancia; recusa total + evento atualizacao_recusada.
- B.2: Nucleo.Inicializacao (no start e em Laco.iniciar): so incompatibilidade de contrato MAJOR.MINOR desativa (inativo_incompativel + evento, so aquele tenant/automacao, log lista os inativos); reavalia a cada inicializacao e reativa (vinculo_reativado); versao de codigo diferente com contrato compativel so atualiza a versao registrada (evento); vinculo sem contrato recebe o carregado (contrato_registrado).
## Em aberto
- Nada de B pendente. Etapa 4 (dominio) so apos aprovacao. Merge de etapa-3-1 na main aguarda o Mateus.
