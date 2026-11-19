/* DP-Next: capture spacebar tap times. Shiny manages the research workflow. */
(() => {
  "use strict";
  const DURATION_MS = 10000;
  let armedRun = null;
  let startedAt = null;
  let times = [];
  let keyDown = false;
  let tickTimer = null;
  let endTimer = null;
  let registered = false;

  const el = (id) => document.getElementById(id);
  const show = (id, text) => { if (el(id)) el(id).textContent = text; };

  function clearTimers() {
    clearInterval(tickTimer);
    clearTimeout(endTimer);
    tickTimer = null;
    endTimer = null;
  }

  function finish(interrupted = false) {
    if (armedRun === null) return;
    const runId = armedRun;
    armedRun = null;
    clearTimers();
    show("tap_message", interrupted ? "Interrupted: discard and repeat" : "Run completed");
    show("tap_clock", "0.0 s");
    if (window.Shiny && Shiny.setInputValue) {
      Shiny.setInputValue("tap_result", {
        run_id: runId,
        timestamps_ms: times.slice(),
        interrupted: interrupted
      }, {priority: "event"});
    }
  }

  function updateClock() {
    if (armedRun === null || startedAt === null) return;
    const elapsed = performance.now() - startedAt;
    show("tap_clock", (Math.max(0, DURATION_MS - elapsed) / 1000).toFixed(1) + " s");
    if (elapsed >= DURATION_MS) finish(false);
  }

  document.addEventListener("keydown", (event) => {
    if (event.code !== "Space" || armedRun === null) return;
    event.preventDefault();
    if (event.repeat || keyDown || event.isComposing) return;
    keyDown = true;
    const now = performance.now();
    if (startedAt === null) {
      startedAt = now;
      times = [0]; // First keypress starts the timer and counts as tap 1.
      show("tap_message", "Keep tapping");
      tickTimer = setInterval(updateClock, 50); // For display only.
      endTimer = setTimeout(() => finish(false), DURATION_MS + 30);
    } else {
      const elapsed = now - startedAt;
      if (elapsed >= DURATION_MS) { finish(false); return; }
      times.push(elapsed);
    }
    show("tap_count", times.length + (times.length === 1 ? " tap" : " taps"));
  });

  document.addEventListener("keyup", (event) => {
    if (event.code === "Space") keyDown = false;
  });

  // A recording is invalidated if the page loses focus.
  const interrupt = () => {
    keyDown = false;
    if (armedRun !== null && startedAt !== null) finish(true);
  };
  window.addEventListener("blur", interrupt);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) interrupt();
  });

  function registerHandlers() {
    if (registered || !window.Shiny || !Shiny.addCustomMessageHandler) return;
    registered = true;
    show("keyboard_state", "Keyboard: ready");

    Shiny.addCustomMessageHandler("arm_tapping", ({run_id}) => {
      clearTimers();
      armedRun = run_id;
      startedAt = null;
      times = [];
      keyDown = false;
      show("tap_message", "Press SPACE to start");
      show("tap_clock", "10.0 s");
      show("tap_count", "0 taps");
      requestAnimationFrame(() => { if (el("tap_panel")) el("tap_panel").focus(); });
    });

    Shiny.addCustomMessageHandler("reset_tapping", () => {
      clearTimers();
      armedRun = null;
      startedAt = null;
      times = [];
      keyDown = false;
      show("tap_message", "Confirm the participant ID to begin");
      show("tap_clock", "10.0 s");
      show("tap_count", "0 taps");
    });

    Shiny.addCustomMessageHandler("participant_status", ({id}) => {
      const hasId = !!id;
      if (el("participant_form")) el("participant_form").style.display = hasId ? "none" : "";
      if (el("participant_confirmed")) el("participant_confirmed").style.display = hasId ? "" : "none";
      show("confirmed_id_value", id || "");
      if (!hasId) {
        if (el("id_a")) el("id_a").value = "";
        if (el("id_b")) el("id_b").value = "";
      }
    });
  }

  // Register immediately when available, also retry on connection and page load.
  registerHandlers();
  window.addEventListener("load", registerHandlers);
  if (window.jQuery) {
    jQuery(document).on("shiny:connected", () => {
      show("connection_state", "Shiny: connected");
      registerHandlers();
    });
    jQuery(document).on("shiny:disconnected", () => {
      show("connection_state", "Shiny: disconnected — reload the app");
      if (armedRun !== null) finish(true);
    });
  } else {
    show("connection_state", "Shiny: waiting for scripts");
  }
})();
