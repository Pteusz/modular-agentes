# Teste geral da etapa 0 (canal). Rodar: source env.sh && elixir test/etapa0_test.exs
ExUnit.start()

defmodule Etapa0Test do
  use ExUnit.Case
  @root Path.expand("..", __DIR__)

  test "canal decidido, versao fixada, sem segredo/sessao no repo, docs nos limites" do
    estado = File.read!(Path.join(@root, "docs/estado.md"))
    assert length(String.split(estado, "\n", trim: true)) <= 30
    assert estado =~ "Decisao do canal"
    assert estado =~ "ESTIMATIVA 50 tenants"

    assert File.read!(Path.join(@root, "spike/amarula/mix.exs")) =~ ~s({:amarula, "== 0.5.10"})
    assert File.exists?(Path.join(@root, "spike/amarula/mix.lock"))
    assert length(String.split(File.read!(Path.join(@root, "CLAUDE.md")), "\n")) <= 16

    gi = File.read!(Path.join(@root, ".gitignore"))
    for p <- [".env", "*.session", "sessions/", ".tools/"], do: assert(gi =~ p)

    {files, 0} = System.cmd("git", ["ls-files"], cd: @root)
    refute files =~ ~r/\.etf$|\.session$|(^|\n)\.env|creds/
  end
end
