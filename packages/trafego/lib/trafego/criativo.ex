defmodule Trafego.Criativo do
  @moduledoc """
  Conferencia DECIDIVEL do criativo (sem IA): formato (png, jpeg, mp4), proporcao e resolucao lidos dos proprios bytes.
  Regras em config :criativo (min_lado, proporcao_min/max como {num, den}, max_bytes).
  `conferir/1` -> {:ok, %{formato, largura, altura, bytes}} | {:error, [motivo]}.
  """
  alias Trafego.Config

  def conferir(bytes) when is_binary(bytes) do
    case dimensoes(bytes) do
      {:ok, formato, w, h} -> regras(formato, w, h, byte_size(bytes))
      {:error, m} -> {:error, [m]}
    end
  end

  def conferir(_), do: {:error, [:arquivo_ilegivel]}

  @doc "Texto para o corretor."
  def explicar(motivos), do: motivos |> Enum.map(&texto/1) |> Enum.join("; ")

  defp texto(:resolucao_baixa), do: "resolucao baixa (o menor lado precisa ter ao menos #{Config.criativo(:min_lado, 600)} px)"
  defp texto(:proporcao_fora_do_aceito), do: "proporcao fora do aceito (entre 9:16 e 1,91:1)"
  defp texto(:arquivo_grande), do: "arquivo grande demais"
  defp texto(:formato_nao_suportado), do: "formato nao suportado (use png, jpg ou mp4)"
  defp texto(:arquivo_ilegivel), do: "arquivo ilegivel ou corrompido"

  defp regras(formato, w, h, tam) do
    {pmin_n, pmin_d} = Config.criativo(:proporcao_min, {9, 16})
    {pmax_n, pmax_d} = Config.criativo(:proporcao_max, {191, 100})

    motivos =
      (if min(w, h) < Config.criativo(:min_lado, 600), do: [:resolucao_baixa], else: []) ++
        (if w * pmin_d >= h * pmin_n and w * pmax_d <= h * pmax_n, do: [], else: [:proporcao_fora_do_aceito]) ++
        (if tam > Config.criativo(:max_bytes, 30_000_000), do: [:arquivo_grande], else: [])

    if motivos == [], do: {:ok, %{formato: formato, largura: w, altura: h, bytes: tam}}, else: {:error, motivos}
  end

  # ---- leitura dos cabecalhos
  defp dimensoes(<<137, 80, 78, 71, 13, 10, 26, 10, resto::binary>>) do
    case resto do
      <<_::32, "IHDR", w::32, h::32, _::binary>> when w > 0 and h > 0 -> {:ok, "png", w, h}
      _ -> {:error, :arquivo_ilegivel}
    end
  end

  defp dimensoes(<<0xFF, 0xD8, resto::binary>>) do
    case jpeg(resto) do
      {w, h} when w > 0 and h > 0 -> {:ok, "jpeg", w, h}
      _ -> {:error, :arquivo_ilegivel}
    end
  end

  defp dimensoes(<<_::32, "ftyp", _::binary>> = b) do
    case mp4(b) do
      {w, h} -> {:ok, "mp4", w, h}
      nil -> {:error, :arquivo_ilegivel}
    end
  end

  defp dimensoes(_), do: {:error, :formato_nao_suportado}

  # JPEG: caminha pelos segmentos ate achar um SOFn (C0-CF exceto C4, C8, CC)
  defp jpeg(<<0xFF, 0xFF, r::binary>>), do: jpeg(<<0xFF, r::binary>>)
  defp jpeg(<<0xFF, m, _len::16, _p, h::16, w::16, _::binary>>) when m in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF], do: {w, h}
  defp jpeg(<<0xFF, m, r::binary>>) when m in 0xD0..0xD7 or m in [0x01, 0xD8], do: jpeg(r)

  defp jpeg(<<0xFF, m, len::16, r::binary>>) when m != 0xD9 and m != 0xDA and len >= 2 do
    case r do
      <<_::binary-size(len - 2), prox::binary>> -> jpeg(prox)
      _ -> nil
    end
  end

  defp jpeg(_), do: nil

  # MP4: caixas moov > trak > tkhd (largura/altura em 16.16); a primeira trilha com area e a de video
  defp mp4(b), do: b |> caixas() |> achar_tkhd()

  defp caixas(<<tam::32, tipo::binary-size(4), r::binary>>) when tam >= 8 do
    n = tam - 8

    case r do
      <<corpo::binary-size(n), prox::binary>> -> [{tipo, corpo} | caixas(prox)]
      _ -> []
    end
  end

  defp caixas(_), do: []

  defp achar_tkhd(cx) do
    Enum.find_value(cx, fn
      {"moov", c} -> c |> caixas() |> achar_tkhd()
      {"trak", c} -> c |> caixas() |> achar_tkhd()
      {"tkhd", c} -> tkhd(c)
      _ -> nil
    end)
  end

  defp tkhd(<<0, _::24, _::32, _::32, _::32, _::32, _::32, _::64, _::64, _::288, w::16, _::16, h::16, _::16, _::binary>>) when w > 0 and h > 0, do: {w, h}
  defp tkhd(<<1, _::24, _::64, _::64, _::32, _::32, _::64, _::64, _::64, _::288, w::16, _::16, h::16, _::16, _::binary>>) when w > 0 and h > 0, do: {w, h}
  defp tkhd(_), do: nil
end
