# Teste da fala humana da Iara (trafego 1.12.0, nucleo 1.6.0): sem travessao em nenhuma saida (codigo, nao so prompt), ganchos na
# apresentacao, "nao da para desligar" nunca dito, juncao de mensagens em sequencia rapida.
# Rodar: MIX_ENV=test mix test test/etapa56_test.exs
# REGRA: tenants tp56_* (so os proprios dados). IA pelo provedor Falso com ROTEIRO (:roteiro_ia). NENHUMA chamada real a OpenAI/Meta.
defmodule Etapa56Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Canal}
  alias Nucleo.Automacoes.Trafego, as: Contrato
  alias Trafego.{Agente, Acesso, Iara, Banco, Conversa, Ferramentas}
  alias Trafego.Iara.Texto
  alias Trafego.Plataforma.Simulada

  @chaves ~w(cotacao_usd_brl teto_ia_brl notificar provedor_ia numero_cadastrado roteiro_ia openai junta_ms)a
  @travessos ["‒", "–", "—", "―", "--"]

  setup_all do
    Registro.migrar!()
    Banco.migrar!()
    limpar()
    start_supervised!(Simulada)
    salvo = for k <- @chaves, do: {k, Application.fetch_env(:trafego, k)}

    on_exit(fn ->
      limpar()
      for {k, v} <- salvo, do: (case v do {:ok, x} -> Application.put_env(:trafego, k, x); :error -> Application.delete_env(:trafego, k) end)
    end)

    :ok
  end

  setup do
    Application.put_env(:trafego, :teto_ia_brl, 1000.0)
    Application.put_env(:trafego, :cotacao_usd_brl, 5.0)
    Application.put_env(:trafego, :provedor_ia, Trafego.IA.Falso)
    Application.put_env(:trafego, :notificar, fn _, _ -> :ok end)
    Application.put_env(:trafego, :numero_cadastrado, fn _ -> "(11) 97420-8400" end)
    Application.put_env(:trafego, :junta_ms, 0)
    Application.delete_env(:trafego, :roteiro_ia)
    :ok
  end

  defp limpar do
    for t <- ~w(estado eventos vinculos), do: Postgrex.query!(Registro, "DELETE FROM #{t} WHERE tenant_id LIKE 'tp56\\_%'", [])
    Postgrex.query!(Registro, "DELETE FROM tenants WHERE id LIKE 'tp56\\_%'", [])
  end

  defp tenant_novo do
    t = "tp56_#{System.unique_integer([:positive])}"
    conta = "act_#{t}"
    Simulada.registrar_conta(conta)
    Simulada.registrar_token("SIM-#{t}", [conta])
    {:ok, :criado} = Nucleo.Vincular.vincular(t, Contrato, Canal.Simulado, %{})
    {:ok, _} = Acesso.cadastrar(t, %{"conta_id" => conta, "token" => "SIM-#{t}"})
    t
  end

  defp roteiro(passos), do: Application.put_env(:trafego, :roteiro_ia, passos)
  defp sobra, do: Application.get_env(:trafego, :roteiro_ia)
  defp dizer(t, texto), do: t |> Agente.processar_mensagens(texto) |> then(fn {:ok, r} -> List.wrap(r) end)
  defp rejeicoes(t), do: Banco.q("SELECT dados FROM eventos WHERE tenant_id = $1 AND tipo = 'operacao' ORDER BY id", [t]).rows |> Enum.map(&hd/1) |> Enum.filter(&(&1["ref"] == "conversa_texto_rejeitado"))

  defp espera(f, n \\ 60) do
    cond do
      f.() -> true
      n == 0 -> false
      true -> Process.sleep(50) && espera(f, n - 1)
    end
  end

  defp sem_travessao?(texto), do: not Enum.any?(@travessos, &String.contains?(texto, &1))

  # ------------------------------------------------------------------------------------------------------------------
  describe "Trafego.Iara.Texto (sanitizacao determinista)" do
    test "travessao entre palavras vira virgula, ponto (se a proxima frase e maiuscula) ou some depois de pontuacao" do
      assert Texto.limpar("Fechado — vou ver") == "Fechado, vou ver"
      assert Texto.limpar("Fechado—vou ver") == "Fechado, vou ver"
      assert Texto.limpar("Fechado — Vou ver") == "Fechado. Vou ver"
      assert Texto.limpar("Combinado! — ok") == "Combinado! ok"
      assert Texto.limpar("Show, – tudo certo") == "Show, tudo certo"
      assert Texto.limpar("isso -- aquilo") == "isso, aquilo"
      assert Texto.limpar("a — b — c") == "a, b, c"
      assert Texto.limpar("a ―― b") == "a, b"
    end

    test "faixas de numero e hora: 'das 9h as 10h', '2 a 3 dias', 'R$ 50 a 100'" do
      assert Texto.limpar("das 9h–10h") == "das 9h às 10h"
      assert Texto.limpar("das 9:30 — 10:30") == "das 9:30 às 10:30"
      assert Texto.limpar("de 2–3 dias") == "de 2 a 3 dias"
      assert Texto.limpar("R$ 50—100 por dia") == "R$ 50 a 100 por dia"
    end

    test "comeco e fim de linha: vira hifen no comeco, some no fim; varias linhas" do
      assert Texto.limpar("— oi") == "- oi"
      assert Texto.limpar("texto —") == "texto"
      assert Texto.limpar("linha 1 —\n— linha 2") == "linha 1\n- linha 2"
      assert Texto.limpar("—") == "-"
    end

    test "o que nao e travessao fica intacto (hifen, e-mail, texto sem nada, tipos que nao sao texto)" do
      for t <- ["guarda-chuva e e-mail", "ok - tudo bem", "9h-10h", "", "Sem nada demais.", "R$ 1.000,50", "p1 - pausada"], do: assert(Texto.limpar(t) == t)
      assert Texto.limpar(nil) == nil
      assert Texto.limpar(42) == 42
    end

    test "nenhum resultado tem travessao, em qualquer combinacao de bordas" do
      entradas = ["—", "a—", "—a", "a — — b", "1—2", "———", "x -- y -- z", "?—!", "fim.—", "—\n—\n—", "9h–– 10h", "tudo bem —\n"]
      for e <- entradas, do: refute(Texto.travessao?(Texto.limpar(e)), "sobrou travessao em #{inspect(e)} -> #{inspect(Texto.limpar(e))}")
    end

    test "limpar_saida cobre texto, lista, {:ok, ...} e a nota de voz (texto equivalente)" do
      assert Texto.limpar_saida({:ok, ["a — b", "c"]}) == {:ok, ["a, b", "c"]}
      assert Texto.limpar_saida({:ok, "a — b", situacao: :x}) == {:ok, "a, b", situacao: :x}
      assert Texto.limpar_saida({:audio, <<1, 2>>, [voz: "x"], "a — b"}) == {:audio, <<1, 2>>, [voz: "x"], "a, b"}
      assert Texto.limpar_saida({:error, :x}) == {:error, :x}
    end
  end

  describe "sem travessao em nenhuma saida da Iara" do
    test "o texto do modelo sai limpo (e a limpeza ve antes do validador: o gancho continua valendo)" do
      t = tenant_novo()
      roteiro([{:texto, "Oi! Sou a Iara — da equipe Ataque Total da Cury Construtora — uma IA. Você já anunciou imóvel antes?"}])
      assert [msg] = dizer(t, "oi")
      assert sem_travessao?(msg)
      assert msg == "Oi! Sou a Iara, da equipe Ataque Total da Cury Construtora, uma IA. Você já anunciou imóvel antes?"
      assert Iara.cobertura(t)["quem_sou"]
    end

    test "fallbacks e textos fixos: modelo fora do ar, erro de ferramenta, primeiro contato" do
      t = tenant_novo()
      roteiro([{:erro, :indisponivel}])
      assert [msg] = dizer(t, "oi")
      assert sem_travessao?(msg)

      roteiro([{:erro, :indisponivel}])
      assert msg2 = dizer(t, "oi de novo") |> Enum.join(" ")
      assert sem_travessao?(msg2)
      assert sem_travessao?(Iara.apresentacao_minima())
    end

    test "aviso proativo (Notificar) sai limpo" do
      pid = self()
      Application.put_env(:trafego, :notificar, fn t, texto -> send(pid, {:aviso, t, texto}) && :ok end)
      Trafego.Notificar.enviar("tp56_x", "Campanha pausada — verba estourou")
      assert_received {:aviso, "tp56_x", "Campanha pausada, verba estourou"}
    end

    test "o prompt (persona, politica, estado e definicoes das ferramentas) tambem nao usa travessao" do
      t = tenant_novo()
      pid = self()
      roteiro([fn entrada -> send(pid, {:instrucao, entrada["instrucao"]}) && {:texto, "Oi!"} end])
      dizer(t, "oi")
      assert_received {:instrucao, i}
      assert sem_travessao?(i)
      assert sem_travessao?(Iara.persona())
      assert sem_travessao?(inspect(Ferramentas.definicoes()))
    end

    test "o laco entrega ao canal mensagens limpas (com o prefixo da Iara)" do
      t = tenant_novo()
      roteiro([{:texto, "Oi! Sou a Iara — uma IA da equipe Ataque Total da Cury. Já mexeu com anúncio de imóvel antes?"}])
      {:ok, l} = Nucleo.Laco.iniciar(t)
      ref = Nucleo.Laco.canal(l)
      Canal.Simulado.injetar(ref, :proprio, "oi")
      assert espera(fn -> length(Canal.Simulado.enviadas(ref)) == 1 end)
      assert [env] = Canal.Simulado.enviadas(ref)
      assert String.starts_with?(env, "[Iara] ") and sem_travessao?(env)
    end
  end

  describe "'nao da para desligar' nunca sai da boca da Iara" do
    test "o validador reconhece as formas do 'nao' (com e sem acento) e deixa passar o resto" do
      for f <- ["Não dá pra desligar.", "nao posso desligar isso", "Não é possível desligar a atualização", "isso nao da para desativar", "Impossível desligar", "essa atualização não pode ser desligada"],
          do: assert(Conversa.frase_de_desligar(f) != nil, f)

      for f <- ["Posso mudar o horário, qual seria?", "Dá pra mandar mais tarde.", "Não dá pra ver o saldo da Meta.", "Desliguei a campanha c1? Não, pausei.", "Pode desligar a luz"],
          do: assert(Conversa.frase_de_desligar(f) == nil, f)
    end

    test "texto com a frase e rejeitado; o modelo corrige e o corretor so ve a versao natural" do
      t = tenant_novo()
      Iara.cobrir(t, "quem_sou")
      Iara.cobrir(t, "como_aprendo")
      Iara.definir_horario(t, "09:00")

      roteiro([{:texto, "Isso eu não posso desligar, só o horário muda."}, {:texto, "Entendi, tá pesando. Posso mandar em outro horário, qual ficaria melhor?"}])
      assert [msg] = dizer(t, "quero parar de receber essas atualizações")
      assert msg =~ "outro horário"
      assert Conversa.frase_de_desligar(msg) == nil
      assert [%{"motivo" => motivo}] = rejeicoes(t)
      assert motivo =~ "desligar"
      assert sobra() == []
    end

    test "o modelo insiste na frase: o corretor ve o fallback, nunca a frase" do
      t = tenant_novo()
      Iara.cobrir(t, "quem_sou")
      Iara.cobrir(t, "como_aprendo")
      Iara.definir_horario(t, "09:00")
      roteiro([{:texto, "Não dá pra desligar."}, {:texto, "Não é possível desligar a atualização."}])
      msgs = dizer(t, "desliga as atualizações")
      assert Enum.all?(msgs, &(Conversa.frase_de_desligar(&1) == nil))
      assert Iara.horario(t) == "09:00"
    end

    test "a ferramenta continua sem opcao de desligar e a politica manda oferecer o horario, sem puxar o assunto" do
      defs = inspect(Ferramentas.definicoes())
      refute defs =~ ~r/desligar|desativar/i
      assert {:erro, _, _} = Ferramentas.executar(tenant_novo(), "lembrar", %{"chave" => "desligar_atualizacao", "valor" => "sim"}, %{efeitos: [], leituras: %{}, entrega: nil, entrega_falha: nil, chamadas: []})

      t = tenant_novo()
      pid = self()
      roteiro([fn entrada -> send(pid, {:instrucao, entrada["instrucao"]}) && {:texto, "Oi!"} end])
      dizer(t, "oi")
      assert_received {:instrucao, i}
      assert i =~ ~r/Se ele pedir para parar ou desligar as atualizacoes, responda como colega.*ofereca mudar o horario/s
      assert i =~ ~r/nunca puxe esse assunto/
      refute i =~ ~r/nao da para desligar|nao pode ser desligada/i
    end
  end

  describe "ganchos na apresentacao" do
    test "criterio: a ultima frase e uma pergunta com 4 palavras ou mais" do
      for ok <- ["Oi! Sou a Iara. Já mexeu com anúncio de imóvel antes?", "Prefere áudio ou texto? 🙂", "Qual horário fica melhor pra você?", "Eu aprendo com o tempo. E você, anuncia há quanto tempo?"],
          do: assert(Conversa.gancho?(ok), ok)

      for ruim <- ["Sou a Iara, uma IA.", "Certo?", "Entendeu?", "Oi. Tudo certo?", "Sou a Iara. Beleza?", "Pergunta no meio? e termina afirmando.", ""],
          do: refute(Conversa.gancho?(ruim), ruim)
    end

    test "mensagem de apresentacao sem gancho e rejeitada; o modelo corrige e o gancho chega ao corretor" do
      t = tenant_novo()

      roteiro([
        {:texto, "Oi! Sou a Iara, da equipe Ataque Total da Cury Construtora, uma IA."},
        {:texto, "Oi! Sou a Iara, da equipe Ataque Total da Cury Construtora, uma IA. Você já anunciou imóvel antes?"}
      ])

      assert [msg] = dizer(t, "oi")
      assert msg =~ "?" and Conversa.gancho?(msg)
      assert [%{"motivo" => motivo}] = rejeicoes(t)
      assert motivo =~ "pergunta"
      assert Iara.cobertura(t)["quem_sou"]
    end

    test "sem gancho de novo: fallback do primeiro contato (uma mensagem fixa), nunca texto solto sem pergunta" do
      t = tenant_novo()
      semgancho = "Oi! Sou a Iara, da equipe Ataque Total da Cury Construtora, uma IA."
      roteiro([{:texto, semgancho}, {:texto, semgancho}])
      assert [msg] = dizer(t, "oi")
      assert msg == Iara.apresentacao_minima()
    end

    test "o horario combinado fecha com a pergunta da primeira campanha; atender pedido nao exige gancho" do
      t = tenant_novo()
      Iara.cobrir(t, "quem_sou")
      Iara.cobrir(t, "como_aprendo")
      Iara.cobrir(t, "horario_perguntado")
      roteiro([{:chamar, "combinar_horario", %{"hora" => "08:00"}}, {:texto, "Fechado, todo dia às 8h."}, {:texto, "Fechado, todo dia às 8h. Já quer criar a sua primeira campanha comigo?"}])
      assert ["Fechado, todo dia às 8h. Já quer criar a sua primeira campanha comigo?"] = dizer(t, "8h")
      assert Iara.encerrada?(t)
      assert [%{"motivo" => m}] = rejeicoes(t)
      assert m =~ "pergunta"

      u = tenant_novo()
      Iara.cobrir(u, "quem_sou")
      roteiro([{:texto, "Por enquanto você não tem campanha rodando."}])
      assert ["Por enquanto você não tem campanha rodando."] = dizer(u, "como estão as campanhas?")
      assert sobra() == []
    end

    test "registro automatico: so o proximo item, so se o texto diz, e nunca com plano ou proposta no ar" do
      t = tenant_novo()
      # fora de ordem: fala de aprender antes de se apresentar nao registra como_aprendo
      roteiro([{:texto, "Eu vou aprendendo com o tempo. Você já mexeu com anúncio de imóvel?"}])
      dizer(t, "oi")
      assert Iara.cobertura(t) == %{"quem_sou" => false, "como_aprendo" => false}

      # com plano em montagem a apresentacao nao entra, mesmo que o texto cite a Iara e a IA
      u = tenant_novo()
      roteiro([{:chamar, "planejar", %{"pedido" => "pedido objetivo vender; imovel Torre Sul"}}, {:texto, "Anotei, sou a Iara, uma IA. Qual o orçamento por dia?"}])
      dizer(u, "quero anunciar o imovel Torre Sul")
      assert Iara.cobertura(u)["quem_sou"] == false
    end

    test "o horario padrao (9h) pode ser dito na pergunta sem ser tratado como numero inventado" do
      t = tenant_novo()
      Iara.cobrir(t, "quem_sou")
      Iara.cobrir(t, "como_aprendo")
      roteiro([{:texto, "Se você não disser outro, mando às 9h. Qual horário fica melhor pra você?"}])
      assert [msg] = dizer(t, "pode ser")
      assert msg =~ "9h"
      assert Iara.perfil(t)["horario_estado"] == "perguntado"
    end
  end

  describe "tres aberturas diferentes (modelo Falso por roteiro)" do
    # cada turno: o corretor fala, o roteiro tem o que o modelo diria; devolve a unica mensagem e registra a transcricao
    defp turno(t, fala, passos, linhas) do
      roteiro(List.wrap(passos))
      assert [msg] = dizer(t, fala)
      assert sobra() == []
      assert sem_travessao?(msg)
      send(self(), {:linha, linhas, fala, msg})
      msg
    end

    defp transcricao(titulo, turnos) do
      corpo = Enum.map_join(turnos, "\n", fn {fala, msg} -> "Corretor: #{fala}\nIara: #{msg}\n" end)
      File.write!(Path.join(System.tmp_dir!(), "transcricoes_iara_1_12.txt"), "== #{titulo} ==\n#{corpo}\n", [:append])
    end

    test "A: abertura seca ('oi'); a pessoa responde cada gancho e a Iara nunca fala duas vezes seguidas" do
      t = tenant_novo()
      m1 = turno(t, "oi", {:texto, "Oi! Iara aqui, da Ataque Total da Cury Construtora. Sou uma IA, mas trabalho igual colega. Você já rodou anúncio de imóvel por conta própria?"}, :a)
      assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => false}

      m2 = turno(t, "já, mas nunca deu resultado", {:texto, "Entendi, é bem comum. Eu vou me adaptando ao seu jeito e aprendendo com o tempo, melhoro a cada campanha. Prefere me mandar áudio ou texto?"}, :a)
      assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => true}

      m3 = turno(t, "áudio", {:texto, "Show, pode mandar áudio à vontade. Se não me disser outro, mando a atualização diária das campanhas às 9h. Qual horário fica melhor pra você?"}, :a)
      assert Iara.perfil(t)["horario_estado"] == "perguntado"

      m4 = turno(t, "8h", [{:chamar, "combinar_horario", %{"hora" => "08:00"}}, {:texto, "Fechado, todo dia às 8h. Já quer criar a sua primeira campanha comigo?"}], :a)
      assert Iara.encerrada?(t) and Iara.horario(t) == "08:00"
      transcricao("A: abertura seca", [{"oi", m1}, {"já, mas nunca deu resultado", m2}, {"áudio", m3}, {"8h", m4}])
    end

    test "B: abertura brincalhona; mensagens com travessao saem limpas e o gancho continua" do
      t = tenant_novo()
      m1 = turno(t, "e aí, tudo certo?? kkk", {:texto, "Tudo certo por aqui, e contigo? Eu sou a Iara, uma IA da equipe Ataque Total da Cury Construtora. Anuncia todo mês ou só de vez em quando?"}, :b)
      m2 = turno(t, "todo mês kkk", {:texto, "Boa, então a gente se entende rápido. Eu me adapto ao seu jeito e vou aprendendo com o tempo, melhorando a cada campanha. Gosta mais de mandar áudio ou de escrever?"}, :b)
      m3 = turno(t, "escrevo mesmo, áudio é chato", {:texto, "Beleza, texto então — me diz uma coisa: que horário é melhor pra eu mandar a atualização das campanhas todo dia? Sem resposta, uso 9h."}, :b)
      assert m3 =~ "texto então, me diz"
      m4 = turno(t, "umas 7h30", [{:chamar, "combinar_horario", %{"hora" => "07:30"}}, {:texto, "Combinado, 7h30 todo dia. Bora montar a sua primeira campanha agora?"}], :b)
      assert Iara.encerrada?(t) and Iara.horario(t) == "07:30"
      transcricao("B: abertura brincalhona", [{"e aí, tudo certo?? kkk", m1}, {"todo mês kkk", m2}, {"escrevo mesmo, áudio é chato", m3}, {"umas 7h30", m4}])
    end

    test "C: abertura com pergunta direta; sem resposta ao horario vale o padrao 9h (a Iara nao insiste)" do
      t = tenant_novo()
      m1 = turno(t, "Bom dia, quem é você?", {:texto, "Bom dia! Sou a Iara, da equipe Ataque Total da Cury Construtora, e sou uma IA. Cuido dos seus anúncios. Quantos imóveis você está anunciando hoje?"}, :c)
      m2 = turno(t, "uns 5", {:texto, "Cinco já dá trabalho. Eu me adapto ao seu jeito e aprendo com o tempo, melhoro a cada campanha. Posso falar por áudio também, tudo bem pra você?"}, :c)
      m3 = turno(t, "pode", {:texto, "Fechado. Se não me disser outro, mando a atualização das campanhas às 9h. Qual horário é melhor pra você?"}, :c)
      assert Iara.perfil(t)["horario_estado"] == "perguntado"

      # ele muda de assunto: a Iara atende e o padrao passa a valer, sem repetir a pergunta
      roteiro([{:texto, "Por enquanto não vejo campanha rodando na sua conta."}])
      assert [m4] = dizer(t, "como estão minhas campanhas?")
      refute m4 =~ "?"
      assert %{"horario_estado" => "padrao", "horario" => "09:00"} = Iara.perfil(t)
      transcricao("C: pergunta direta", [{"Bom dia, quem é você?", m1}, {"uns 5", m2}, {"pode", m3}, {"como estão minhas campanhas?", m4}])
    end
  end

  describe "fechamento da apresentacao: primeira campanha (1.12.1)" do
    defp fechado(t) do
      for i <- ~w(quem_sou como_aprendo horario_perguntado), do: Iara.cobrir(t, i)
      roteiro([{:chamar, "combinar_horario", %{"hora" => "08:00"}}, {:texto, "Fechado, todo dia às 8h. Já está pronto pra criar a sua primeira campanha comigo?"}])
      assert [msg] = dizer(t, "8h")
      msg
    end

    test "o fechamento termina em pergunta sobre a primeira campanha e marca o estado" do
      t = tenant_novo()
      msg = fechado(t)
      assert Conversa.gancho?(msg) and msg =~ "campanha"
      assert Iara.campanha_perguntada?(t) and Iara.perfil(t)["campanha_perguntada"] == true
      assert Iara.encerrada?(t)
    end

    test "resposta 'sim' segue o fluxo normal de criar campanha, sem repetir a pergunta nem se reapresentar" do
      t = tenant_novo()
      fechado(t)
      pid = self()
      espia = fn entrada -> send(pid, {:instrucao, entrada["instrucao"]}) && {:chamar, "planejar", %{"pedido" => "pedido objetivo vender; imovel Torre Sul"}} end
      roteiro([espia, {:texto, "Bora! Qual o orçamento por dia pra essa campanha?"}])
      assert [msg | _] = dizer(t, "sim, bora")
      assert_received {:instrucao, i}
      assert i =~ "campanha_perguntada=sim" and i =~ "apresentacao encerrada"
      assert msg =~ "orçamento"
      assert Trafego.Plano.atual(t) != nil
    end

    test "resposta 'nao': resposta curta, sem nova pergunta de gancho e sem repetir a pergunta depois" do
      t = tenant_novo()
      fechado(t)
      roteiro([{:texto, "Tranquilo, quando quiser é só me chamar."}])
      assert ["Tranquilo, quando quiser é só me chamar."] = dizer(t, "agora não")
      assert sobra() == []
      roteiro([{:texto, "Por enquanto você não tem campanha rodando."}])
      assert ["Por enquanto você não tem campanha rodando."] = dizer(t, "como estão as campanhas?")
      assert sobra() == []
    end
  end

  describe "estado anterior preservado" do
    test "corretor com apresentacao encerrada: nada de apresentacao, nem gancho, nem registro" do
      t = tenant_novo()
      Iara.atualizar(t, %{"apresentada" => true, "horario" => "07:00", "horario_estado" => "definido"})
      antes = Iara.perfil(t)
      roteiro([{:texto, "Oi! Tudo bem? Sou a Iara, uma IA, e estou por aqui."}])
      assert [msg] = dizer(t, "oi")
      assert msg =~ "Iara"
      assert Iara.perfil(t) == antes
    end

    test "perfil legado (apresentada=true, sem mapa) so e cobrado do horario" do
      t = tenant_novo()
      Iara.atualizar(t, %{"apresentada" => true})
      assert Iara.proximo_item(t) == "perguntar_horario"
      roteiro([{:texto, "Posso mandar a atualização diária das campanhas às 9h. Qual horário fica melhor pra você?"}])
      assert [_] = dizer(t, "oi")
      assert Iara.perfil(t)["horario_estado"] == "perguntado"
      assert Iara.cobertura(t) == %{"quem_sou" => true, "como_aprendo" => true}
    end
  end

  describe "juncao de mensagens em sequencia rapida (Nucleo.Laco 1.6.0)" do
    @ia "Oi! Sou a Iara, uma IA da equipe Ataque Total da Cury. Já mexeu com anúncio de imóvel antes?"

    defp espia_itens(texto) do
      pid = self()
      fn entrada -> send(pid, {:itens, entrada["itens"]}) && {:texto, texto} end
    end

    test "duas mensagens dentro da janela viram UM turno, com os textos unidos por quebra de linha" do
      t = tenant_novo()
      Application.put_env(:trafego, :junta_ms, 250)
      roteiro([espia_itens(@ia)])
      {:ok, l} = Nucleo.Laco.iniciar(t)
      ref = Nucleo.Laco.canal(l)
      Canal.Simulado.injetar(ref, :proprio, "oi")
      Canal.Simulado.injetar(ref, :proprio, "tudo bem?")
      Canal.Simulado.injetar(ref, :proprio, "tem alguem ai")
      assert_receive {:itens, itens}, 3000
      assert List.last(itens)["texto"] == "oi\ntudo bem?\ntem alguem ai"
      assert espera(fn -> length(Canal.Simulado.enviadas(ref)) == 1 end)
      Process.sleep(500)
      assert [_] = Canal.Simulado.enviadas(ref)
      assert sobra() == []
    end

    test "mensagens separadas por mais que a janela sao turnos separados" do
      t = tenant_novo()
      Application.put_env(:trafego, :junta_ms, 100)
      roteiro([{:texto, @ia}, {:texto, "Beleza, me conta mais."}])
      {:ok, l} = Nucleo.Laco.iniciar(t)
      ref = Nucleo.Laco.canal(l)
      Canal.Simulado.injetar(ref, :proprio, "oi")
      assert espera(fn -> length(Canal.Simulado.enviadas(ref)) == 1 end)
      Canal.Simulado.injetar(ref, :proprio, "ja mexi sim")
      assert espera(fn -> length(Canal.Simulado.enviadas(ref)) == 2 end)
      assert sobra() == []
    end

    test "janela 0 (padrao do teste): cada mensagem e um turno, como antes" do
      t = tenant_novo()
      roteiro([{:texto, @ia}, {:texto, "Beleza, me conta mais."}])
      {:ok, l} = Nucleo.Laco.iniciar(t)
      ref = Nucleo.Laco.canal(l)
      Canal.Simulado.injetar(ref, :proprio, "oi")
      Canal.Simulado.injetar(ref, :proprio, "e ai")
      assert espera(fn -> length(Canal.Simulado.enviadas(ref)) == 2 end)
      assert sobra() == []
    end

    test "depois do fechamento a Iara fica quieta: nenhuma mensagem sem o corretor escrever" do
      t = tenant_novo()
      for i <- ~w(quem_sou como_aprendo horario_perguntado), do: Iara.cobrir(t, i)
      roteiro([{:chamar, "combinar_horario", %{"hora" => "08:00"}}, {:texto, "Fechado, todo dia às 8h. Já quer criar a sua primeira campanha comigo?"}])
      {:ok, l} = Nucleo.Laco.iniciar(t)
      ref = Nucleo.Laco.canal(l)
      Canal.Simulado.injetar(ref, :proprio, "8h")
      assert espera(fn -> length(Canal.Simulado.enviadas(ref)) == 1 end)
      Process.sleep(400)
      assert [_] = Canal.Simulado.enviadas(ref)
    end
  end
end
