# Etapas
Etapa 0 - Canal. Verificar elixir, OTP, rust, postgres. Ler o codigo-fonte de cada lib de WhatsApp antes de instalar (ha relato de pacote malicioso imitando o Baileys) e fixar versao exata. Testar BaileysEx e Amarula um de cada vez (desvincular antes de trocar; Mateus escaneia o QR). Numero so para conversar com o Mateus, volume baixo (risco de banimento). Medir memoria da sessao e reconexao apos reinicio sem novo QR. Estabilidade de varios dias e verificada na etapa 1. Extrapolar 50 tenants = medida x 50, declarar estimativa. Pronto: decisao em docs/estado.md (Elixir, ou Go com whatsmeow atras do mesmo contrato) com numeros medidos. PARADA.
Etapa 1 - Nucleo minimo. Registro (estado versionado, separado do codigo), vinculo e manifesto de versoes exatas, laco (esqueleto), gancho, operacao de vincular (idempotente, evento) e canal atras do contrato. Pronto: dois tenants vinculados, estado proprio, sem enxergar um ao outro; mensagem entra e sai pelo canal de cada um (um real, um simulado com o mesmo contrato); manifesto lista versoes exatas; canal ignora mensagens fora do chat do proprio usuario.
Etapa 2 - Contrato de automacao. Behaviours: declara oferece/exige (versao do contrato separada da versao do codigo), referencial, o que reter e como e lido de volta, acoes que exigem aprovacao. Pronto: vinculo incompativel recusado. PARADA para aprovar o contrato.
Etapa 3 - Automacao de teste, sem dominio. Verificador decidivel; molde da primeira versao generica. Pronto: laco completo; verificador acusa a regra violada; estado retido e lido de volta muda a saida; atualizar versao preserva estado do tenant; gancho intercepta uma acao.
Etapas 4+ (trafego, redes sociais): so apos aprovacao da etapa 3 e definicao da seguinte.
Etapa 3.1 - Correcoes antes do trafego. (A) Nucleo e cada automacao viram pacotes Mix independentes no mesmo repositorio (tag propria: nucleo-X.Y.Z, eco-X.Y.Z); o cliente depende de cada um por git + sparse + tag (spike antes; se falhar, parar e propor); atualizar uma automacao = trocar a tag dela. Sem reescrever logica. Manifesto validado contra as versoes carregadas (Application.spec vsn); divergencia e erro. (B) Encaixe (oferta/exigencia, MAJOR.MINOR) checado tambem ao atualizar: ao registrar nova versao, reverificar todos os vinculos que a envolvem; se algum quebrar, recusar tudo, evento atualizacao_recusada com o vinculo que quebraria, estado e manifesto intactos. Na inicializacao, validar vinculos contra as versoes carregadas: incompativel = inativo_incompativel com evento, a automacao nao roda para o tenant, os demais seguem (ANTES de implementar: propor em 3 linhas e esperar). Teste geral (1): cliente fixa nucleo e Eco por tag, trocar so a tag da Eco muda so a Eco no mix.lock, manifesto bate com o carregado; tenant com automacao B que exige Eco MAJOR 1: Eco 1.1 aceita, 2.0 recusada com evento, estado e manifesto intactos; limpa tenants ta*/tb* no inicio. Fora do escopo: Nucleo.Passo, Oban, verificadores empiricos/humanos, credenciais de anuncio, automacao de dominio (etapa 4). Pronto: teste geral passando, etapas 1-3 passando, estado.md (<=30 linhas) e etapas.md atualizados, resumo ate 10 linhas. PARADA antes do merge.
Etapa 3.1 FEITA (resumo): pacotes packages/nucleo e packages/eco; cliente por git+sparse+tag sem override; Manifesto.validar; Vincular.atualizar (B.1); Nucleo.Inicializacao (B.2: so contrato MAJOR.MINOR desativa; reativa sozinho; versao de codigo so atualiza o registrado; contrato registrado na primeira inicializacao; log dos inativos). Teste: test/etapa31_test.exs.

ETAPA 4 - TRAFEGO PARA CORRETORES (para o Claude Code)

