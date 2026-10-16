# Correcoes
data | peca (registro, vinculo, laco, gancho ou canal) | o que quebrou | por que | como foi corrigido
2026-10-16 | registro (teste) | mix test nao rodou: faltava test/test_helper.exs | o ExUnit.start estava no proprio teste, mix exige o helper | helper de 1 linha; teste continua unico
2026-10-16 | canal | sessao Amarula da etapa 0 pedia QR de novo ("No stored credentials") | aparelho foi desvinculado ao trocar de lib | re-pareamento via scripts/pareia.sh; reconexao sem QR ja medida na etapa 0
2026-10-16 | vinculo (config de teste) | test/etapa2_test.exs nao era executado | mix.exs tinha test_pattern fixo em etapa1_test.exs | pattern passou a "etapa[12]_test.exs"
2026-10-16 | gancho | laco caiu ao interceptar acao com aprovacao: ArgumentError | config sem aprovado_<acao> devolve nil e o operador not exige booleano | trocado por !
2026-10-16 | registro/vinculo (spike 3.1) | deps.get no cliente: "App nucleo lists itself as a dependency" / modulo duplicado | todos os pacotes usavam o mesmo modulo de projeto (P.MixProject) e o Mix carrega todos na mesma VM | modulo de projeto com nome unico por pacote (PNucleo.MixProject, PEco.MixProject)
2026-10-16 | vinculo (teste 3.1) | deps.get do cliente de teste divergia: eco vinha com path ../nucleo | o subprocesso herdava NUCLEO_LOCAL=1 posto pelo mix.exs da raiz | o teste desfaz NUCLEO_LOCAL no ambiente do cliente
2026-10-16 | registro | atualizar/vincular falhou: coluna contrato inexistente | migracao nova (ALTER TABLE vinculos ADD COLUMN IF NOT EXISTS contrato) ainda nao escrita | migrar!/0 passou a adicionar a coluna
2026-10-16 | nucleo (Application) | aviso "inicializacao nao validou" no start (coluna estado/contrato inexistente) | a validacao na inicializacao rodava antes da migracao que cria as colunas novas de vinculos | Application.start roda Registro.migrar!() (idempotente) antes de Inicializacao.validar_todos()
