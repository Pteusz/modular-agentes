defmodule Trafego.Voz do
  @moduledoc """
  A Iara FALA por audio (etapa 5.2.3). Regra de uso:
    * corretor mandou AUDIO -> as mensagens CONVERSACIONAIS curtas voltam como nota de voz; texto -> texto (a menos que ele peca);
    * pedido explicito ("responde em audio" / "so texto") vale dai em diante e fica no perfil (iara_perfil "voz": audio | texto);
    * dados para conferir ficam SEMPRE em texto: qualquer mensagem com numero, R$, aspas, link ou mais de #{200} caracteres
      (resumo do plano, valores, texto do anuncio, id da campanha/plano/proposta);
    * ao montar o plano em modo audio, uma fala curta ("montei o plano, olha ai") vai antes do resumo, que segue em texto;
    * a nota de voz nao tem prefixo; falha na sintese, provedor sem voz ou teto de IA bloqueado = texto, nunca silencio.
  `aplicar/3` recebe o resultado do agente ({:ok, texto | [textos]}) e devolve o mesmo formato, com `{:audio, bytes, opts, texto}`
  nos elementos falados (Nucleo.Laco 1.5.0 envia; sem canal de audio ou com falha o `texto` sai como texto). O custo de cada fala
  entra no custo_tokens (R$, por duracao estimada) e, portanto, no teto de IA do corretor.
  """
  alias Trafego.{Evento, IA, Iara, TetoIA}

  @max_chars 200
  @aviso_plano "Montei o plano, olha ai."

  def aplicar(tenant, {:ok, r}, origem) when is_binary(r) or (is_list(r) and r != []) do
    if modo_audio?(tenant, origem) do
      saida = falar(tenant, List.wrap(r))
      {:ok, if(is_binary(r) and length(saida) == 1, do: hd(saida), else: saida)}
    else
      {:ok, r}
    end
  end

  def aplicar(_tenant, outro, _origem), do: outro

  @doc "Como `aplicar/3` (argumentos na ordem de pipe: resultado, tenant, origem); qualquer falha devolve o resultado original em texto."
  def aplicar_seguro(res, tenant, origem) do
    aplicar(tenant, res, origem)
  rescue
    _ -> res
  catch
    _, _ -> res
  end

  @doc "Responder por voz? Preferencia do perfil manda; sem ela, acompanha a origem (audio -> audio). Teto de IA bloqueado = nao."
  def modo_audio?(tenant, origem) do
    quer = Iara.voz_preferida(tenant) == "audio" or (origem == "audio" and Iara.voz_preferida(tenant) != "texto")
    quer and not match?({:bloqueado, _}, TetoIA.status(tenant))
  end

  @doc "Mensagem conversacional (pode virar voz): curta e sem dado para conferir."
  def conversacional?(texto) when is_binary(texto) do
    t = String.trim(texto)

    t != "" and String.length(t) <= @max_chars and not Regex.match?(~r/\d|R\$|["“”]|https?:|www\.|\n/u, t)
  end

  defp falar(tenant, msgs) do
    corpo = Enum.map(msgs, &falar_uma(tenant, &1))

    case Enum.find_index(corpo, &plano?/1) do
      nil ->
        corpo

      i ->
        case sintetizar(tenant, @aviso_plano) do
          {:ok, audio} -> List.insert_at(corpo, i, audio)
          _ -> corpo
        end
    end
  end

  defp plano?(t) when is_binary(t), do: String.starts_with?(t, "Montei o plano")
  defp plano?(_), do: false

  defp falar_uma(tenant, texto) do
    if conversacional?(texto) do
      case sintetizar(tenant, texto) do
        {:ok, audio} -> audio
        _ -> texto
      end
    else
      texto
    end
  end

  # {:ok, {:audio, bytes, opts, texto}} | :erro. O custo e registrado so quando o audio foi gerado.
  defp sintetizar(tenant, texto) do
    case IA.sintetizar(tenant, texto) do
      {:ok, bytes, uso} when is_binary(bytes) and bytes != "" ->
        Evento.custo_audio(tenant, "planejador", "voz", uso)
        {:ok, {:audio, bytes, [mime: uso["mime"] || "audio/ogg; codecs=opus", segundos: uso["segundos"] || 1], texto}}

      _ ->
        :erro
    end
  rescue
    _ -> :erro
  catch
    _, _ -> :erro
  end
end