Acrescente esta etapa a docs/etapas.md. Procedimento de sempre: ler CLAUDE.md e docs/estado.md, escrever o teste geral ANTES de construir cada sub-etapa, branch etapa-4-N, quebras em docs/correcoes.md, PARADA para aprovacao no fim de cada sub-etapa. Sessao nova por sub-etapa.

ENTRADAS (copie para docs/ na 4.0)
- criterios-trafego-corretores.txt -> docs/trafego.txt (fonte das regras de dominio; nao altere sem pedir).
- Interface: o Mateus aprovou o esboco de UI/UX (identidade e 11 telas). Ele passa o link/prints; a especificacao minima esta abaixo e deve ir para docs/interface.md.

INTERFACE (docs/interface.md)
- Celular primeiro, PC adaptado. Uma coluna, alvos de toque >= 48 px, barra inferior (corretor: Inicio, Campanhas, Agente, Conta; admin: Painel, Equipe, IA, Alertas). Desktop: barra lateral, conteudo fluido.
- Cores: Cobalto #2B44C8 (acao e tudo que o agente fez), Nevoa #E9EDFB, Papel #F7F6F2 (fundo), Branco #FFFFFF (cartoes), Tinta #14161F, Linha #E7E5DE, Ok #1F7A5A, Atencao #A8620B, Erro #B3362F. Contraste minimo 4.5:1.
- Fontes: Geist (texto, titulos 600) e Geist Mono (numeros, ids, eventos, R$). Servir as fontes localmente, sem CDN.
- Marca: dois aneis sobrepostos com um ponto no encaixe, em cobalto; nome "modular agentes".
- Estado nunca so por cor: ponto/icone + rotulo. Mensagens do agente em bloco Nevoa com prefixo [agente].
- O painel mostra o plano; a autorizacao acontece no WhatsApp (nunca um botao "confirmar" no painel).
- Telas: login (com convite, recuperacao de senha); corretor: inicio, plano aguardando, campanha, conta/WhatsApp (QR e estado); admin: equipe (busca, filtro cruzado, status), corretor (campanhas, cadastro, IA, desativar/excluir), aba IA (Planejador, Executor, Verificador, Monitor; Fez/Aprendeu/Erros), painel geral, alertas, auditoria.
- Pagina: server-rendered leve (Phoenix LiveView recomendado; confirme na 4.0). Sem framework JS pesado.

AMBIENTE (acrescenta ao prompt de producao)
- Dominio: agente.khoral.com.br (DNS ja configurado). Proxy reverso: nginx na vps2.
- O Mateus confirma o dominio no painel/dashboard do nginx. Voce NAO altera a configuracao do nginx, certificados ou DNS. Na 4.3 voce entrega ao Mateus os valores exatos (dominio, porta de destino da faixa reservada, websocket habilitado para LiveView) e ele aplica. Verifique antes como o nginx esta instalado (comum ou com painel) e relate em 2 linhas.
- Email: SMTP da Hostinger (smtp.hostinger.com:465 SSL/TLS). Usuario e senha ficam so em env (/opt/modular-agentes-data), que o Mateus preenche. Nunca no repositorio, nunca em log. Nao altere SPF/DKIM/DNS.
- Segredos: chave de cifra das credenciais de anuncio e chave da OpenAI tambem so em env. Credenciais cifradas no banco (token da BM, ids), mascaradas na tela, nunca em log nem em evento.

MODELOS DE IA (OpenAI, configuravel, nada fixo no codigo)
- Duas faixas configuraveis: pequena (ler confirmacao em texto livre, conferir criativo) e media (criar e revisar o plano).
- Antes de escolher, consulte a lista e os precos ATUAIS na documentacao oficial da OpenAI (as fontes divergem) e evite modelos com aposentadoria anunciada (ex.: gpt-4.1-nano e o4-mini saem em 23/10/2026). Comece com a menor que passar no teste da 4.2. Relate escolha, preco e motivo em 3 linhas e espere o Mateus.
- Custo de tokens registrado por evento, em R$ (cotacao diaria; fonte da cotacao: proponha na 4.5).
- Tudo atras de um contrato "provedor de IA" (trocar de modelo/provedor nao muda o dominio). Em teste, use um provedor falso deterministico.

