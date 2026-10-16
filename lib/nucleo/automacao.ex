defmodule Nucleo.Automacao do
  @moduledoc """
  Contrato de automacao (versao do contrato != versao do codigo). Toda automacao implementa:
  - versao/0: versao do codigo "X.Y.Z"
  - contrato/0: %{versao: "MAJOR.MINOR", oferece: %{cap => "M.m"}, exige: %{cap => "M.m"}}
  - referencial/0: %{tipo: :decidivel, regras: [..]} (verificador + catalogo de regras)
  - retencao/0: [%{chave: "..", leitura: :ultimo | :historico}] (o que reter e como e lido de volta)
  - aprovacao/0: [atom] (acoes que exigem aprovacao do usuario)
  """
  @callback versao() :: String.t()
  @callback contrato() :: %{versao: String.t(), oferece: map, exige: map}
  @callback referencial() :: %{tipo: atom, regras: list}
  @callback retencao() :: [%{chave: String.t(), leitura: :ultimo | :historico}]
  @callback aprovacao() :: [atom]

  @contrato_do_nucleo "1.0"
  @tipos_aceitos [:decidivel]
  def contrato_do_nucleo, do: @contrato_do_nucleo

  @doc "Capacidades que o nucleo fornece a qualquer automacao."
  def capacidades_nucleo, do: %{"registro" => "1.0", "gancho" => "1.0", "canal.texto" => "1.0"}

  @doc "Valida forma da automacao e encaixe com o que o nucleo + camada do cliente fornecem. :ok | {:error, [motivo]}"
  def compativel(mod), do: compativel(mod, %{})
  def compativel(mod, camada) do
    with :ok <- forma(mod) do
      c = mod.contrato()
      fornece = Map.merge(capacidades_nucleo(), camada)

      erros =
        (if major(c.versao) == major(@contrato_do_nucleo), do: [], else: ["contrato #{c.versao} incompativel com o do nucleo #{@contrato_do_nucleo}"]) ++
          (if mod.referencial().tipo in @tipos_aceitos, do: [], else: ["verificador #{inspect(mod.referencial().tipo)} nao aceito nesta etapa"]) ++
          for {cap, req} <- c.exige, not atende?(fornece[cap], req), do: "exige #{cap} #{req}, fornecido #{inspect(fornece[cap])}"

      if erros == [], do: :ok, else: {:error, erros}
    end
  end

  defp forma(mod) do
    Code.ensure_loaded(mod)
    faltam = for {f, a} <- __MODULE__.behaviour_info(:callbacks), not function_exported?(mod, f, a), do: "falta #{f}/#{a}"
    if Code.ensure_loaded?(mod) and faltam == [], do: :ok, else: {:error, if(faltam == [], do: ["modulo inexistente"], else: faltam)}
  end

  defp atende?(nil, _), do: false
  defp atende?(oferecido, exigido), do: major(oferecido) == major(exigido) and minor(oferecido) >= minor(exigido)
  defp major(v), do: v |> String.split(".") |> hd() |> String.to_integer()
  defp minor(v), do: v |> String.split(".") |> Enum.at(1, "0") |> String.to_integer()
end
