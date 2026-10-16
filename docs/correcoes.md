# Correcoes
data | peca (registro, vinculo, laco, gancho ou canal) | o que quebrou | por que | como foi corrigido
2026-10-16 | registro (teste) | mix test nao rodou: faltava test/test_helper.exs | o ExUnit.start estava no proprio teste, mix exige o helper | helper de 1 linha; teste continua unico
2026-10-16 | canal | sessao Amarula da etapa 0 pedia QR de novo ("No stored credentials") | aparelho foi desvinculado ao trocar de lib | re-pareamento via scripts/pareia.sh; reconexao sem QR ja medida na etapa 0