REGRAS DE SEGURANCA DE GASTO
- Ate o fim da 4.4 nenhuma campanha e ativada. So CRUD, sempre pausada.
- Escrita na Meta so em conta de teste do Mateus e so depois da aprovacao dele (PARADA antes da primeira escrita real). Leitura para validar o token pode rodar antes.
- O agente so toca na conta de anuncio do corretor do tenant, mesmo que o token alcance mais; id de conta nunca vem do modelo de IA, vem do registro do tenant.
- Qualquer alteracao exige: o agente diz o que vai fazer, o corretor confirma em texto livre, a IA le a confirmacao; resposta ambigua -> pergunta curta de novo ("so pra confirmar se entendi, posso fazer isso mesmo?"). Sem confirmacao clara, nada executa.
- Privacidade: o admin ve o que o agente fez, nunca a conversa do corretor consigo mesmo.

AUTORIZADO NESTA ETAPA (alem do que ja estava)
- Adicionar Oban (fila de pendencias: planos aguardando confirmacao, monitor agendado) e migracoes das novas tabelas.
- Criar pacotes novos no repositorio do projeto, cada um com tag propria: trafego, painel-base, gestao-equipe (como a Eco: pacote Mix, contrato, versao de contrato MAJOR.MINOR). Gestao de equipe le o trafego so pela fronteira do contrato; trafego e painel-base nao dependem dela. Uma instancia de uma pessoa funciona sem gestao-equipe.
- Dependencias Elixir novas (LiveView, Swoosh, cliente HTTP, cifra): leia o que adicionar, fixe versao exata, relate.

PARADAS EXTRAS
- Qualquer item "em aberto" do modelo ou do docs/trafego.txt (teto de gasto por campanha, formato do feed, fonte da cotacao): proponha em 3 linhas e espere.
- Promocao de Nucleo.Passo ao nucleo: decidir no fim da 4.5 com dois exemplos reais; nao antes.
- Antes de mudar docs/modelo.txt.

SUB-ETAPAS

4.0 Preparacao (sem construir dominio)
- Corrigir o aviso "inicializacao nao validou" (validacao rodava antes da migracao); registrar em correcoes.md.
- Copiar docs/trafego.txt e escrever docs/interface.md.
- Propor em ate 10 linhas e esperar: onde mora o login (recomendacao: pacote painel-base), LiveView, uso do Oban, cifra das credenciais, tipos de verificador usados (decidivel; empirico com atraso no monitor; humano = confirmacao do corretor), formato do evento do tenant.
Pronto: proposta aprovada.

4.1 Base generica de agentes com plataforma SIMULADA (sem Meta, sem OpenAI reais)
- Contrato de plataforma de anuncios (behaviour: validar credencial, criar/ler/editar/pausar campanha incluindo conjunto e anuncio) com adaptador simulado em memoria/banco.
- Plano generico v1 (destino site/WhatsApp direto/formulario; resultado derivado do destino; publico; criativo; orcamento diario e teto; janela; meta; imovel opcional). Cada destino declara exigencias; plano so confirma com exigencias satisfeitas (mesmo mecanismo de oferta/exigencia do nucleo).
- Papeis: planejador (IA, via provedor falso), executor (sem IA, cria pausado), verificador decidivel (execucao bate com o plano), monitor (esqueleto, sem agendar ainda).
- Eventos do tenant: pedido, plano, confirmacao, operacao, verificacao, resultado, custo em tokens. Aba IA e projecao desses eventos.
- Aprendizado minimo por tenant: situacao, acao, resultado contra a meta, regra violada nomeada; ao propor, le registros parecidos. Promocao ao catalogo manual (so a estrutura).
- Gancho: nenhuma alteracao sem confirmacao.
TESTE GERAL 4.1: pedido -> plano -> confirmacao em texto livre (clara, ambigua que repergunta, negativa) -> execucao pausada na plataforma simulada -> verificador acusa divergencia injetada; dois tenants com contas diferentes nao se enxergam; agente tentando acessar conta de outro tenant e barrado; erro vira registro e muda a proposta seguinte (estado lido de volta); atualizar versao do pacote trafego preserva o estado.
STATUS 4.1: pronta em 2026-10-16 (branch etapa-4-1, test/etapa41_test.exs, packages/trafego), aguardando aprovacao do Mateus.

