defmodule Nucleo.Manifesto do
  @moduledoc "Manifesto de versoes exatas (pacotes carregados, runtime, libs fixadas com ==) e vinculos ativos."

  @doc "Pacotes do projeto carregados (apps com env nucleo_pacote: true) => versao lida de Application.spec."
  def carregados do
    for {app, _, _} <- Application.loaded_applications(), Application.get_env(app, :nucleo_pacote), into: %{} do
      {app, app |> Application.spec(:vsn) |> to_string()}
    end
  end

  @doc "Compara o manifesto declarado (%{app => versao}) com o carregado. Divergencia e erro."
  def validar(declarado) do
    carregado = carregados()

    erros =
      for app <- Enum.uniq(Map.keys(declarado) ++ Map.keys(carregado)), declarado[app] != carregado[app] do
        "#{app}: declarado #{inspect(declarado[app])}, carregado #{inspect(carregado[app])}"
      end

    if erros == [], do: :ok, else: {:error, erros}
  end

  def gerar do
    v = fn app -> app |> Application.spec(:vsn) |> to_string() end

    %{
      nucleo: v.(:nucleo),
      amarula: v.(:amarula),
      postgrex: v.(:postgrex),
      jason: v.(:jason),
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)) <> "/erts-" <> to_string(:erlang.system_info(:version)),
      vinculos: Nucleo.Registro.vinculos()
    }
    |> Map.merge(carregados())
  end
end
