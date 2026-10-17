defmodule PainelBase.Tentativas do
  @moduledoc "Limite de tentativas: login por e-mail (5 falhas / 15 min) e por IP (30 falhas / 15 min); recuperacao por e-mail (5 pedidos / 15 min). Sucesso zera a do e-mail."
  import PainelBase.Banco, only: [q: 2]

  @janela 15 * 60
  @limite %{"e" => 5, "i" => 30, "r" => 5}

  def bloqueado?(tipo, valor), do: contar(tipo, valor) >= @limite[tipo]

  def falha(tipo, valor), do: q("INSERT INTO pb_tentativas (chave) VALUES ($1)", [chave(tipo, valor)]) && :ok
  def zerar(tipo, valor), do: q("DELETE FROM pb_tentativas WHERE chave=$1", [chave(tipo, valor)]) && :ok

  defp contar(tipo, valor) do
    q("SELECT count(*) FROM pb_tentativas WHERE chave=$1 AND em > now() - make_interval(secs => $2)", [chave(tipo, valor), @janela * 1.0]).rows |> hd() |> hd()
  end

  defp chave(tipo, valor), do: tipo <> ":" <> String.downcase(to_string(valor))
end
