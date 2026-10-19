defmodule Trafego.IA do
  @moduledoc """
  Contrato "provedor de IA" (trocar de modelo/provedor nao muda o dominio). `faixa`: :pequena (ler confirmacao,
  conferir criativo) ou :media (criar/revisar plano). `tarefa`: :planejar | :confirmar | :falar (texto-base -> fala da Iara, entrada
  "base", "situacao", "mensagem_do_corretor", "origem", "primeiro_contato", "perguntar_horario", "omitir_base", "dados"; saida "texto")
  | :horario (le "HH:MM" no texto; saida "horario" ou nil) | :checar_transcricao (saida "duvida": o que ficou ambiguo, ou nil).
  Devolve a saida e o uso (modelo, tokens_in, tokens_out) para o evento custo_tokens. O provedor nunca informa id de conta.
  `chamar/4` e a porta do dominio: aplica o teto de custo de IA do corretor (aviso a 80%, bloqueio a 100%) antes de chamar o provedor.
  """
  alias Trafego.{Evento, Notificar, TetoIA}

  @callback chamar(faixa :: :pequena | :media, tarefa :: atom, entrada :: map) :: {:ok, saida :: map, uso :: map} | {:error, term}

  @doc """
  Provedor em uso. Config explicita (`:trafego, :provedor_ia`) manda: os testes fixam o Falso em config/config.exs, entao o
  ambiente de producao (OPENAI_API_KEY, TRAFEGO_IA) nunca vaza para a suite. Sem config (producao): `escolher/1`.
  """
  def provedor do
    case Application.fetch_env(:trafego, :provedor_ia) do
      {:ok, p} -> p
      :error -> escolher()
    end
  end

  @doc "Escolha pelo ambiente: TRAFEGO_IA=falso | openai manda; senao OpenAI quando OPENAI_API_KEY esta definida; senao Falso."
  def escolher(get_env \\ &System.get_env/1) do
    modo = get_env.("TRAFEGO_IA") |> to_string() |> String.trim() |> String.downcase()
    chave = get_env.("OPENAI_API_KEY") |> to_string() |> String.trim()

    cond do
      modo == "falso" -> Trafego.IA.Falso
      modo == "openai" -> Trafego.IA.OpenAI
      chave != "" -> Trafego.IA.OpenAI
      true -> Trafego.IA.Falso
    end
  end

  @callback transcrever(bytes :: binary, meta :: %{mime: String.t(), segundos: pos_integer}) :: {:ok, texto :: String.t(), uso :: map} | {:error, term}

  @doc "Fala (TTS, etapa 5.2.3): texto -> audio opus (nota de voz). uso: modelo, segundos (estimado), caracteres, mime. Callback opcional."
  @callback sintetizar(texto :: String.t()) :: {:ok, bytes :: binary, uso :: map} | {:error, term}
  @optional_callbacks sintetizar: 1

  @doc "Chamada com teto: {:ok, saida, uso} | {:error, {:teto_ia, info}} (sem chamar o provedor) | {:error, outro}"
  def chamar(tenant, faixa, tarefa, entrada), do: com_teto(tenant, plano_id(entrada), fn -> provedor().chamar(faixa, tarefa, entrada) end)

  @doc "Transcricao de audio com o mesmo teto de custo da IA: {:ok, texto, uso} | {:error, {:teto_ia, info}} | {:error, outro}. Uso: %{modelo, segundos}."
  def transcrever(tenant, bytes, meta), do: com_teto(tenant, nil, fn -> provedor().transcrever(bytes, meta) end)

  @doc """
  Fala com o mesmo teto de custo da IA: {:ok, bytes, uso} | {:error, {:teto_ia, info}} | {:error, outro}. Provedor sem fala = {:error, :sem_voz}.
  O custo NAO e registrado aqui: quem usa o audio registra (Trafego.Voz), so quando ele foi gerado.
  """
  def sintetizar(tenant, texto) do
    com_teto(tenant, nil, fn ->
      mod = provedor()
      Code.ensure_loaded(mod)
      if function_exported?(mod, :sintetizar, 1), do: mod.sintetizar(texto), else: {:error, :sem_voz}
    end)
  end

  defp com_teto(tenant, plano_id, f) do
    case TetoIA.status(tenant) do
      {:bloqueado, info} ->
        Evento.emitir(tenant, "operacao", plano_id, "planejador", "teto_ia_bloqueado", %{"gasto_brl" => info[:gasto], "teto_brl" => info[:teto]})
        if TetoIA.primeira_vez?(tenant, "bloqueio"), do: Notificar.enviar(tenant, TetoIA.mensagem(info))
        {:error, {:teto_ia, info}}

      {:aviso, %{gasto: g, teto: t}} ->
        if TetoIA.primeira_vez?(tenant, "aviso"),
          do: Notificar.enviar(tenant, "Aviso: o custo de IA do mes chegou a #{TetoIA.brl(g)} de #{TetoIA.brl(t)} (teto de IA). Ao chegar no teto eu paro de interpretar mensagens, sem alterar nada.")

        f.()

      :ok ->
        f.()
    end
  end

  defp plano_id(%{"plano" => %{"id" => id}}), do: id
  defp plano_id(%{"plano" => id}) when is_binary(id), do: id
  defp plano_id(_), do: nil
end
