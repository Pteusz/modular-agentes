# Interface (especificacao minima, aprovada pelo Mateus)
Fonte: etapa-4.txt (INTERFACE). Link/prints do esboco: o Mateus passa.

## Layout
- Celular primeiro, PC adaptado. Uma coluna, alvos de toque >= 48 px.
- Barra inferior SO no mobile (>= 48rem a navegacao fica no header). Corretor: Inicio, Campanhas, Agente; Conta e Sair no menu do usuario (header). Admin: Painel, Equipe, IA, Alertas.
- Desktop: barra lateral, conteudo fluido.

## Cores (contraste minimo 4.5:1)
| Nome | Hex | Uso |
|---|---|---|
| Cobalto | #2B44C8 | acao e tudo que o agente fez |
| Nevoa | #E9EDFB | bloco de mensagem do agente |
| Papel | #F7F6F2 | fundo |
| Branco | #FFFFFF | cartoes |
| Tinta | #14161F | texto |
| Linha | #E7E5DE | divisores |
| Ok | #1F7A5A | estado ok |
| Atencao | #A8620B | estado de atencao |
| Erro | #B3362F | estado de erro |

## Tipografia
- Geist (texto; titulos peso 600) e Geist Mono (numeros, ids, eventos, R$).
- Fontes servidas localmente, sem CDN.

## Marca
Dois aneis sobrepostos com um ponto no encaixe, em cobalto; nome "modular agentes".

## Regras de UI
- Estado nunca so por cor: ponto/icone + rotulo.
- Mensagens do agente em bloco Nevoa com prefixo [agente].
- O painel mostra o plano; a autorizacao acontece no WhatsApp (nunca um botao "confirmar" no painel).
- Pagina server-rendered leve (Phoenix LiveView recomendado; confirmar na 4.0). Sem framework JS pesado.

## Telas
- Login (com convite e recuperacao de senha).
- Corretor: inicio, plano aguardando, campanha, conta/WhatsApp (QR e estado).
- Admin: equipe (busca, filtro cruzado, status); corretor (campanhas, cadastro, IA, desativar/excluir); aba IA (Planejador, Executor, Verificador, Monitor; Fez/Aprendeu/Erros); painel geral; alertas; auditoria.
