defmodule Nucleo.Verificador do
  @moduledoc "Verificador decidivel: cada regra do referencial e `%{nome: atom, ok?: (ctx -> boolean)}`. Devolve as regras violadas."
  def violadas(%{tipo: :decidivel, regras: regras}, ctx), do: for(%{nome: n, ok?: f} <- regras, not f.(ctx), do: n)
end
