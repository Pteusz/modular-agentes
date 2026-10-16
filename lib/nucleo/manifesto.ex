defmodule Nucleo.Manifesto do
  @moduledoc "Manifesto de versoes exatas (nucleo, runtime, libs fixadas com ==) e vinculos ativos."
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
  end
end
