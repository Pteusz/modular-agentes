defmodule Trafego.AbaIA do
  @moduledoc "Aba IA: projecao dos eventos do tenant por papel (fez / aprendeu / erros). Nao guarda nada; nunca inclui a conversa do corretor."
  alias Nucleo.Registro
  alias Trafego.{Aprendizado, Evento}

  @vazio %{fez: [], aprendeu: [], erros: []}

  def projetar(tenant) do
    base = Map.new(~w(planejador executor verificador monitor)a, &{&1, @vazio})

    por_papel =
      for %{tipo: t, dados: %{"papel" => p} = d} <- Registro.eventos(tenant), t in Evento.tipos(), reduce: base do
        acc ->
          papel = String.to_existing_atom(p)
          erro? = Map.has_key?(d, "erro") or Map.get(d, "violadas", []) != []
          campo = if erro?, do: :erros, else: :fez
          Map.update!(acc, papel, &Map.update!(&1, campo, fn l -> l ++ [%{tipo: t, ref: d["ref"]}] end))
      end

    aprendeu = for r <- Aprendizado.historico(tenant), r["regra_violada"], do: r["regra_violada"]
    update_in(por_papel.planejador.aprendeu, fn _ -> Enum.uniq(aprendeu) end)
  end
end
