defmodule Etapa6GruposTest do
  use ExUnit.Case, async: true
  alias Amarula.{Address, Msg}
  alias Nucleo.Canal

  @pn Address.pn("5511999990000")
  @lid Address.lid("99887766554433")
  @contas [@pn, @lid]

  # imita Amarula.own_chat?/2: from_me e `to` = uma das nossas identidades (a sala nao entra na conta)
  defp own_chat?(%Msg{from_me: true, to: %Address{} = to}), do: Enum.any?(@contas, &Address.same_account?(&1, to))
  defp own_chat?(_), do: false

  defp texto(attrs), do: struct(%Msg{channel: nil, type: :text, content: "oi", raw: nil, from_me: true}, attrs)
  defp filtrar(m), do: Canal.Amarula.filtrar(m, &own_chat?/1, @contas)

  test "conversa consigo mesmo passa (PN, LID, com device e midia)" do
    assert {:entregar, "oi"} = filtrar(texto(channel: @pn, from: %{@pn | device: 3}, to: @pn))
    assert {:entregar, "oi"} = filtrar(texto(channel: @lid, from: %{@lid | device: 5}, to: @lid))
    assert {:entregar, "oi"} = filtrar(texto(channel: %{@pn | device: 2}, from: @pn, to: @pn))
    m = texto(channel: @pn, from: @pn, to: @pn, type: :media, content: nil)
    assert {:midia, ^m} = filtrar(m)
  end

  test "grupo escrito pelo proprio usuario NAO passa (PN e LID) - reproduz o vazamento" do
    grupo = Address.group("120363000000000001")
    assert :ignorar = filtrar(texto(channel: grupo, from: %{@pn | device: 3}, to: @pn))
    assert :ignorar = filtrar(texto(channel: grupo, from: %{@lid | device: 3}, to: @lid))
    assert :ignorar = filtrar(texto(channel: grupo, from: @lid, to: @pn))
  end

  test "grupo de terceiro, chat 1:1 com outro, status, newsletter e sala desconhecida nao passam" do
    outro = Address.pn("5511888880000")
    assert :ignorar = filtrar(texto(channel: Address.group("1203"), from: outro, to: @pn, from_me: false))
    assert :ignorar = filtrar(texto(channel: outro, from: outro, to: @pn, from_me: false))
    assert :ignorar = filtrar(texto(channel: outro, from: @pn, to: outro))
    assert :ignorar = filtrar(texto(channel: Address.lid("111"), from: @lid, to: Address.lid("111")))
    # status@broadcast, newsletter, comunidade: o Amarula nao tem Address para eles (channel nil)
    assert Address.parse("status@broadcast") == nil and Address.parse("123@newsletter") == nil
    assert :ignorar = filtrar(texto(channel: nil, from: @pn, to: @pn))
    assert :ignorar = filtrar(texto(channel: :teste, from: @pn, to: @pn))
  end

  test "AND: mesmo se own_chat? for enganado (sempre true), a sala precisa ser a propria conta" do
    todos = fn _ -> true end
    assert :ignorar = Canal.Amarula.filtrar(texto(channel: Address.group("1203"), from: @pn, to: @pn), todos, @contas)
    assert :ignorar = Canal.Amarula.filtrar(texto(channel: Address.pn("5511888880000"), from: @pn, to: @pn), todos, @contas)
    assert {:entregar, "oi"} = Canal.Amarula.filtrar(texto(channel: @pn, from: @pn, to: @pn), todos, @contas)
    # sem contas conhecidas (ainda sem login): nada entra
    assert :ignorar = Canal.Amarula.filtrar(texto(channel: @pn, from: @pn, to: @pn), todos, [])
    assert :ignorar = Canal.Amarula.filtrar(texto(channel: @pn, from: @pn, to: @pn), todos)
  end

  test "motivo da rejeicao nao carrega conteudo nem numero" do
    grupo = texto(channel: Address.group("1203"), from: @pn, to: @pn, content: "segredo")
    assert {:grupo, "g.us"} = Canal.Amarula.motivo(grupo, &own_chat?/1, @contas)
    assert {:nao_e_proprio, "s.whatsapp.net"} = Canal.Amarula.motivo(texto(channel: Address.pn("5511888880000"), from: @pn, to: @pn), &own_chat?/1, @contas)
    assert {:sem_sala, "desconhecido"} = Canal.Amarula.motivo(texto(channel: nil), &own_chat?/1, @contas)
    refute inspect(Canal.Amarula.motivo(grupo, &own_chat?/1, @contas)) =~ "segredo"
  end

  test "envio vai sempre para a propria conta (destino nao vem da mensagem)" do
    fonte = File.read!(Path.expand("../packages/nucleo/lib/nucleo/canal/amarula.ex", __DIR__))
    assert Canal.Amarula.module_info(:exports)[:enviar_texto] == 2
    assert Canal.Amarula.module_info(:exports)[:enviar_audio] == 3
    # os dois handle_call de envio derivam o jid de Amarula.own_address(conn) e de mais nada
    assert length(Regex.scan(~r/Amarula\.Address\.to_jid\(%\{Amarula\.own_address\(c\) \| device: 0\}\)/, fonte)) == 2
    assert length(Regex.scan(~r/Amarula\.send_(text|media)\(c, jid,/, fonte)) == 2
    refute fonte =~ ~r/handle_call\(\{:enviar[^)]*(msg|jid|destino|para)/
  end
end
