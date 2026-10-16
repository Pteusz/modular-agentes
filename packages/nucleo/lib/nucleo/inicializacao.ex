defmodule Nucleo.Inicializacao do
  @moduledoc """
  Valida os vinculos contra o que esta carregado (modulo + contrato atual). Reavaliada a cada inicializacao:
  - contrato incompativel (MAJOR.MINOR) -> vinculo inativo_incompativel + evento (so daquele tenant/automacao);
  - voltou a ser compativel -> vinculo_reativado (nada e apagado);
  - versao de codigo diferente com contrato compativel -> so atualiza a versao registrada (+ evento);
  - vinculo sem contrato registrado recebe o carregado (contrato_registrado).
  Vinculos cuja automacao nao e um modulo com contrato (ex.: esqueleto) nao sao tocados.
  """
  require Logger
  alias Nucleo.{Automacao, Registro}

  def validar_todos, do: validar_todos(%{})

  def validar_todos(camada) do
    for t <- Registro.tenants_vinculados(), do: validar(t, camada)

    case Registro.inativos() do
      [] -> Logger.info("inicializacao: nenhum vinculo inativo")
      ins -> Logger.warning("inicializacao: vinculos inativos (incompativeis): " <> inspect(ins))
    end

    :ok
  end

  def validar(tenant), do: validar(tenant, %{})

  def validar(tenant, camada) do
    linhas = for l <- Registro.contratos(tenant), do: {l, modulo(l.automacao)}
    carregados = for {l, m} <- linhas, m != nil, into: %{}, do: {l.automacao, m.contrato()}

    for {l, m} <- linhas, m != nil or l.contrato != nil do
      fornece = for({a, c} <- carregados, a != l.automacao, reduce: camada, do: (acc -> Map.merge(acc, c.oferece)))
      resultado = if m, do: Automacao.compativel(m, fornece), else: {:error, ["modulo nao carregado"]}
      aplicar(tenant, l, m, resultado)
    end

    :ok
  end

  defp modulo(automacao) do
    mod = Module.concat([automacao])
    if Code.ensure_loaded?(mod) and function_exported?(mod, :contrato, 0), do: mod
  end

  defp aplicar(t, l, mod, :ok) do
    contrato = mod.contrato() |> Jason.encode!() |> Jason.decode!()

    if mod.versao() != l.versao or contrato != l.contrato do
      Registro.gravar_vinculo(t, l.automacao, mod.versao(), l.canal, mod.contrato())
      tipo = if l.contrato == nil, do: "contrato_registrado", else: "versao_registrada_atualizada"
      Registro.evento(t, tipo, %{"automacao" => l.automacao, "de" => l.versao, "para" => mod.versao()})
    end

    if l.estado != "ativo" do
      Registro.marcar_estado(t, l.automacao, "ativo")
      Registro.evento(t, "vinculo_reativado", %{"automacao" => l.automacao, "versao" => mod.versao()})
    end
  end

  defp aplicar(t, l, mod, {:error, motivos}) do
    if l.estado != "inativo_incompativel" do
      Registro.marcar_estado(t, l.automacao, "inativo_incompativel")

      Registro.evento(t, "inativo_incompativel", %{
        "automacao" => l.automacao,
        "versao_registrada" => l.versao,
        "versao_carregada" => mod && mod.versao(),
        "motivos" => motivos
      })
    end
  end
end
