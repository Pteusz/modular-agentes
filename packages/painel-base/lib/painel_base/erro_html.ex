defmodule PainelBase.ErroHTML do
  @moduledoc "Paginas de erro sem detalhes internos."
  def render("404.html", _), do: pagina("Página não encontrada.")
  def render("403.html", _), do: pagina("Pedido recusado. Volte e tente de novo.")
  def render(_, _), do: pagina("Algo deu errado. Tente de novo em instantes.")

  defp pagina(msg),
    do: ~s(<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>modular agentes</title><link rel="stylesheet" href="/assets/app.css"></head><body><main class="auth"><p class="aviso erro">#{msg}</p><p class="apoio"><a href="/">Voltar ao início</a></p></main></body></html>)
end
