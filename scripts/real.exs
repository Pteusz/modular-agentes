# Demo etapa 1: tenant "mateus" no canal real (Amarula) + tenant "sim" no canal simulado.
# Uso: set -a; source /opt/modular-agentes-data/db.env; set +a; mix run scripts/real.exs SEGUNDOS
alias Nucleo.{Registro, Vincular, Laco, Manifesto, Canal}
secs = String.to_integer(List.first(System.argv()) || "90")
Logger.configure(level: :info)
Registro.migrar!()
{:ok, _} = Vincular.vincular("mateus", "esqueleto", "0.1.0", Canal.Amarula)
{:ok, _} = Vincular.vincular("sim", "esqueleto", "0.1.0", Canal.Simulado)
{:ok, _} = Laco.iniciar("mateus")
{:ok, ls} = Laco.iniciar("sim")
sim = Laco.canal(ls)
Canal.Simulado.injetar(sim, :proprio, "oi")
IO.inspect(Manifesto.gerar(), label: "manifesto")
IO.puts("Mande uma mensagem no seu chat consigo mesmo (WhatsApp) nos proximos #{secs}s.")
Process.sleep(secs * 1000)
IO.inspect(Canal.Simulado.enviadas(sim), label: "sim enviadas")
for t <- ["mateus", "sim"], do: IO.inspect(Enum.map(Registro.eventos(t), & &1.tipo), label: "eventos #{t}")
IO.inspect(Registro.ler("mateus", "contador"), label: "contador mateus")
