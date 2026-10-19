# Teste da correcao 5.1.1 (producao rodava com o provedor Falso; audio sem resposta; texto-base robotico e repetido).
# Escrito ANTES de corrigir. Rodar: MIX_ENV=test mix test test/etapa511_test.exs
# REGRA: tenants tpb_* (so os proprios dados). Nenhuma chamada real: IA pelo Falso e por provedores de teste locais.
defmodule IaBomba do
  @moduledoc false
  # provedor que explode: :falar devolve erro; as demais tarefas levantam; a transcricao funciona (bytes = texto falado)
  # salvo quando Process.get(:bomba) == :transcricao
  @behaviour Trafego.IA
  @impl true
  def chamar(_faixa, :falar, _entrada), do: {:error, :boom}
  def chamar(_faixa, _tarefa, _entrada), do: raise("boom")

  @impl true
  def transcrever(bytes, meta) do
    if Process.get(:bomba) == :transcricao, do: raise("boom"), else: Trafego.IA.Falso.transcrever(bytes, meta)
  end
end

defmodule IaEspia511 do
  @moduledoc false
  @behaviour Trafego.IA
  alias Trafego.IA.Falso
  @impl true
  def chamar(faixa, tarefa, entrada) do
    send(self(), {:ia, tarefa, entrada})
    Falso.chamar(faixa, tarefa, entrada)
  end

  @impl true
  def transcrever(bytes, meta), do: Falso.transcrever(bytes, meta)

  @impl true
  def turno(faixa, entrada), do: Falso.turno(faixa, entrada)
end

