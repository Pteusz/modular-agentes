// Liga o LiveView (phoenix.min.js e phoenix_live_view.min.js, servidos localmente).
(function () {
  var meta = document.querySelector("meta[name='csrf-token']");
  var token = meta ? meta.getAttribute("content") : "";
  var live = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, { params: { _csrf_token: token } });
  live.connect();
  window.liveSocket = live;
})();
