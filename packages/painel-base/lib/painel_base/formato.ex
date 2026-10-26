defmodule PainelBase.Formato do
  @moduledoc "Formatacao para tela (pt-BR). Estado nunca so por cor: sempre rotulo em texto + simbolo."

  @doc "Centavos -> \"R$ 1.234,56\"."
  def brl(c) when is_integer(c) do
    sinal = if c < 0, do: "-", else: ""
    c = abs(c)
    "R$ #{sinal}#{numero(div(c, 100))},#{c |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  def brl(_), do: "—"

  @doc "12000 -> \"12.000\"."
  def numero(n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1.") |> String.reverse()
  end

  def numero(_), do: "—"

  @doc "{rotulo, simbolo} do status da campanha (a plataforma simulada diz PAUSADA, a Meta PAUSED)."
  def status(s) do
    case s |> to_string() |> String.upcase() do
      x when x in ["PAUSADA", "PAUSED"] -> {"Pausada", "❚❚"}
      x when x in ["ATIVA", "ACTIVE"] -> {"Ativa", "▶"}
      x when x in ["ARQUIVADA", "ARCHIVED", "DELETED"] -> {"Arquivada", "■"}
      "" -> {"Sem status", "?"}
      outro -> {String.capitalize(String.downcase(outro)), "•"}
    end
  end

  @doc "Estado do canal (WhatsApp) -> {rotulo, simbolo}."
  def canal(:sem_sessao), do: {"Sem sessão", "○"}
  def canal(:conectando), do: {"Conectando…", "◌"}
  def canal({:qr, _}), do: {"Aguardando leitura do QR", "▣"}
  def canal(:conectado), do: {"Conectado", "✓"}
  def canal(:precisa_parear), do: {"Precisa parear de novo", "!"}
  def canal(_), do: {"Desconectado", "✕"}

  @doc "SVG do QR a partir do texto que o canal publicou (a classe `qr` marca so este desenho)."
  def qr_svg(texto) when is_binary(texto) do
    case QRCode.create(texto, :medium) |> QRCode.render(:svg) do
      {:ok, svg} -> {:ok, com_viewbox(svg)}
      _ -> :erro
    end
  end

  # O SVG do gerador vem com width/height fixos e sem viewBox: sem viewBox o CSS (largura maxima) recorta o desenho em vez de encolher.
  defp com_viewbox(svg) do
    caixa =
      case Regex.run(~r/<svg[^>]*\swidth="(\d+)"[^>]*\sheight="(\d+)"/, svg) do
        [_, l, a] -> ~s(viewBox="0 0 #{l} #{a}" )
        _ -> ""
      end

    svg
    |> String.replace(~r/(<svg[^>]*?)\swidth="\d+"/, "\\1", global: false)
    |> String.replace(~r/(<svg[^>]*?)\sheight="\d+"/, "\\1", global: false)
    |> String.replace("<svg ", ~s(<svg class="qr" role="img" aria-label="QR para parear o WhatsApp" #{caixa}), global: false)
  end
end
