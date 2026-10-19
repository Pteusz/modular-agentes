// Liga o LiveView (phoenix.min.js e phoenix_live_view.min.js, servidos localmente).
(function () {
  var meta = document.querySelector("meta[name='csrf-token']");
  var token = meta ? meta.getAttribute("content") : "";
  var live = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, { params: { _csrf_token: token } });
  live.connect();
  window.liveSocket = live;
})();

// Menu do usuario (details): fecha ao clicar fora, com Esc ou ao escolher um item.
(function () {
  function fechar(menu) { if (menu) menu.removeAttribute("open"); }
  document.addEventListener("click", function (e) {
    document.querySelectorAll("details.menu-usuario[open]").forEach(function (m) {
      if (!m.contains(e.target) || e.target.closest("a")) fechar(m);
    });
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") document.querySelectorAll("details.menu-usuario[open]").forEach(fechar);
  });
})();
