defmodule Trafego.Plano do
  @moduledoc """
  Plano generico v1 (mapa de chaves string, guardado versionado no registro do tenant em "plano:<id>").
  Destino site | whatsapp | formulario; o resultado deriva do destino; cada destino declara EXIGENCIAS
  (mesmo mecanismo de oferta/exigencia do nucleo: `Nucleo.Automacao.nao_atendidas/2`) e o plano so confirma sem pendencias.
  Dinheiro em centavos de real. Status: rascunho | aguardando_confirmacao | confirmado | executado | verificado | divergente | recusado | erro.
  """
  alias Nucleo.{Automacao, Registro}

  @resultados %{"site" => "evento_pixel", "whatsapp" => "conversa_iniciada", "formulario" => "lead"}
  @exigencias %{
    "site" => %{"url" => "1.0", "pixel" => "1.0"},
    "whatsapp" => %{"numero" => "1.0"},
    "formulario" => %{"formulario" => "1.0"}
  }

  def exigencias(destino), do: Map.get(@exigencias, destino, %{})

  # ---- registro
  def novo(tenant) do
    n = ((Registro.ler(tenant, "trafego_seq") || %{})["n"] || 0) + 1
    Registro.gravar(tenant, "trafego_seq", %{"n" => n})
    plano = %{"id" => "p#{n}", "status" => "rascunho", "atencao" => []}
    salvar(tenant, plano)
    plano
  end

  def salvar(tenant, %{"id" => id} = plano) do
    Registro.gravar(tenant, "plano:" <> id, plano)
    plano
  end

  def ler(tenant, id), do: Registro.ler(tenant, "plano:" <> id)

  def listar(tenant) do
    n = (Registro.ler(tenant, "trafego_seq") || %{})["n"] || 0
    for i <- 1..n//1, do: ler(tenant, "p#{i}")
  end

  def atual(tenant) do
    case Registro.ler(tenant, "trafego_atual") do
      %{"plano_id" => id} when is_binary(id) -> ler(tenant, id)
      _ -> nil
    end
  end

  def definir_atual(tenant, id), do: Registro.gravar(tenant, "trafego_atual", %{"plano_id" => id})

  # ---- conteudo
  @doc "Mescla o que o planejador devolveu. O id de conta NUNCA entra (vem do registro do tenant). Devolve {plano, ignorados}."
  def mesclar(plano, parcial) do
    {ignorados, parcial} = Map.split(parcial, ["conta_id"])
    parcial = Map.reject(parcial, fn {_, v} -> v in [nil, ""] end)
    novo = Map.merge(plano, parcial, fn k, a, b when k in ["meta", "criativo", "janela"] and is_map(a) and is_map(b) -> Map.merge(a, b); _, _, b -> b end)

    novo =
      case novo["destino"] do
        nil -> novo
        d -> Map.put(novo, "resultado", @resultados[d])
      end

    {com_url(novo), Map.keys(ignorados)}
  end

  # imovel opcional: monta a URL quando o destino e o site
  defp com_url(%{"destino" => "site", "url" => url, "imovel" => im} = p) when is_binary(url) and is_binary(im),
    do: Map.put(p, "url_final", url <> if(String.contains?(url, "?"), do: "&", else: "?") <> "imovel=" <> im)

  defp com_url(p), do: p

  @doc "Pendencias: exigencias do destino nao satisfeitas, campos genericos faltando ou invalidos."
  def pendencias(plano) do
    destino = if plano["destino"] in Map.keys(@exigencias), do: [], else: ["destino"]

    campos =
      for {campo, ok?} <- [
            {"criativo", presente?(get_in(plano, ["criativo", "midia"]))},
            {"orcamento_diario", is_integer(plano["orcamento_diario"]) and plano["orcamento_diario"] > 0},
            {"teto_total", is_integer(plano["teto_total"]) and plano["teto_total"] > 0},
            {"janela", presente?(get_in(plano, ["janela", "inicio"])) and presente?(get_in(plano, ["janela", "fim"]))},
            {"publico", presente?(plano["publico"])},
            {"meta", is_integer(get_in(plano, ["meta", "resultados"])) and is_integer(get_in(plano, ["meta", "custo_max"]))}
          ],
          not ok?,
          do: campo

    # ordem de pergunta (a Iara pergunta uma por vez): destino, o que o destino exige, criativo, dinheiro, janela, publico, meta, invalidos
    destino ++ exigencias_faltando(plano) ++ campos ++ invalidos(plano)
  end

  @doc "Plano sem nenhum conteudo (so id/status): o corretor ainda nao disse nada util (ex.: um 'oi')."
  def vazio?(plano), do: Map.drop(plano, ["id", "status", "atencao", "ficha"]) == %{}

  @doc "Como a Iara chama cada pendencia (o codigo fica no texto: o significado do erro nao depende da fala)."
  def rotulo("destino"), do: "destino (para onde o anuncio leva: site, whatsapp ou formulario)"
  def rotulo("url"), do: "url (o link do site)"
  def rotulo("pixel"), do: "pixel (o codigo de rastreio do site)"
  def rotulo("numero"), do: "numero (o whatsapp que recebe os contatos)"
  def rotulo("formulario"), do: "formulario (o id do formulario)"
  def rotulo("criativo"), do: "criativo (a imagem ou o video do anuncio, e o texto dele)"
  def rotulo("orcamento_diario"), do: "orcamento_diario (quanto gastar por dia)"
  def rotulo("teto_total"), do: "teto_total (o maximo para gastar no total)"
  def rotulo("janela"), do: "janela (de que dia ate que dia roda)"
  def rotulo("publico"), do: "publico (quem deve ver o anuncio)"
  def rotulo("meta"), do: "meta (quantos resultados quer e quanto paga no maximo por cada um)"
  def rotulo(outro), do: outro

  defp exigencias_faltando(plano) do
    exige = exigencias(plano["destino"])
    fornece = for k <- Map.keys(exige), presente?(plano[k]), into: %{}, do: {k, "1.0"}
    if Automacao.nao_atendidas(exige, fornece) == [], do: [], else: Map.keys(exige) -- Map.keys(fornece)
  end

  defp invalidos(p) do
    d = p["orcamento_diario"]
    t = p["teto_total"]

    (if is_integer(d) and is_integer(t) and t < d, do: ["teto_menor_que_diario"], else: []) ++
      (case {Date.from_iso8601(get_in(p, ["janela", "inicio"]) || ""), Date.from_iso8601(get_in(p, ["janela", "fim"]) || "")} do
         {{:ok, i}, {:ok, f}} -> if Date.compare(f, i) == :lt, do: ["janela_invalida"], else: []
         {{:ok, _}, _} -> ["janela_invalida"]
         {_, {:ok, _}} -> ["janela_invalida"]
         _ -> []
       end)
  end

  defp presente?(v), do: v not in [nil, ""]

  def situacao(p),
    do: %{"destino" => p["destino"], "publico" => p["publico"], "orcamento_diario" => p["orcamento_diario"], "criativo_tipo" => criativo_tipo(p)}

  defp criativo_tipo(p) do
    case Path.extname(get_in(p, ["criativo", "midia"]) || "") |> String.downcase() do
      e when e in [".mp4", ".mov"] -> "video"
      "" -> nil
      _ -> "imagem"
    end
  end

  @nome_max 60
  @rotulos_destino %{"whatsapp" => "WhatsApp", "site" => "Site", "formulario" => "Formulário"}

  @doc "Nome da campanha na plataforma: \"<imovel> · <destino>\". O imovel e dado do corretor: sem controle, espacos colapsados, ate #{@nome_max} caracteres (corta em palavra). Sem imovel: \"Campanha · <destino> <id do plano>\"."
  def nome_campanha(p) do
    destino = rotulo_destino(p["destino"])

    case limpar_nome(p["imovel"]) do
      "" -> "Campanha · #{destino} #{p["id"]}"
      imovel -> "#{imovel} · #{destino}"
    end
  end

  defp rotulo_destino(d), do: Map.get(@rotulos_destino, d) || String.capitalize(to_string(d))

  defp limpar_nome(v) when is_binary(v) do
    limpo = v |> String.replace(~r/[[:cntrl:]\s]+/u, " ") |> String.trim()

    if String.length(limpo) <= @nome_max do
      limpo
    else
      corte = String.slice(limpo, 0, @nome_max)

      if String.at(limpo, @nome_max) == " " or not String.contains?(corte, " "),
        do: String.trim(corte),
        else: corte |> String.replace(~r/\s+\S*$/u, "") |> String.trim()
    end
  end

  defp limpar_nome(_), do: ""

  def params_campanha(p),
    do: %{
      "nome" => nome_campanha(p), "objetivo" => p["resultado"], "destino" => p["destino"],
      "orcamento_diario" => p["orcamento_diario"], "teto_total" => p["teto_total"], "janela" => p["janela"],
      "publico" => p["publico"], "criativo" => p["criativo"],
      "url" => p["url"], "url_final" => p["url_final"], "pixel" => p["pixel"], "numero" => p["numero"], "formulario" => p["formulario"]
    }

  def brl(c) when is_integer(c), do: "R$ #{div(c, 100)},#{c |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  def brl(_), do: "?"

  def resumo(p) do
    "Plano #{p["id"]}: destino #{p["destino"]} (resultado: #{p["resultado"]}); publico: #{p["publico"]}; " <>
      "criativo: #{get_in(p, ["criativo", "midia"])}; orcamento diario #{brl(p["orcamento_diario"])}, teto #{brl(p["teto_total"])}; " <>
      "janela #{get_in(p, ["janela", "inicio"])} a #{get_in(p, ["janela", "fim"])}; meta #{get_in(p, ["meta", "resultados"])} resultados a ate #{brl(get_in(p, ["meta", "custo_max"]))} cada."
  end
end
