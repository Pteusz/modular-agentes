# modular agentes
Ponteiros: docs/estado.md (comece aqui) | docs/etapas.md | docs/modelo.txt | docs/correcoes.md
Dados e segredos ficam em /opt/modular-agentes-data, nunca no repo. Sessao nova por etapa; leia so o necessario.

LIMITES (nunca, sem autorizacao do Mateus)
- Mexer fora de /opt/modular-agentes, /opt/modular-agentes-data, /opt/modular-agentes-cliente-exemplo e da faixa de portas (docs/estado.md).
- Parar/alterar outros servicos da VPS; instalar pacotes do sistema; tocar em outros bancos.
- Apagar dados, force push, reescrever historico; segredo ou sessao do WhatsApp no repo.
- Usar o numero do Mateus para algo alem de conversar com ele mesmo.
PARE E ESPERE: fim de cada etapa (resumo ate 10 linhas); contrato de automacao (etapa 2); itens "em aberto" do modelo (proponha em 3 linhas); mudanca em docs/modelo.txt; acao irreversivel.
Por etapa: teste geral ANTES (1 so, em test/), construir so a etapa, branch etapa-N, merge na main so apos aprovacao.