4.2 Meta real e OpenAI real (fase 1)
- Adaptador Meta (leitura e escrita; Graph API; versao fixada; leia a documentacao oficial atual). Credenciais do tenant cifradas; validacao ao cadastrar (alcanca pagina, conta de anuncio e Instagram); status "token invalido".
- Provedor OpenAI real nas duas faixas; escolha de modelo conforme regra acima.
- Criativo: conferencia decidivel de formato, proporcao e resolucao; recebimento de midia pelo canal (Amarula) a verificar aqui; se nao receber, relate e proponha alternativa.
- Primeiro teste real: leitura com a conta do Mateus. PARADA. Depois, com aprovacao, criar uma campanha PAUSADA em conta de teste e verificar.
TESTE GERAL 4.2: ponta a ponta real em conta de teste, tudo pausado, verificador confere o que a Meta devolveu; custo de tokens registrado; token nunca aparece em log.
4.2 FEITA ATE A PARADA (resumo): cifra AES-256-GCM (chave so em env), adaptador Meta (Graph v26.0 fixada, tudo PAUSED), provedor OpenAI (gpt-6-luna nas duas faixas, config), conferencia decidivel de criativo, midia pelo canal (Agente.receber_midia), custo de tokens em R$ por evento. TESTE GERAL 4.2 passa com servidores falsos (test/etapa42_test.exs). FALTA, com o Mateus: segredos em /opt/modular-agentes-data/trafego.env, autorizacao da 1a LEITURA real (Meta e OpenAI), depois (outra aprovacao) campanha PAUSADA na conta de teste e a prova de recepcao de midia na CDN real do WhatsApp.

4.3 Painel base, dominio e WhatsApp pelo site
- STATUS: implementada na branch etapa-4-3, teste geral e etapas anteriores passando (12 testes); aguarda aprovacao, dominio/TLS (Mateus) e SMTP (Mateus).
- Pacote painel-base: login, convite por email, definicao de senha, verificacao de email, recuperacao de senha (SMTP via env). Sem 2 fatores por ora. Sessao segura, limite de tentativas.
- Pagina do corretor: conta, campanhas e metricas (gasto, alcance, cliques, mensagens iniciadas, custo por resultado, 7 dias), plano aguardando, conexao do WhatsApp (QR e estado) via canal Amarula, uma sessao por tenant.
- UI conforme docs/interface.md.
- Entregar ao Mateus os valores do nginx (dominio, porta, websocket). PARADA ate ele confirmar o dominio e o TLS.
TESTE GERAL 4.3: convite -> senha -> login -> ver campanhas proprias -> QR/estado do WhatsApp; usuario A nunca ve dados do B; email de recuperacao chega (ambiente do Mateus).

4.4 Gestao de equipe
- STATUS: implementada na branch etapa-4-4, teste geral e etapas anteriores passando (18 testes, 0 falhas); APROVADA, na main, tags publicadas.
- Pacote gestao-equipe: papeis (dono cria admins; admin cadastra corretores; corretor), cadastro com todos os campos (G3 do trafego.txt), unicidade de usuario/email/numero, o cadastro dispara o vincular do tenant, filiacao em texto livre com sugestao, lista com filtro cruzado, pagina do corretor para o admin, desativar (reversivel) separado de excluir (apaga dados pessoais e desvincula a sessao; campanha na Meta nao e apagada), painel geral, status e alertas, log de auditoria.
TESTE GERAL 4.4: admin cadastra corretor -> tenant vinculado -> corretor completa pelo convite; desativar bloqueia o agente; excluir apaga dados pessoais; admin nao ve a conversa propria; instancia de uma pessoa funciona sem este pacote.

