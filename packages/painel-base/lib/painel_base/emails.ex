defmodule PainelBase.Emails do
  @moduledoc "Textos dos e-mails (texto puro). O link leva o token em claro; o banco so guarda o hash."
  import Swoosh.Email
  alias PainelBase.{Config, Mailer}

  def convite(usuario, token),
    do:
      montar(usuario, "Seu acesso ao modular agentes", """
      Olá, #{usuario.nome}.

      Você foi convidado para o painel do modular agentes. Para definir sua senha e entrar, abra o link (vale por 7 dias, uso único):

      #{Config.url_base()}/convite/#{token}

      Se você não esperava este convite, ignore esta mensagem.
      """)

  def verificacao(usuario, token),
    do:
      montar(usuario, "Confirme seu e-mail", """
      Olá, #{usuario.nome}.

      Para confirmar seu e-mail, abra o link (vale por 2 dias, uso único):

      #{Config.url_base()}/verificar/#{token}
      """)

  def recuperacao(usuario, token),
    do:
      montar(usuario, "Redefinir sua senha", """
      Olá, #{usuario.nome}.

      Recebemos um pedido para redefinir sua senha. Abra o link para escolher uma nova (vale por 1 hora, uso único):

      #{Config.url_base()}/redefinir/#{token}

      Se não foi você, ignore esta mensagem: sua senha atual continua valendo.
      """)

  def teste(destino),
    do:
      new()
      |> to(destino)
      |> from({"modular agentes", Mailer.remetente() || "painel@localhost"})
      |> subject("Teste de e-mail do painel")
      |> text_body("Se você recebeu esta mensagem, o envio de e-mail do painel está funcionando.\n")

  defp montar(usuario, assunto, corpo),
    do:
      new()
      |> to({usuario.nome, usuario.email})
      |> from({"modular agentes", Mailer.remetente() || "painel@localhost"})
      |> subject(assunto)
      |> text_body(corpo)
end
