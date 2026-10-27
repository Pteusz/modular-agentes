defmodule Trafego.Plataforma.Meta do
  @moduledoc """
  Adaptador Meta (Graph / Marketing API) atras de Trafego.Plataforma. Versao FIXADA em config (:meta, :versao; padrao v26.0).
  Toda campanha nasce e fica PAUSADA (campanha, conjunto e anuncio); nao ha ativar nesta fase. A conta de anuncio vem da credencial
  do tenant (Trafego.Acesso), nunca do modelo. Dinheiro em centavos da moeda da conta (so BRL nesta fase).
  O token vai SO no header Authorization (nunca em URL/corpo) e nunca em erro, log ou evento.
  Mapeamento (para o verificador decidivel ler de volta): nome do conjunto = publico; nome do criativo = midia; mensagem do
  criativo = texto; spend_cap da campanha = teto_total; daily_budget do conjunto = orcamento_diario; start/end_time = janela.
  Limites desta fase: so imagem (video: {:error, :video_nao_suportado}); segmentacao padrao de config (:meta, :targeting) ate haver
  publico estruturado; texto livre do publico fica no nome do conjunto.
  """
  @behaviour Trafego.Plataforma
  alias Trafego.{Config, Criativo}

  @pausado "PAUSED"
  @ativo "ACTIVE"

  # ---- contrato
  @impl true
  def validar_credencial(%{"conta_id" => conta, "token" => _} = cred) do
    conta = conta_id(conta)

    with {:ok, c} <- ver(cred, conta, "id,account_id,account_status,currency", :conta),
         {:ok, _} <- pagina(cred),
         {:ok, ig} <- instagram(cred) do
      info = %{"conta_id" => conta, "moeda" => c["currency"], "conta_status" => c["account_status"], "instagram" => ig}
      {:ok, if(ig == "nao_ligado", do: Map.put(info, "avisos", ["instagram_nao_ligado"]), else: info)}
    end
  end

  # pagina e obrigatoria (os criativos saem por ela); Instagram e opcional: ausente ou nao alcancado NAO bloqueia, vira aviso
  defp pagina(%{"pagina_id" => id} = cred) when id not in [nil, ""], do: ver(cred, id, "id,name", :pagina)
  defp pagina(_), do: {:error, {:inacessivel, :pagina}}

  defp instagram(%{"instagram_id" => id} = cred) when id not in [nil, ""] do
    case ver(cred, id, "id,username", :instagram) do
      {:ok, _} -> {:ok, "ok"}
      {:error, {:inacessivel, :instagram}} -> {:ok, "nao_ligado"}
      {:error, _} = e -> e
    end
  end

  defp instagram(_), do: {:ok, "ausente"}

  @impl true
  def criar_campanha(cred, p) do
    with :ok <- moeda(cred),
         {:ok, bytes, nome, mime} <- criativo(p),
         {:ok, midia} <- subir_midia(cred, bytes, nome, mime),
         {:ok, camp} <- criar(cred, "campaigns", campanha(cred, p), "campaigns", %{}),
         {:ok, conj} <- criar(cred, "adsets", conjunto(cred, p, camp), "adsets", %{"campanha_id" => camp}),
         {:ok, cri} <- criar(cred, "adcreatives", criativo_meta(cred, p, nome, midia), "adcreatives", %{"campanha_id" => camp}),
         {:ok, _ad} <- criar(cred, "ads", anuncio(cred, nome, conj, cri), "ads", %{"campanha_id" => camp}) do
      ler_campanha(cred, camp)
    end
  end

  # leitura: o numero de WhatsApp ligado a Pagina (campo whatsapp_number). Nao cria nada. Se o token nao le o campo, o erro
  # volta e o Executor segue (a Meta ainda decide, e o erro dela e traduzido).
  @impl true
  def numeros_vinculados(%{"pagina_id" => id} = cred) when id not in [nil, ""] do
    case get(cred, id, fields: "id,whatsapp_number") do
      {:ok, %{} = pg} -> {:ok, pg["whatsapp_number"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.map(&String.replace(&1, ~r/\D/, "")) |> Enum.reject(&(&1 == ""))}
      {:error, _} = e -> e
    end
  end

  def numeros_vinculados(_), do: {:error, :sem_pagina}

  @impl true
  def ler_campanha(cred, id) do
    case get(cred, id, fields: campos()) do
      {:ok, c} -> if mesma_conta?(cred, c), do: {:ok, normalizar(c)}, else: {:error, :nao_encontrada}
      {:error, {:graph, cod, _}} when cod in [100, 33, 803] -> {:error, :nao_encontrada}
      e -> e
    end
  end

  @impl true
  def listar_campanhas(cred) do
    with {:ok, %{"data" => dados}} <- get(cred, conta_id(cred["conta_id"]) <> "/campaigns", [fields: "id,name,status", limit: 100], leitura()) do
      {:ok, for(c <- dados, do: %{"id" => c["id"], "nome" => c["name"], "status" => status(c["status"]), "conta_id" => conta_id(cred["conta_id"])})}
    end
  end

  # saldo (6.3): so leitura. Em conta pre-paga o `balance` da Meta e valor DEVIDO (vem 0); o saldo disponivel so aparece no texto de
  # exibicao de funding_source_details ("Saldo disponivel (R$6,99 BRL)"), que o Saldo.parse_centavos/1 le.
  @impl true
  def ler_saldo(cred) do
    with {:ok, r} <- get(cred, conta_id(cred["conta_id"]), [fields: "is_prepay_account,funding_source_details,currency"], leitura()), do: saldo_da_resposta(r)
  end

  @doc false
  def saldo_da_resposta(%{"is_prepay_account" => true} = r) do
    brl? = r["currency"] in [nil, "BRL"]
    saldo = if brl?, do: Trafego.Saldo.parse_centavos(get_in(r, ["funding_source_details", "display_string"]))
    {:ok, %{"tipo" => "pre_pago", "saldo" => saldo}}
  end

  def saldo_da_resposta(%{"is_prepay_account" => false}), do: {:ok, %{"tipo" => "pos_pago", "saldo" => nil}}
  def saldo_da_resposta(_), do: {:error, :resposta_inesperada}

  @campos_insights "campaign_id,spend,reach,clicks,actions"
  @max_paginas 10

  @impl true
  def metricas(cred, id, dias) do
    # acesso por id isolado: a checagem de conta (get_da_conta) continua
    with {:ok, _} <- get_da_conta(cred, id),
         {:ok, r} <- get(cred, id <> "/insights", [fields: @campos_insights, time_range: janela(dias), level: "campaign"], leitura()) do
      {:ok, r |> Map.get("data", []) |> List.first() |> metricas_da_linha()}
    end
  end

  # Lote (painel rapido): a listagem + UM insights da conta com level=campaign casado por campaign_id = 2 chamadas, qualquer que seja
  # o numero de campanhas (antes: 1 + 2N). Os ids vem da propria conta, entao nao ha get_da_conta por campanha. O numero e o mesmo de
  # metricas/3 (mesma funcao de linha; campanha sem linha no insights = zeros). Se so o insights falhar, as campanhas voltam SEM a
  # chave "metricas" e o chamador cai no caminho antigo; erro de token passa como erro.
  @impl true
  def listar_campanhas_com_metricas(cred, dias) do
    conta = conta_id(cred["conta_id"])

    with {:ok, lista} <- listar_campanhas(cred) do
      case insights_da_conta(cred, conta, dias) do
        {:ok, linhas} ->
          por_id = Map.new(linhas, &{&1["campaign_id"], &1})
          {:ok, for(c <- lista, do: Map.put(c, "metricas", metricas_da_linha(por_id[c["id"]])))}

        {:error, :token_invalido} = e ->
          e

        {:error, _} ->
          {:ok, lista}
      end
    end
  end

  defp insights_da_conta(cred, conta, dias), do: paginar(cred, conta <> "/insights", [fields: @campos_insights, time_range: janela(dias), level: "campaign", limit: 500], [], @max_paginas)

  defp paginar(_cred, _caminho, _params, acc, 0), do: {:ok, acc}

  defp paginar(cred, caminho, params, acc, restantes) do
    with {:ok, r} <- get(cred, caminho, params, leitura()) do
      acc = acc ++ (r["data"] || [])

      paging = r["paging"] || %{}

      case get_in(paging, ["cursors", "after"]) do
        depois when is_binary(depois) and is_map_key(paging, "next") -> paginar(cred, caminho, Keyword.put(params, :after, depois), acc, restantes - 1)
        _ -> {:ok, acc}
      end
    end
  end

  defp leitura, do: [receive_timeout: Config.meta(:timeout_leitura, 8_000)]

  defp janela(dias) do
    fim = Date.utc_today()
    Jason.encode!(%{"since" => Date.to_iso8601(Date.add(fim, -(dias - 1))), "until" => Date.to_iso8601(fim)})
  end

  defp metricas_da_linha(linha) do
    linha = linha || %{}
    acoes = for %{"action_type" => t, "value" => v} <- linha["actions"] || [], into: %{}, do: {t, inteiro(v) || 0}
    msgs = acoes["onsite_conversion.messaging_conversation_started_7d"] || 0
    leads = (acoes["lead"] || 0) + (acoes["offsite_conversion.fb_pixel_lead"] || 0)

    %{
      "gasto" => reais_em_centavos(linha["spend"]), "alcance" => inteiro(linha["reach"]) || 0, "cliques" => inteiro(linha["clicks"]) || 0,
      "mensagens_iniciadas" => msgs, "resultados" => msgs + leads
    }
  end

  defp reais_em_centavos(nil), do: 0

  defp reais_em_centavos(s) do
    case Float.parse(to_string(s)) do
      {v, _} -> round(v * 100)
      :error -> 0
    end
  end

  @impl true
  def editar_campanha(_cred, _id, %{"status" => st}) when st not in ["PAUSADA", "PAUSED"], do: {:error, :ativacao_fora_da_fase}

  def editar_campanha(cred, id, attrs) do
    with {:ok, c} <- get_da_conta(cred, id),
         conj = c |> get_in(["adsets", "data"]) |> List.wrap() |> List.first(),
         :ok <- postar(cred, id, campanha_attrs(attrs)),
         :ok <- if(conj, do: postar(cred, conj["id"], conjunto_attrs(attrs, cred)), else: :ok) do
      ler_campanha(cred, id)
    end
  end

  @impl true
  def pausar_campanha(cred, id) do
    with {:ok, c} <- get_da_conta(cred, id),
         ids = [id | for(a <- get_in(c, ["adsets", "data"]) || [], x <- [a | get_in(a, ["ads", "data"]) || []], do: x["id"])],
         :ok <- postar_todos(cred, ids, %{"status" => @pausado}) do
      ler_campanha(cred, id)
    end
  end

  @doc """
  Ativa campanha, conjuntos e anuncios (anuncios primeiro, campanha por ultimo). TRAVADO: so com liberacao explicita
  (config :meta, :permitir_ativacao = true ou env TRAFEGO_ATIVACAO_META=1), que so o Mateus liga. Sem ela nada sai para a Meta.
  """
  @impl true
  def ativar_campanha(cred, id) do
    if Config.meta(:permitir_ativacao, false) == true or System.get_env("TRAFEGO_ATIVACAO_META") == "1" do
      with {:ok, c} <- get_da_conta(cred, id),
           ids = Enum.reverse([id | for(a <- get_in(c, ["adsets", "data"]) || [], x <- [a | get_in(a, ["ads", "data"]) || []], do: x["id"])]),
           :ok <- postar_todos(cred, ids, %{"status" => "ACTIVE"}) do
        ler_campanha(cred, id)
      end
    else
      {:error, :ativacao_nao_liberada}
    end
  end

  # ---- montagem dos objetos (tudo PAUSED)
  defp campanha(_cred, p) do
    %{
      "name" => p["nome"], "objective" => objetivo(p["destino"]), "status" => @pausado,
      "special_ad_categories" => Jason.encode!(Config.meta(:special_ad_categories, ["HOUSING"])),
      "spend_cap" => p["teto_total"], "is_adset_budget_sharing_enabled" => "false"
    }
  end

  defp conjunto(cred, p, camp) do
    %{
      "name" => p["publico"], "campaign_id" => camp, "daily_budget" => p["orcamento_diario"], "billing_event" => "IMPRESSIONS",
      "optimization_goal" => meta_otimizacao(p["destino"]), "bid_strategy" => "LOWEST_COST_WITHOUT_CAP",
      "destination_type" => destino_meta(p["destino"]), "promoted_object" => Jason.encode!(promovido(cred, p)),
      "targeting" => Jason.encode!(Config.meta(:targeting, %{"geo_locations" => %{"countries" => ["BR"]}})),
      "start_time" => "#{p["janela"]["inicio"]}T00:00:00#{fuso()}", "end_time" => "#{p["janela"]["fim"]}T23:59:59#{fuso()}", "status" => @pausado
    }
  end

  defp criativo_meta(cred, p, nome, midia) do
    {link, cta} = chamada(p)
    texto = get_in(p, ["criativo", "texto"]) || ""

    spec =
      case midia do
        {:imagem, hash} -> %{"page_id" => cred["pagina_id"], "link_data" => %{"image_hash" => hash, "link" => link, "message" => texto, "call_to_action" => cta}}
        {:video, id, miniatura} -> %{"page_id" => cred["pagina_id"], "video_data" => %{"video_id" => id, "image_url" => miniatura, "message" => texto, "call_to_action" => cta}}
      end

    spec = if cred["instagram_id"], do: Map.put(spec, "instagram_user_id", cred["instagram_id"]), else: spec
    %{"name" => nome, "object_story_spec" => Jason.encode!(spec)}
  end

  defp anuncio(_cred, nome, conj, cri),
    do: %{"name" => nome, "adset_id" => conj, "creative" => Jason.encode!(%{"creative_id" => cri}), "status" => @pausado}

  defp objetivo("whatsapp"), do: "OUTCOME_ENGAGEMENT"
  defp objetivo(_), do: "OUTCOME_LEADS"

  defp meta_otimizacao("whatsapp"), do: "CONVERSATIONS"
  defp meta_otimizacao("formulario"), do: "LEAD_GENERATION"
  defp meta_otimizacao(_), do: "OFFSITE_CONVERSIONS"

  defp destino_meta("whatsapp"), do: "WHATSAPP"
  defp destino_meta("formulario"), do: "ON_AD"
  defp destino_meta(_), do: "WEBSITE"

  defp destino_plano("WHATSAPP"), do: "whatsapp"
  defp destino_plano("ON_AD"), do: "formulario"
  defp destino_plano(_), do: "site"

  defp promovido(_cred, %{"destino" => "site"} = p), do: %{"pixel_id" => p["pixel"], "custom_event_type" => "LEAD"}
  # WhatsApp: o numero no promoted_object PRECISA estar vinculado a Pagina/conta (a Meta recusa com "This WhatsApp phone number is not
  # linked to your account"); o Executor confere antes de criar (numeros_vinculados/1). Sem numero: so a Pagina (WhatsApp ligado a ela).
  defp promovido(cred, %{"destino" => "whatsapp", "numero" => n}) when is_binary(n) and n != "", do: %{"page_id" => cred["pagina_id"], "whatsapp_phone_number" => n}
  defp promovido(cred, _p), do: %{"page_id" => cred["pagina_id"]}

  defp chamada(%{"destino" => "whatsapp"} = p) do
    link = if p["numero"] in [nil, ""], do: "https://api.whatsapp.com/send", else: "https://api.whatsapp.com/send?phone=#{p["numero"]}"
    {link, %{"type" => "WHATSAPP_MESSAGE", "value" => %{"app_destination" => "WHATSAPP"}}}
  end

  defp chamada(%{"destino" => "formulario"} = p), do: {"http://fb.me/", %{"type" => "SIGN_UP", "value" => %{"lead_gen_form_id" => p["formulario"]}}}
  defp chamada(p), do: (u = p["url_final"] || p["url"]; {u, %{"type" => "LEARN_MORE", "value" => %{"link" => u}}})

  defp campanha_attrs(a), do: %{"name" => a["nome"], "spend_cap" => a["teto_total"]} |> Map.reject(fn {_, v} -> is_nil(v) end)

  defp conjunto_attrs(a, _cred) do
    j = a["janela"]

    %{"daily_budget" => a["orcamento_diario"]}
    |> then(&if j, do: Map.merge(&1, %{"start_time" => "#{j["inicio"]}T00:00:00#{fuso()}", "end_time" => "#{j["fim"]}T23:59:59#{fuso()}"}), else: &1)
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp fuso, do: Config.meta(:fuso, "-0300")

  # ---- leitura normalizada (o que o verificador decidivel compara com o plano)
  defp campos,
    do:
      "id,name,status,objective,spend_cap,account_id,adsets{id,name,status,daily_budget,start_time,end_time,destination_type,ads{id,name,status,creative{id,name,object_story_spec}}}"

  defp normalizar(c) do
    conjs = get_in(c, ["adsets", "data"]) || []
    primeiro = List.first(conjs) || %{}
    todos = [c | for(a <- conjs, x <- [a | get_in(a, ["ads", "data"]) || []], do: x)]

    %{
      "id" => c["id"], "nome" => c["name"], "conta_id" => "act_" <> to_string(c["account_id"]), "objetivo" => c["objective"],
      "status" =>
        cond do
          Enum.all?(todos, &(&1["status"] == @pausado)) -> "PAUSADA"
          Enum.all?(todos, &(&1["status"] == @ativo)) -> "ATIVA"
          true -> status(c["status"], todos)
        end,
      "destino" => destino_plano(primeiro["destination_type"]), "orcamento_diario" => inteiro(primeiro["daily_budget"]),
      "teto_total" => inteiro(c["spend_cap"]),
      "janela" => %{"inicio" => dia(primeiro["start_time"]), "fim" => dia(primeiro["end_time"])},
      "conjuntos" =>
        for a <- conjs do
          %{
            "id" => a["id"], "status" => status(a["status"]), "publico" => a["name"],
            "anuncios" =>
              for ad <- get_in(a, ["ads", "data"]) || [] do
                spec = get_in(ad, ["creative", "object_story_spec"]) || %{}
                %{"id" => ad["id"], "status" => status(ad["status"]), "criativo" => %{"midia" => nome_criativo(get_in(ad, ["creative", "name"])), "texto" => get_in(spec, ["link_data", "message"]) || get_in(spec, ["video_data", "message"])}}
              end
          }
        end
    }
  end

  # a Meta anexa ao nome do criativo um sufixo automatico " AAAA-MM-DD-<hex>"; o plano guarda so o nome enviado
  @doc false
  def nome_criativo(n) when is_binary(n), do: String.replace(n, ~r/\s\d{4}-\d{2}-\d{2}-[0-9a-f]+$/, "")
  def nome_criativo(n), do: n

  defp status(@pausado), do: "PAUSADA"
  defp status(@ativo), do: "ATIVA"
  defp status(s), do: s
  defp status(s, todos), do: if(s in [@pausado, @ativo], do: "FILHOS_COM_STATUS_DIFERENTE:" <> Enum.map_join(todos, ",", & &1["status"]), else: s)

  defp inteiro(nil), do: nil
  defp inteiro(n) when is_integer(n), do: n

  defp inteiro(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp dia(nil), do: nil
  defp dia(s), do: String.slice(s, 0, 10)

  # ---- criativo
  defp criativo(p) do
    with bytes when is_binary(bytes) <- p["criativo_bytes"] || {:error, :criativo_ausente},
         {:ok, %{formato: f}} <- Criativo.conferir(bytes) |> reprovado() do
      nome = get_in(p, ["criativo", "midia"]) || "criativo"

      case f do
        "mp4" -> {:ok, bytes, nome, "video/mp4"}
        "png" -> {:ok, bytes, nome, "image/png"}
        "jpeg" -> {:ok, bytes, nome, "image/jpeg"}
      end
    end
  end

  defp reprovado({:error, _}), do: {:error, :criativo_reprovado}
  defp reprovado(ok), do: ok

  defp subir_midia(cred, bytes, nome, "video/mp4"), do: subir_video(cred, bytes, nome)
  defp subir_midia(cred, bytes, nome, mime), do: with({:ok, hash} <- subir_imagem(cred, bytes, nome, mime), do: {:ok, {:imagem, hash}})

  # video: sobe (multipart), espera a Meta terminar de processar e usa a miniatura que ela gera
  defp subir_video(cred, bytes, nome) do
    opcoes = [form_multipart: [name: nome, source: {bytes, filename: nome, content_type: "video/mp4"}], receive_timeout: Config.meta(:timeout_video, 180_000)]

    with {:ok, %{"id" => id}} <- post(cred, conta_id(cred["conta_id"]) <> "/advideos", opcoes),
         {:ok, miniatura} <- esperar_video(cred, id, Config.meta(:video_tentativas, 60)) do
      {:ok, {:video, id, miniatura}}
    else
      {:ok, _} -> {:error, :resposta_inesperada}
      {:error, e} -> {:error, e}
    end
  end

  defp esperar_video(_cred, _id, 0), do: {:error, :video_processando}

  defp esperar_video(cred, id, restantes) do
    case get(cred, id, fields: "status,picture") do
      {:ok, %{"status" => %{"video_status" => "ready"}, "picture" => pic}} when is_binary(pic) -> {:ok, pic}
      {:ok, %{"status" => %{"video_status" => "error"}}} -> {:error, :video_reprovado_pela_meta}
      {:ok, _} -> Process.sleep(Config.meta(:video_espera_ms, 3_000)); esperar_video(cred, id, restantes - 1)
      {:error, e} -> {:error, e}
    end
  end

  defp subir_imagem(cred, bytes, nome, mime) do
    with {:ok, %{"images" => imagens}} <- post(cred, conta_id(cred["conta_id"]) <> "/adimages", form_multipart: [filename: {bytes, filename: nome, content_type: mime}]),
         %{"hash" => hash} <- imagens |> Map.values() |> List.first() do
      {:ok, hash}
    else
      {:error, e} -> {:error, e}
      _ -> {:error, :resposta_inesperada}
    end
  end

  defp moeda(%{"moeda" => m}) when m not in [nil, "BRL"], do: {:error, :moeda_nao_suportada}
  defp moeda(_), do: :ok

  # ---- http
  defp criar(cred, borda, campos, etapa, parcial) do
    case post(cred, conta_id(cred["conta_id"]) <> "/" <> borda, form: form(campos)) do
      {:ok, %{"id" => id}} -> {:ok, id}
      {:ok, _} -> {:error, {:parcial, etapa, parcial}}
      {:error, :token_invalido} -> {:error, :token_invalido}
      {:error, e} when parcial == %{} -> {:error, e}
      {:error, e} -> {:error, {:parcial, etapa, Map.put(parcial, "erro", Trafego.Executor.motivo(e))}}
    end
  end

  defp form(m), do: for({k, v} <- m, not is_nil(v), do: {k, to_string(v)})

  defp postar(_cred, _id, attrs) when attrs == %{}, do: :ok

  defp postar(cred, id, attrs) do
    case post(cred, id, form: form(attrs)) do
      {:ok, _} -> :ok
      e -> e
    end
  end

  defp postar_todos(cred, ids, attrs), do: Enum.reduce_while(ids, :ok, fn id, _ -> (case postar(cred, id, attrs) do :ok -> {:cont, :ok}; e -> {:halt, e} end) end)

  defp get_da_conta(cred, id) do
    case get(cred, id, fields: campos()) do
      {:ok, c} -> if mesma_conta?(cred, c), do: {:ok, c}, else: {:error, :nao_encontrada}
      {:error, {:graph, cod, _}} when cod in [100, 33, 803] -> {:error, :nao_encontrada}
      e -> e
    end
  end

  defp mesma_conta?(cred, c), do: to_string(c["account_id"]) == String.replace_prefix(conta_id(cred["conta_id"]), "act_", "")

  defp ver(cred, id, fields, qual) do
    case get(cred, id, fields: fields) do
      {:ok, c} -> {:ok, c}
      {:error, {:graph, _, _}} -> {:error, {:inacessivel, qual}}
      e -> e
    end
  end


  defp conta_id("act_" <> _ = c), do: c
  defp conta_id(c), do: "act_" <> to_string(c)

  defp get(cred, caminho, params, extra \\ []), do: pedir(cred, :get, caminho, [params: params] ++ extra)
  defp post(cred, caminho, opcoes), do: pedir(cred, :post, caminho, opcoes)

  # a Graph responde JSON com content-type text/javascript: o Req nao decodifica, entao decodificamos aqui
  defp decodificar({:ok, %{body: b} = r}) when is_binary(b) do
    case Jason.decode(b) do
      {:ok, m} -> {:ok, %{r | body: m}}
      _ -> {:ok, r}
    end
  end

  defp decodificar(r), do: r

  # a Graph so diz "Invalid parameter"; o motivo real vem em error_subcode / error_user_msg
  defp detalhe(e) do
    [e["error_subcode"] && "sub=#{e["error_subcode"]}", e["error_user_msg"] || e["message"]] |> Enum.reject(&is_nil/1) |> Enum.map_join(" ", &to_string/1)
  end

  defp pedir(cred, metodo, caminho, opcoes) do
    url = "#{Config.meta(:base_url, "https://graph.facebook.com")}/#{Config.meta(:versao, "v26.0")}/#{caminho}"

    req = [method: metodo, url: url, headers: [{"authorization", "Bearer " <> cred["token"]}], retry: false, receive_timeout: Config.meta(:timeout, 30_000)] |> Keyword.merge(opcoes)

    case Req.request(req) |> decodificar() do
      {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, b}
      {:ok, %{body: %{"error" => %{"code" => c}}}} when c in [190, 102] -> {:error, :token_invalido}
      {:ok, %{body: %{"error" => %{"code" => c} = e}}} when c in [4, 17, 32, 613, 80004] -> {:error, {:limite_de_taxa, e["message"] && String.slice(e["message"], 0, 120)}}
      {:ok, %{body: %{"error" => %{"code" => c} = e}}} -> {:error, {:graph, c, String.slice(detalhe(e), 0, 200)}}
      {:ok, %{status: 401}} -> {:error, :token_invalido}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, %{reason: :timeout}} -> {:error, :timeout}
      {:error, ex} -> {:error, {:rede, ex |> Exception.message() |> String.slice(0, 120)}}
    end
  end
end
