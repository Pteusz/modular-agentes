defmodule PainelBase.AuthHTML do
  use Phoenix.Component
  import PainelBase.Layouts, only: [csrf: 1]

  attr :erro, :string, default: nil

  def aviso(assigns) do
    ~H"""
    <p :if={@erro} class="aviso erro" role="alert"><span class="simbolo" aria-hidden="true">✕</span> {@erro}</p>
    """
  end

  def entrar(assigns) do
    ~H"""
    <h1>Entrar</h1>
    <.aviso erro={@erro} />
    <form method="post" action="/entrar" class="formulario">
      <.csrf />
      <label for="email">E-mail</label>
      <input id="email" type="email" name="email" value={@email} autocomplete="username" required />
      <label for="senha">Senha</label>
      <input id="senha" type="password" name="senha" autocomplete="current-password" required />
      <button type="submit" class="botao">Entrar</button>
    </form>
    <p class="apoio"><a href="/recuperar">Esqueci a senha</a></p>
    """
  end

  def convite(assigns), do: formulario_senha(Map.merge(assigns, %{titulo: "Definir senha", acao: "/convite/#{assigns.token}", botao: "Definir senha"}))
  def redefinir(assigns), do: formulario_senha(Map.merge(assigns, %{titulo: "Nova senha", acao: "/redefinir/#{assigns.token}", botao: "Salvar nova senha"}))

  defp formulario_senha(assigns) do
    ~H"""
    <h1>{@titulo}</h1>
    <p class="apoio">Use pelo menos 10 caracteres. Uma frase longa é melhor que uma senha curta e cheia de símbolos.</p>
    <.aviso erro={@erro} />
    <form method="post" action={@acao} class="formulario">
      <.csrf />
      <label for="senha">Senha</label>
      <input id="senha" type="password" name="senha" autocomplete="new-password" minlength="10" required />
      <label for="senha_confirmacao">Repita a senha</label>
      <input id="senha_confirmacao" type="password" name="senha_confirmacao" autocomplete="new-password" minlength="10" required />
      <button type="submit" class="botao">{@botao}</button>
    </form>
    """
  end

  def verificar(assigns) do
    ~H"""
    <h1>Confirmar e-mail</h1>
    <p class="apoio">Confirme que este endereço é seu para poder entrar.</p>
    <form method="post" action={"/verificar/#{@token}"} class="formulario">
      <.csrf />
      <button type="submit" class="botao">Confirmar e-mail</button>
    </form>
    """
  end

  def recuperar(%{enviado: true} = assigns) do
    ~H"""
    <h1>Recuperar senha</h1>
    <p class="aviso ok" role="status"><span class="simbolo" aria-hidden="true">✓</span> Se o e-mail existir, enviamos um link para redefinir a senha. O link vale por 1 hora.</p>
    <p class="apoio"><a href="/entrar">Voltar para entrar</a></p>
    """
  end

  def recuperar(assigns) do
    ~H"""
    <h1>Recuperar senha</h1>
    <p class="apoio">Informe o e-mail do seu acesso. Se ele existir, você recebe um link para escolher uma nova senha.</p>
    <form method="post" action="/recuperar" class="formulario">
      <.csrf />
      <label for="email">E-mail</label>
      <input id="email" type="email" name="email" autocomplete="username" required />
      <button type="submit" class="botao">Enviar link</button>
    </form>
    <p class="apoio"><a href="/entrar">Voltar para entrar</a></p>
    """
  end

  def invalido(assigns) do
    ~H"""
    <h1>Link indisponível</h1>
    <p class="aviso erro" role="alert"><span class="simbolo" aria-hidden="true">✕</span> Este link é inválido ou já usado. Peça um novo convite ou use "Esqueci a senha".</p>
    <p class="apoio"><a href="/entrar">Ir para entrar</a></p>
    """
  end
end
