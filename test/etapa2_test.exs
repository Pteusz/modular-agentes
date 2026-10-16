# Teste geral da etapa 2 (contrato de automacao). Rodar: MIX_ENV=test mix test
defmodule Etapa2Test do
  use ExUnit.Case
  alias Nucleo.{Registro, Vincular, Canal}

  defmodule Boa do
    @behaviour Nucleo.Automacao
    def versao, do: "0.1.0"
    def contrato, do: %{versao: "1.0", oferece: %{"verifica" => "1.0"}, exige: %{"registro" => "1.0", "canal.texto" => "1.0", "conta" => "1.0"}}
    def referencial, do: %{tipo: :decidivel, regras: [:r1]}
    def retencao, do: [%{chave: "regra_violada", leitura: :ultimo}]
    def aprovacao, do: [:gastar]
  end

  defmodule MajorAlto do
    @behaviour Nucleo.Automacao
    defdelegate versao, to: Boa
    def contrato, do: %{versao: "2.0", oferece: %{}, exige: %{}}
    defdelegate referencial, to: Boa
    defdelegate retencao, to: Boa
    defdelegate aprovacao, to: Boa
  end

  defmodule Empirica do
    @behaviour Nucleo.Automacao
    defdelegate versao, to: Boa
    defdelegate contrato, to: Boa
    def referencial, do: %{tipo: :empirico, regras: []}
    defdelegate retencao, to: Boa
    defdelegate aprovacao, to: Boa
  end

  defmodule SemCallbacks do
    def versao, do: "0.1.0"
  end

  setup_all do
    Registro.migrar!()
    :ok
  end

  setup do: {:ok, t: "tc#{System.unique_integer([:positive])}"}

  test "vinculo compativel passa; incompativel e recusado antes de gravar, com evento e sem alterar o anterior", %{t: t} do
    # falta capacidade da camada do cliente -> recusa, nada gravado
    assert {:error, {:incompativel, [m]}} = Vincular.vincular(t, Boa, Canal.Simulado, %{})
    assert m =~ "conta"
    assert Registro.vinculos() |> Enum.filter(&(&1.tenant == t)) == []

    # MINOR menor que o exigido e MAJOR diferente -> recusa
    assert {:error, _} = Vincular.vincular(t, Boa, Canal.Simulado, %{"conta" => "1.0"} |> Map.put("registro", "0.9"))
    assert {:error, _} = Vincular.vincular(t, Boa, Canal.Simulado, %{"conta" => "2.0"})

    # contrato com MAJOR diferente do nucleo, verificador nao decidivel, modulo fora do behaviour
    assert {:error, {:incompativel, [m2]}} = Vincular.vincular(t, MajorAlto, Canal.Simulado, %{})
    assert m2 =~ "incompativel"
    assert {:error, {:incompativel, [m3]}} = Vincular.vincular(t, Empirica, Canal.Simulado, %{"conta" => "1.0"})
    assert m3 =~ "nao aceito"
    assert {:error, {:incompativel, [_ | _]}} = Vincular.vincular(t, SemCallbacks, Canal.Simulado, %{})
    assert Registro.vinculos() |> Enum.filter(&(&1.tenant == t)) == []
    assert Registro.eventos(t) |> Enum.count(&(&1.tipo == "vinculo_recusado")) == 6

    # MINOR maior que o exigido e compativel; idempotente e registrado
    ok = %{"conta" => "1.3"}
    assert {:ok, :criado} = Vincular.vincular(t, Boa, Canal.Simulado, ok)
    assert {:ok, :ja_vinculado} = Vincular.vincular(t, Boa, Canal.Simulado, ok)
    assert [%{versao: "0.1.0"}] = Registro.vinculos() |> Enum.filter(&(&1.tenant == t))

    # recusa posterior nao desfaz o vinculo existente
    assert {:error, _} = Vincular.vincular(t, Boa, Canal.Simulado, %{})
    assert [_] = Registro.vinculos() |> Enum.filter(&(&1.tenant == t))

    # a automacao declara referencial, retencao e aprovacao
    assert Boa.aprovacao() == [:gastar]
    assert [%{leitura: :ultimo}] = Boa.retencao()
  end
end
