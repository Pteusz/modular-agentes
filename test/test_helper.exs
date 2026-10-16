# Chave de cifra SO de teste (constante publica, nao protege nada). Em producao vem de /opt/modular-agentes-data.
System.put_env("TRAFEGO_CIFRA_CHAVES", "t1:" <> Base.encode64(:binary.copy(<<7>>, 32)))
System.put_env("TRAFEGO_CIFRA_ATUAL", "t1")
Code.require_file("http_falso.exs", __DIR__)
ExUnit.start()
