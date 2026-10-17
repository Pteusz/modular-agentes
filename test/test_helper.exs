# Chave de cifra SO de teste (constante publica, nao protege nada). Em producao vem de /opt/modular-agentes-data.
System.put_env("TRAFEGO_CIFRA_CHAVES", "t1:" <> Base.encode64(:binary.copy(<<7>>, 32)))
System.put_env("TRAFEGO_CIFRA_ATUAL", "t1")
Code.require_file("http_falso.exs", __DIR__)
# painel-base em teste: e-mail no adaptador de teste do Swoosh (cai na caixa do processo), recuperacao sincrona, PBKDF2 barato.
Application.put_env(:painel_base, :mailer_adapter, Swoosh.Adapters.Test)
Application.put_env(:painel_base, :recuperar_async, false)
Application.put_env(:painel_base, :iteracoes_pbkdf2, 1000)
ExUnit.start()