4.5 Fase 2: ativacao com confirmacao
- STATUS: implementada na branch etapa-4-5, teste geral (10 testes) e etapas anteriores passando; AGUARDA APROVACAO (sem merge, sem tags). Decisoes aprovadas pelo Mateus: feed = dump .sql da wp_produtos importado para feed_imoveis (estado_obra e so informativo desde a 4.6); cotacao = PTAX do Banco Central; teto_total obrigatorio + maximo por tenant + teto mensal de IA em R$ por corretor. Ativacao real na Meta segue travada.
- Ativar campanha somente com confirmacao em texto livre; monitor agendado (Oban) compara resultado e meta (meta batida, desvio, dados insuficientes); relatorios com limite de frequencia e resumo; desvio que queima verba pode alertar na hora; ajuste sempre como proposta confirmada.
- Custo de IA em R$ com cotacao diaria e teto por corretor (aviso e bloqueio); proponha a fonte da cotacao e o teto por campanha (paradas).
- Feed de imoveis: o Mateus expoe; aqui so a leitura sem status de imovel (4.6 retirou o esgotado).
- Fim: decidir Nucleo.Passo com dois exemplos.
TESTE GERAL 4.5: ativacao so apos confirmacao clara; desvio gera proposta e nao alteracao; teto de IA bloqueia (a regra de esgotado saiu na 4.6).

FORA DO ESCOPO
Publico de pessoas e LAL, etapas encadeadas, modelo de plano escrito pela equipe, Google Ads, criacao de pixel/eventos, funil depois do clique, redes sociais, 2 fatores.

PRONTO (cada sub-etapa)
Teste geral passando, mix test das etapas anteriores passando, docs/estado.md e docs/etapas.md atualizados, resumo de ate 10 linhas, PARADA para aprovacao antes do merge.

4.6 Correcoes (Mateus)
- STATUS: branch etapa-4-6; teste test/etapa46_test.exs. AGUARDA APROVACAO (sem merge, sem tags).
- Correcao 1 (feita): imovel nao tem status. Sai a regra esgotado/vendido -> evento + proposta de pausar + bloqueio de ativacao (trafego 1.4.1). Feed serve id, nome, bairro/regiao, dormitorios, valor, imagem, url, data; estado_obra so informativo.
- Correcao 2 (feita; teste test/etapa46b_test.exs): dono e admin com tenant proprio (o do dono, `mateus`, e preservado e so ganha vinculos), WhatsApp/QR, plano + confirmacao e campanhas como o corretor, telas de corretor + atalhos, isolamento e privacidade, desativar/excluir e auditoria mantidos. gestao-equipe 1.1.0, painel-base 1.1.1.
- Implantacao (depende de aprovacao): mix equipe.garantir EMAIL do dono; reiniciar o painel.

5.7 Diretrizes da Iara, passo 1 (trafego 1.12.2)
- STATUS: branch diretrizes; teste test/etapa57_test.exs. AGUARDA APROVACAO (sem push, merge, tag nem deploy).
- A politica de conversa.ex virou lista de diretrizes (packages/trafego/lib/trafego/diretrizes.ex); casamento por estado em codigo, nenhuma chamada nova ao modelo. Com apresentacao pendente o texto e byte a byte o da politica antiga.

5.8 Diretrizes da Iara, passo 2 (trafego 1.12.3)
- STATUS: branch diretrizes2; teste test/etapa58_test.exs. AGUARDA APROVACAO (sem push, merge, tag nem deploy).
- A: regra g (:depois_da_pergunta) so casa com o marcador pergunta_aberta no iara_perfil (liga em marcar_campanha_perguntada/1, desliga no primeiro turno posterior da Conversa que finaliza; fallback nao desliga; legado sem campo = desligado, sem migracao). Linha ESTADO intacta.
- B: cada diretriz tem valida opcional; Conversa.validar roda os validadores das diretrizes casadas no inicio do turno mais os globais. Mesmas rejeicoes nos mesmos casos.
- C: a ferramenta apresentacao so e oferecida quando a diretriz :apresentacao casa; combinar_horario fica sempre.
- Sem chamada nova ao modelo, sem mudanca no contrato Nucleo.Automacao. etapa57 (a)/(b): assert da regra g antiga trocado por refute (marcador desligado).
- Passo 3 (nao implementado): promover Diretrizes ao nucleo como callback opcional quando a automacao de redes sociais precisar.
