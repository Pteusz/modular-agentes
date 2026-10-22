defmodule Trafego.Iara.Texto do
  @moduledoc """
  Garantia determinista de escrita da Iara (trafego 1.12.0): NENHUMA mensagem dela (WhatsApp, avisos, fallbacks, textos fixos, resumo no
  painel) sai com travessao. Ninguem usa travessao em conversa de WhatsApp, e o prompt pede para nao usar, mas quem garante e o codigo:
  `limpar/1` e a ultima etapa antes de qualquer envio.

  Regras (travessao em dash U+2014, en dash U+2013, barra horizontal U+2015, figure dash U+2012, e "--"):
    * entre numeros/horas: "9h-10h" -> "9h às 10h"; "2-3 dias" -> "2 a 3 dias"; "R$ 50-100" -> "R$ 50 a 100" (com o travessao no lugar do "-");
    * entre palavras ("isso, e olha, funciona"): vira virgula; depois de pontuacao some; se a frase seguinte comeca em maiuscula,
      vira ponto ("Fechado — Vou ver" -> "Fechado. Vou ver");
    * no comeco de linha (fala/lista): vira "- " (hifen comum); no fim da linha: some.
  Hifen comum ("guarda-chuva", "e-mail", " - ") nao e travessao e nao muda.
  """

  @travessos "‒–—―"
  @dash "[#{@travessos}](?:[ \t]*[#{@travessos}])*|-{2,}"
  @tem ~r/[\x{2012}\x{2013}\x{2014}\x{2015}]|--/u

  @doc "Texto sem travessao (outros tipos voltam como estao)."
  def limpar(t) when is_binary(t) do
    if Regex.match?(@tem, t), do: t |> faixa() |> corpo() |> inicio_de_linha(), else: t
  end

  def limpar(outro), do: outro

  @doc "Aplica `limpar/1` a uma saida da Iara: texto, lista, `{:ok, ...}`, `{:audio, bytes, opts, texto}` (o texto equivalente)."
  def limpar_saida({:ok, r}), do: {:ok, limpar_saida(r)}
  def limpar_saida({:ok, r, extra}), do: {:ok, limpar_saida(r), extra}
  def limpar_saida({:audio, bytes, opts, texto}), do: {:audio, bytes, opts, limpar(texto)}
  def limpar_saida(l) when is_list(l), do: Enum.map(l, &limpar_saida/1)
  def limpar_saida(t) when is_binary(t), do: limpar(t)
  def limpar_saida(outro), do: outro

  @doc "Tem travessao?"
  def travessao?(t) when is_binary(t), do: Regex.match?(@tem, t)
  def travessao?(_), do: false

  # numero ou hora de um lado e do outro
  defp faixa(t) do
    Regex.replace(~r/(\d(?:h\d\d|h|:\d\d)?)[ \t]*(?:#{@dash})[ \t]*(?=(\d))/u, t, fn _, esq, _dir ->
      if Regex.match?(~r/(?:h\d\d|h|:\d\d)$/, esq), do: "#{esq} às ", else: "#{esq} a "
    end)
  end

  # travessao no meio do texto (com ou sem espacos) entre palavras/pontuacao; consome so o caractere da esquerda
  defp corpo(t) do
    t =
      Regex.replace(~r/(\S)[ \t]*(?:#{@dash})[ \t]*(?=(\S))/u, t, fn todo, antes, depois ->
        cond do
          Regex.match?(@tem, antes) -> todo
          antes in [".", "!", "?", ":", ";", ","] -> antes <> " "
          Regex.match?(~r/^\p{Lu}$/u, depois) -> antes <> ". "
          true -> antes <> ", "
        end
      end)

    # travessao no fim da linha: some
    Regex.replace(~r/(\S)[ \t]*(?:#{@dash})[ \t]*$/mu, t, "\\1")
  end

  # "— fala" / "– item" no comeco de linha vira hifen comum (nao sobra travessao)
  defp inicio_de_linha(t) do
    t
    |> then(&Regex.replace(~r/^([ 	]*)(?:#{@dash})[ 	]*$/mu, &1, "\\1-"))
    |> then(&Regex.replace(~r/^([ 	]*)(?:#{@dash})[ 	]*/mu, &1, "\\1- "))
  end
end
