defmodule Trafego.IA.Falso do
  @moduledoc """
  Provedor de IA falso e deterministico (testes). Planejar: le segmentos `chave valor` separados por ";".
  Confirmar: classifica sim | nao | ambiguo por palavras. Se o texto traz `conta X`, devolve "conta_id" no plano
  (imita um modelo tentando impor conta; o dominio deve ignorar).
  """
  @behaviour Trafego.IA

  @impl true
  def chamar(faixa, :planejar, %{"texto" => texto} = entrada) do
    saida = %{"plano" => parse(texto)}
    {:ok, saida, uso(faixa, entrada, saida)}
  end

  def chamar(faixa, :confirmar, %{"texto" => texto} = entrada) do
    saida = %{"decisao" => decisao(texto)}
    {:ok, saida, uso(faixa, entrada, saida)}
  end

  # fala: devolve o texto-base composto, sem reescrever (a persona real vive no adaptador OpenAI)
  def chamar(faixa, :falar, entrada) do
    opts = [
      primeiro: entrada["primeiro_contato"] == true,
      pergunta_horario: entrada["perguntar_horario"] == true,
      omitir_base: entrada["omitir_base"] == true
    ]

    saida = %{"texto" => Trafego.Iara.compor(entrada["base"] || "", opts)}
    {:ok, saida, uso(faixa, entrada, saida)}
  end

  # horario: "8h30", "7h", "08:30"
  def chamar(faixa, :horario, %{"texto" => texto} = entrada) do
    h =
      case Regex.run(~r/(?<![\d-])(\d{1,2})\s*(?:h|:)\s*(\d{2})?(?!\d)/i, texto) do
        [_, hh] -> Trafego.Iara.normalizar_horario(hh)
        [_, hh, mm] -> Trafego.Iara.normalizar_horario("#{hh}:#{mm}")
        _ -> nil
      end

    saida = %{"horario" => h}
    {:ok, saida, uso(faixa, entrada, saida)}
  end

  # transcricao duvidosa: o Falso marca "inaudivel" ou "???" no texto falado
  def chamar(faixa, :checar_transcricao, %{"transcricao" => fala} = entrada) do
    duvida = if fala =~ ~r/inaudivel|\?\?\?/i, do: "uma parte do audio ficou inaudivel", else: nil
    saida = %{"duvida" => duvida}
    {:ok, saida, uso(faixa, entrada, saida)}
  end

  # audio de teste: os bytes SAO o texto falado
  @impl true
  def transcrever(bytes, %{segundos: s}) when is_binary(bytes) do
    if String.valid?(bytes), do: {:ok, bytes, %{"modelo" => "falso-audio", "segundos" => s}}, else: {:error, :audio_nao_suportado}
  end

  # fala de teste: os bytes sao "FALA:" + o texto (o teste confere o que foi dito); duracao por caracteres
  @impl true
  def sintetizar(texto) when is_binary(texto) do
    n = String.length(texto)
    {:ok, "FALA:" <> texto, %{"modelo" => "falso-voz", "caracteres" => n, "segundos" => max(ceil(n / 15), 1), "mime" => "audio/ogg; codecs=opus"}}
  end

  defp uso(faixa, e, s),
    do: %{"modelo" => "falso-#{faixa}", "tokens_in" => div(String.length(inspect(e)), 4) + 1, "tokens_out" => div(String.length(inspect(s)), 4) + 1}

  # ---- planejar
  defp parse(texto) do
    texto
    |> String.split(";", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.replace(~r/^pedido\s+/i, "")))
    |> Enum.reduce(%{}, fn seg, acc ->
      case String.split(seg, ~r/\s+/, parts: 2) do
        [k, v] -> campo(acc, String.downcase(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp campo(a, "destino", v), do: Map.put(a, "destino", destino(v))
  defp campo(a, k, v) when k in ~w(url pixel numero formulario imovel), do: Map.put(a, k, v)
  defp campo(a, "objetivo", v), do: Map.put(a, "objetivo", v)
  defp campo(a, "sugeridos", v), do: Map.put(a, "sugeridos", v |> String.split(~r/[\s,]+/, trim: true))
  defp campo(a, "ambiguidade", v), do: Map.put(a, "ambiguidade", v)
  defp campo(a, "sem_teto", _), do: Map.put(a, "sem_teto", true)
  defp campo(a, "sem_numero", _), do: Map.put(a, "sem_numero", true)
  defp campo(a, "conta", v), do: Map.put(a, "conta_id", v)
  defp campo(a, "publico", v), do: Map.put(a, "publico", v)

  defp campo(a, "criativo", v) do
    {midia, txt} =
      case String.split(v, "|", parts: 2) do
        [m, t] -> {String.trim(m), String.trim(t)}
        [m] -> {String.trim(m), ""}
      end

    Map.put(a, "criativo", %{"midia" => midia, "texto" => txt})
  end

  defp campo(a, "diario", v), do: Map.put(a, "orcamento_diario", centavos(v))
  defp campo(a, "teto", v), do: Map.put(a, "teto_total", centavos(v))

  defp campo(a, "janela", v) do
    case String.split(v) do
      [i, f] -> Map.put(a, "janela", %{"inicio" => i, "fim" => f})
      _ -> a
    end
  end

  defp campo(a, "meta", v), do: Map.update(a, "meta", %{"resultados" => inteiro(v)}, &Map.put(&1, "resultados", inteiro(v)))
  defp campo(a, "custo_max", v), do: Map.update(a, "meta", %{"custo_max" => centavos(v)}, &Map.put(&1, "custo_max", centavos(v)))
  defp campo(a, _, _), do: a

  defp destino(v) do
    v = String.downcase(v)

    cond do
      v =~ "whats" -> "whatsapp"
      v =~ "form" -> "formulario"
      true -> "site"
    end
  end

  defp inteiro(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp centavos(v) do
    case Regex.run(~r/(\d+)(?:[.,](\d{1,2}))?/, v) do
      [_, r] -> String.to_integer(r) * 100
      [_, r, c] -> String.to_integer(r) * 100 + String.to_integer(String.pad_trailing(c, 2, "0"))
      _ -> nil
    end
  end

  # ---- confirmar
  @sim ~w(sim pode confirmo confirmado fechado beleza ok claro perfeito vai positivo autorizo)
  @nao ~w(nao cancela cancelar desisto negativo pare)
  @ajuste ~w(muda mude troca troque altera altere ajusta ajuste aumenta aumente diminui diminua)
  @duvida ["talvez", "nao sei", "depois", "acho", "hmm", "duvida", "esperar"]

  defp decisao(texto) do
    n =
      texto
      |> String.downcase()
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.replace(~r/[^a-z0-9\s]/, " ")
      |> String.replace(~r/\s+/, " ")

    palavras = String.split(n)
    sim? = Enum.any?(palavras, &(&1 in @sim))
    nao? = Enum.any?(palavras, &(&1 in @nao))

    cond do
      Enum.any?(@duvida, &String.contains?(n, &1)) -> "ambiguo"
      Enum.any?(palavras, &(&1 in @ajuste)) and not sim? -> "ajuste"
      sim? and not nao? -> "sim"
      nao? and not sim? -> "nao"
      true -> "ambiguo"
    end
  end
end
