defmodule PTrafego.MixProject do
  use Mix.Project
  @version "1.10.0"

  # Dev local (NUCLEO_LOCAL=1, posto pelo mix.exs da raiz): path. No cliente: git + sparse + tag, sem override.
  defp nucleo do
    if System.get_env("NUCLEO_LOCAL"),
      do: {:nucleo, path: "../nucleo"},
      else: {:nucleo, git: System.get_env("NUCLEO_GIT", "https://github.com/Pteusz/modular-agentes.git"), sparse: "packages/nucleo", tag: System.get_env("NUCLEO_TAG", "nucleo-1.4.0")}
  end

  def project, do: [app: :trafego, version: @version, elixir: "~> 1.19", deps: [nucleo(), {:req, "== 0.7.5"}, {:oban, "== 2.24.1"}]]
  def application, do: [extra_applications: [:logger], mod: {Trafego.Application, []}, env: [
        nucleo_pacote: true,
        # Meta: versao da Graph API FIXADA (subir de versao e decisao, nao acidente). Nada de segredo aqui.
        meta: [base_url: "https://graph.facebook.com", versao: "v26.0", special_ad_categories: ["HOUSING"], fuso: "-0300", targeting: %{"geo_locations" => %{"countries" => ["BR"]}}],
        # OpenAI: modelo e esforco por faixa, trocaveis por config da instancia (precos da pagina oficial, USD por milhao de tokens)
        openai: [
          base_url: "https://api.openai.com",
          modelos: %{pequena: "gpt-6-luna", media: "gpt-6-luna"},
          esforco: %{pequena: "low", media: "medium"},
          max_tokens: 4000,
          timeout: 60_000,
          # transcricao de audio (nota de voz); idioma fixo pt
          transcricao: [modelo: "gpt-transcribe", idioma: "pt"]
        ],
        # audio do WhatsApp: limites antes de baixar/transcrever (nota de voz tipica: ate ~1 min, < 1 MB)
        audio: [max_segundos: 120, max_bytes: 10_000_000],
        # transcricao: USD por minuto (pagina oficial de precos)
        # fala (TTS) tambem em USD por minuto de audio gerado (estimativa; a API de fala nao devolve uso)
        preco_usd_por_minuto: %{"gpt-transcribe" => 0.0045, "gpt-4o-mini-tts" => 0.015},
        # voz da Iara (etapa 5.2.3): modelo, voz feminina, opus (nota de voz do WhatsApp) e duracao estimada por caracteres
        voz: [
          modelo: "gpt-4o-mini-tts",
          voz: "marin",
          formato: "opus",
          chars_por_segundo: 15,
                    instrucoes: "Fale em portugues do Brasil, com voz feminina jovem, calorosa e objetiva, tom informal de colega de equipe falando pelo WhatsApp. Ritmo natural e animado, sem exagero, sem sotaque estrangeiro."
        ],
        preco_usd_por_milhao: %{"gpt-6-luna" => {0.10, 0.50}, "gpt-6-sol" => {2.00, 10.00}},
        criativo: [min_lado: 600, proporcao_min: {9, 16}, proporcao_max: {191, 100}, max_bytes: 30_000_000]
      ]]
end