defmodule Etapa511Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, IA}
  alias Trafego.Plataforma.Simulada

  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar baixar_midia provedor_ia)a

  setup_all do
    Registro.migrar!()
    Trafego.Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}
    env = for k <- ~w(OPENAI_API_KEY TRAFEGO_IA), do: {k, System.get_env(k)}

    on_exit(fn ->
      limpar()
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
      for {k, v} <- env, do: (if v, do: System.put_env(k, v), else: System.delete_env(k))
    end)

    {:ok, config_original: salvo[:provedor_ia]}
  end

  setup do
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)
    Application.put_env(:trafego, :cotacao_usd_brl, 5.0)
    Application.put_env(:trafego, :provedor_ia, IaEspia511)
    Process.delete(:bomba)
    Application.put_env(:trafego, :notificar, fn _, _ -> :ok end)
    Application.put_env(:trafego, :baixar_midia, fn %{content: %{url: bytes}} -> if bytes == :falha, do: {:error, :x}, else: {:ok, bytes} end)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tpb\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tpb\\_%'", [])
  end

  defp resp({:ok, r}), do: r
  defp dizer(t, texto), do: resp(Agente.processar(t, texto))

  defp audio(bytes) do
    media = struct(Amarula.Content.Media, kind: :audio, mimetype: "audio/ogg; codecs=opus", seconds: 6, file_length: 9_000, url: bytes)
    %Amarula.Msg{channel: :teste, type: :media, raw: nil, content: media}
  end

  defp tenant_pronto do
    t = "tpb_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    t
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "provedor da IA por ambiente: chave OU TRAFEGO_IA=openai -> OpenAI; sem chave -> Falso; TRAFEGO_IA=falso vence" do
    env = fn m -> fn k -> Map.get(m, k) end end
    assert IA.escolher(env.(%{"OPENAI_API_KEY" => "sk-teste"})) == Trafego.IA.OpenAI
    assert IA.escolher(env.(%{"TRAFEGO_IA" => "openai"})) == Trafego.IA.OpenAI
    assert IA.escolher(env.(%{"TRAFEGO_IA" => "OpenAI", "OPENAI_API_KEY" => ""})) == Trafego.IA.OpenAI
    assert IA.escolher(env.(%{})) == Trafego.IA.Falso
    assert IA.escolher(env.(%{"OPENAI_API_KEY" => ""})) == Trafego.IA.Falso
    assert IA.escolher(env.(%{"OPENAI_API_KEY" => "   "})) == Trafego.IA.Falso
    assert IA.escolher(env.(%{"TRAFEGO_IA" => "falso", "OPENAI_API_KEY" => "sk-teste"})) == Trafego.IA.Falso
  end

  test "o ambiente de producao NAO vaza para a suite: com chave exportada o provedor de teste continua Falso", %{config_original: original} do
    # a config de teste (config/config.exs) fixa o Falso; o ambiente so vale quando NAO ha config
    assert original == {:ok, Trafego.IA.Falso}
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
    System.put_env("OPENAI_API_KEY", "sk-vazou")
    System.put_env("TRAFEGO_IA", "openai")
    assert IA.provedor() == Trafego.IA.Falso
    # e o padrao de producao (sem config) segue o ambiente
    assert IA.escolher() == Trafego.IA.OpenAI
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "Falso.transcrever recusa bytes que nao sao texto (audio real nunca vira 'fala')" do
    assert {:ok, "oi", _} = Trafego.IA.Falso.transcrever("oi", %{segundos: 3})
    assert {:error, :audio_nao_suportado} = Trafego.IA.Falso.transcrever(<<0xFF, 0xFE, 0x00, 0x01, 0x80>>, %{segundos: 3})
  end

  test "audio real com o provedor Falso: nunca silencio, resposta amigavel e nada alterado" do
    t = tenant_pronto()
    r = resp(Agente.receber_midia(t, audio(<<0xFF, 0xFE, 0x00, 0x01, 0x80, 0xC3, 0x28>>)))
    assert r =~ ~r/audio/i and r =~ "nada foi alterado"
  end

  test "excecao em qualquer ponto do audio vira resposta amigavel (nao propaga, nao fica mudo)" do
    t = tenant_pronto()
    Application.put_env(:trafego, :provedor_ia, IaBomba)

    # transcricao estoura
    Process.put(:bomba, :transcricao)
    assert resp(Agente.receber_midia(t, audio("quero uma campanha"))) =~ ~r/audio/i

    # transcricao ok, planejamento estoura
    Process.delete(:bomba)
    r = resp(Agente.receber_midia(t, audio("quero uma campanha")))
    assert is_binary(r) and r =~ "nada foi alterado"

    # download estoura / devolve lixo
    Application.put_env(:trafego, :baixar_midia, fn _ -> raise "rede" end)
    assert resp(Agente.receber_midia(t, audio("x"))) =~ ~r/audio/i
    Application.put_env(:trafego, :baixar_midia, fn _ -> :ok end)
    assert resp(Agente.receber_midia(t, audio("x"))) =~ ~r/audio/i
  end

  test "excecao no texto tambem responde, sem eco do conteudo" do
    t = tenant_pronto()
    Application.put_env(:trafego, :provedor_ia, IaBomba)
    r = dizer(t, "segredo do corretor 12345")
    assert r =~ "nada foi alterado" and not (r =~ "segredo")
    refute Enum.any?(Registro.eventos(t), &(inspect(&1.dados) =~ "segredo"))
  end

  # ------------------------------------------------------------------------------------------------------------------
  test "texto-base menos robotico e a pergunta do corretor chega a fala (contexto), sem repetir a mesma mensagem pronta" do
    t = tenant_pronto()
    primeira = dizer(t, "pedido destino site; url https://corretor.com.br/lancamento")
    refute primeira =~ "Falta so isso pra fechar o plano"
    assert primeira =~ "pixel" and primeira =~ "1. "

    # o corretor pergunta em vez de responder: a entrada da fala leva a pergunta e o que ja foi pedido
    segunda = dizer(t, "mas pra que serve esse pixel?")
    # 5.3: a pergunta vai para a conversa (planejar com o texto dela e o plano em andamento), nao para a fala
    assert_received {:ia, :planejar, %{"texto" => "pedido destino site; url https://corretor.com.br/lancamento"}}
    assert_received {:ia, :planejar, e2}
    assert e2["texto"] == "mas pra que serve esse pixel?"
    assert e2["plano"]["destino"] == "site" and e2["plano"]["status"] == "rascunho"
    # texto fixo (Falso) tambem nao repete a mensagem anterior
    assert segunda != primeira
    assert segunda =~ "pixel"

    # respondeu tudo: o plano sai (o teto pedido e nao dado vira sugestao)
    terceira = dizer(t, "pixel 998877; diario R$ 50")
    assert terceira =~ "Montei o plano"
    assert terceira != segunda
  end
end
