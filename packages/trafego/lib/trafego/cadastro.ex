defmodule Trafego.Cadastro do
  @moduledoc """
  Numero de WhatsApp do corretor vindo do CADASTRO (etapa 5.2.3): o destino dos anuncios e sempre o numero cadastrado dele, sem
  perguntar. Fonte: ge_corretores.numero (tabela da gestao, mesmo Postgres; lida so por SQL, o trafego nao depende de codigo da
  gestao), depois o numero do WhatsApp pareado do tenant (Nucleo.Canal.Estado). Sem nenhum dos dois: nil e a Iara pergunta, uma vez.
  Configuravel por :numero_cadastrado (funcao tenant -> numero) nos testes. Devolve "55DDDnumero" ou nil.
  """
  alias Trafego.Ficha

  def numero(tenant) do
    bruto =
      case Application.get_env(:trafego, :numero_cadastrado) do
        f when is_function(f, 1) -> f.(tenant)
        _ -> do_banco(tenant) || do_pareado(tenant)
      end

    case bruto && Ficha.normalizar_numero(bruto) do
      {:ok, n} -> n
      _ -> nil
    end
  end

  defp do_banco(tenant) do
    sql = "SELECT numero FROM ge_corretores WHERE tenant_id = $1 AND status = 'ativo' AND to_regclass('ge_corretores') IS NOT NULL"

    case Postgrex.query(Nucleo.Registro, sql, [to_string(tenant)]) do
      {:ok, %{rows: [[n]]}} when is_binary(n) and n != "" -> n
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp do_pareado(tenant) do
    case Nucleo.Canal.Estado.numero(tenant) do
      n when is_binary(n) and n != "" -> n
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
