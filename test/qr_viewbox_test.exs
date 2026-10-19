defmodule QrViewboxTest do
  use ExUnit.Case, async: true

  test "o SVG do QR tem viewBox e nao tem tamanho fixo (encolhe sem recortar)" do
    {:ok, svg} = PainelBase.Formato.qr_svg(String.duplicate("2@abcDEF123,xyz+/=", 8))
    [tag] = Regex.run(~r/<svg[^>]*>/, svg)
    assert tag =~ ~r/viewBox="0 0 \d+ \d+"/
    refute tag =~ ~r/\swidth="/
    refute tag =~ ~r/\sheight="/
    assert tag =~ ~s(class="qr")
  end
end
