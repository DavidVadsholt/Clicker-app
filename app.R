# DP-Next finger tapping: one practice + five 10-second spacebar runs.
# Install once: install.packages(c("shiny", "httr", "jsonlite"))
library(shiny)
library(httr)
library(jsonlite)

DURATION_MS <- 10000
REST_SECONDS <- 30L
N_RUNS <- 5L

# REDCap field names must match the existing project's data dictionary.
config <- function() list(
  url        = Sys.getenv("REDCAP_API_URL"),
  token      = Sys.getenv("REDCAP_API_TOKEN"),
  id         = Sys.getenv("REDCAP_ID_FIELD", "record_id"),
  instrument = Sys.getenv("REDCAP_INSTRUMENT", "finger_tapping"),
  event      = Sys.getenv("REDCAP_EVENT", ""),  # Set for longitudinal projects.
  count      = Sys.getenv("REDCAP_COUNT_FIELD", "ft_total_taps"),
  mean       = Sys.getenv("REDCAP_MEAN_FIELD", "ft_mean_interval_ms"),
  sd         = Sys.getenv("REDCAP_SD_FIELD", "ft_sd_interval_ms"),
  raw        = Sys.getenv("REDCAP_RAW_FIELD", "ft_raw_json"),
  discarded  = Sys.getenv("REDCAP_DISCARDED_FIELD", "ft_discarded_json")
)

# Summaries are calculated on the server, not trusted from the browser.
summarise_run <- function(timestamps) {
  t <- as.numeric(unlist(timestamps, use.names = FALSE))
  if (!length(t) || length(t) > 1000 || any(!is.finite(t)) ||
      t[1] != 0 || any(diff(t) <= 0) || any(t < 0 | t >= DURATION_MS)) {
    stop("Invalid timestamp sequence; discard and repeat this attempt.")
  }
  intervals <- diff(t)
  list(times = t, taps = length(t),
       mean = if (length(intervals)) mean(intervals) else NA_real_,
       sd = if (length(intervals) >= 2) sd(intervals) else NA_real_)
}

format_ms <- function(x) if (is.na(x)) "Not defined" else sprintf("%.2f ms", x)

redcap_post <- function(body, cfg) {
  response <- httr::POST(cfg$url, config = httr::timeout(30),
                         body = c(list(token = cfg$token), body), encode = "form")
  content <- httr::content(response, as = "text", encoding = "UTF-8")
  if (httr::http_error(response)) stop(paste("REDCap API error:", content))
  content
}

redcap_read <- function(record_id, cfg) {
  # Check that the record exists and whether these repeat instances already exist.
  body <- list(content = "record", format = "json", type = "flat",
               returnFormat = "json")
  body[["records[0]"]] <- record_id
  fields <- unique(c(cfg$id, cfg$count, cfg$mean, cfg$sd, cfg$raw, cfg$discarded))
  for (i in seq_along(fields)) {
    body[[paste0("fields[", i - 1, "]")]] <- fields[i]
  }
  jsonlite::fromJSON(redcap_post(body, cfg), simplifyVector = FALSE)
}

redcap_export <- function(record_id, runs, discards) {
  cfg <- config()
  if (!nzchar(cfg$url) || !nzchar(cfg$token)) {
    stop("REDCap connection is not configured on the Shiny server.")
  }
  existing <- redcap_read(record_id, cfg)
  matches_id <- function(row) identical(as.character(row[[cfg$id]]), record_id)
  if (!any(vapply(existing, matches_id, logical(1)))) {
    stop("This participant ID was not found in REDCap; nothing was imported.")
  }
  is_used_instance <- function(row) {
    if (is.null(row$redcap_repeat_instance)) return(FALSE)
    instance <- suppressWarnings(as.integer(row$redcap_repeat_instance))
    if (length(instance) != 1L || is.na(instance)) return(FALSE)
    same_form <- identical(as.character(row$redcap_repeat_instrument), cfg$instrument)
    same_event <- !nzchar(cfg$event) || identical(as.character(row$redcap_event_name), cfg$event)
    same_form && same_event && instance %in% seq_len(N_RUNS)
  }
  if (any(vapply(existing, is_used_instance, logical(1)))) {
    stop("Finger-tapping instances already exist in REDCap. Review them before retrying; no data were overwritten.")
  }

  records <- lapply(seq_len(N_RUNS), function(i) {
    x <- runs[[i]]
    raw <- list(protocol_version = "1.0", duration_ms = DURATION_MS,
                key = "Space", timestamps_ms = I(round(x$times, 3)),
                intervals_ms = I(round(diff(x$times), 3)))
    previous_discards <- Filter(function(d) identical(d$before_run, i) ||
                                           (i == 1L && identical(d$before_run, 0L)), discards)
    row <- list(redcap_repeat_instrument = cfg$instrument,
                redcap_repeat_instance = i)
    row[[cfg$id]] <- record_id
    if (nzchar(cfg$event)) row$redcap_event_name <- cfg$event
    row[[cfg$count]] <- x$taps
    row[[cfg$mean]] <- if (is.na(x$mean)) "" else round(x$mean, 3)
    row[[cfg$sd]] <- if (is.na(x$sd)) "" else round(x$sd, 3)
    row[[cfg$raw]] <- jsonlite::toJSON(raw, auto_unbox = TRUE, digits = 3)
    row[[cfg$discarded]] <- jsonlite::toJSON(previous_discards, auto_unbox = TRUE)
    row
  })

  # One API operation imports all five summaries AND their raw data.
  reply <- redcap_post(list(content = "record", action = "import",
                            format = "json", type = "flat", overwriteBehavior = "normal",
                            returnContent = "count", returnFormat = "json",
                            data = jsonlite::toJSON(records, auto_unbox = TRUE)), cfg)
  # REDCap may return either a numeric string or JSON such as {"count":5}.
  import_count <- suppressWarnings(as.integer(trimws(reply)))
  if (is.na(import_count)) {
    parsed <- tryCatch(jsonlite::fromJSON(reply), error = function(e) NULL)
    if (is.list(parsed) && !is.null(parsed$count))
      import_count <- suppressWarnings(as.integer(parsed$count))
  }
  if (length(import_count) != 1L || is.na(import_count) || import_count != N_RUNS)
    stop(paste("REDCap returned an unexpected import count:", reply,
               "Check REDCap before attempting another upload."))
  # Verify the saved count and raw data for every repeat instance.
  saved <- redcap_read(record_id, cfg)
  for (i in seq_len(N_RUNS)) {
    rows <- Filter(function(r) is_used_instance(r) &&
                     as.integer(r$redcap_repeat_instance) == i, saved)
    expected_raw <- records[[i]][[cfg$raw]]
    same_number <- function(actual, expected) {
      if (is.na(expected)) return(is.null(actual) || is.na(suppressWarnings(as.numeric(actual))))
      a <- suppressWarnings(as.numeric(actual))
      length(a) == 1L && is.finite(a) && abs(a - expected) < 0.00051
    }
    if (length(rows) != 1L ||
        !identical(as.character(rows[[1]][[cfg$count]]), as.character(runs[[i]]$taps)) ||
        !identical(as.character(rows[[1]][[cfg$raw]]), as.character(expected_raw)) ||
        !same_number(rows[[1]][[cfg$mean]], runs[[i]]$mean) ||
        !same_number(rows[[1]][[cfg$sd]], runs[[i]]$sd)) {
      stop("The import was sent, but verification was incomplete. Check REDCap before retrying.")
    }
  }
  invisible(TRUE)
}

# ----- Investigator interface -----
ui <- fluidPage(
  tags$head(
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    tags$style(HTML("
      body { background:#f5f7fa; color:#17324a; font-family:system-ui,-apple-system,Segoe UI,sans-serif; }
      .container-fluid { max-width:900px; padding:26px 18px 55px; margin:auto; }
      .masthead { margin-bottom:18px; }
      .eyebrow { color:#4d6c85; font-size:13px; font-weight:700; letter-spacing:.07em; text-transform:uppercase; }
      .masthead h1 { font-size:29px; font-weight:750; margin:8px 0; }
      .muted { color:#587087; }
      .workflow { display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin:24px 0 18px; }
      .workflow-step { background:#e7edf3; color:#536a7f; border-radius:9px; padding:11px 8px; text-align:center; font-size:12px; font-weight:650; }
      .workflow-step.current { background:#0d5876; color:white; }
      .workflow-step.past { background:#d9eee7; color:#176b54; }
      .sheet { background:white; border:1px solid #dbe4ec; border-radius:14px; box-shadow:0 3px 16px rgba(23,50,74,.04); padding:24px; margin-bottom:14px; }
      .sheet h2 { font-size:21px; margin:0 0 12px; font-weight:700; }
      .sheet h3 { font-size:19px; margin:0 0 11px; }
      .sheet p { line-height:1.55; }
      .id-grid { display:grid; grid-template-columns:1fr 1fr; gap:14px; }
      .btn { border-radius:8px; font-weight:650; padding:10px 17px; }
      .btn-primary { background:#0d5876; border-color:#0d5876; }
      .btn-primary:hover { background:#0a445e; }
      .btn-success { background:#176b54; border-color:#176b54; }
      .btn-default { border-color:#b9c8d4; }
      #tap_panel { border:2px solid #d2e0e8; background:#f8fbfd; border-radius:12px;
                   text-align:center; padding:26px 12px; margin-top:12px; }
      #tap_message { font-size:17px; font-weight:650; }
      #tap_clock { font-size:64px; font-weight:750; font-variant-numeric:tabular-nums; color:#0d5876; line-height:1.25; }
      #tap_count { font-size:17px; color:#536a7f; }
      .instruction { background:#eef6f9; border-left:4px solid #0d5876; padding:12px 15px; border-radius:4px; }
      .metrics { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; margin:14px 0; }
      .metric { border:1px solid #dce6ee; border-radius:10px; padding:13px; background:#fafcfd; }
      .metric-label { font-size:12px; color:#587087; }
      .metric-number { font-size:23px; font-weight:750; font-variant-numeric:tabular-nums; }
      .run-badges { display:flex; flex-wrap:wrap; gap:7px; margin:12px 0; }
      .run-badge { border:1px solid #cad8e2; color:#61788c; border-radius:99px; padding:5px 12px; font-size:12px; font-weight:600; }
      .run-badge.done { background:#e4f4ee; border-color:#b7ddcd; color:#176b54; }
      .warning-note { padding:11px 14px; background:#fff4e7; border:1px solid #f0d2a3; border-radius:8px; margin:12px 0; }
      .success-note { padding:11px 14px; background:#eaf5ef; border:1px solid #b7ddc7; border-radius:8px; margin:12px 0; }
      .rest-number { font-size:55px; font-weight:750; color:#0d5876; font-variant-numeric:tabular-nums; }
      .table { margin-bottom:0; }
      .small-note { font-size:12px; color:#60788d; margin-top:11px; }
      @media (max-width:600px) {
        .container-fluid {padding:14px 12px 40px;}
        .masthead h1 {font-size:24px;}
        .workflow-step {font-size:10px; padding:10px 3px;}
        .sheet {padding:17px;}
        .id-grid, .metrics {grid-template-columns:1fr;}
      }
    "))
  ),
  div(class = "masthead",
      div(class = "eyebrow", "DP-Next · investigator tool"),
      tags$h1("Finger-tapping assessment"),
      p(class = "muted", "Dominant index finger · spacebar · 10 seconds per run"),
      p(class = "small-note", span(id = "connection_state", "Shiny: connecting..."),
        " · ", span(id = "keyboard_state", "Keyboard: loading..."))),
  uiOutput("workflow"),
  div(class = "sheet", id = "participant_sheet",
      div(id = "participant_form",
          tags$h2("1. Identify participant"),
          p("Enter the existing REDCap record ID twice. Do not enter names or CPR numbers."),
          div(class = "id-grid",
              textInput("id_a", "Participant record ID"),
              textInput("id_b", "Confirm record ID")),
          actionButton("confirm_id", "Confirm participant ID", class = "btn-primary"),
          if (!nzchar(config()$url) || !nzchar(config()$token))
            p(class = "small-note", "Test mode: REDCap is not configured. A JSON backup will be available.")),
      div(id = "participant_confirmed", style = "display:none",
          tags$strong("Confirmed participant ID: "), span(id = "confirmed_id_value"))),
  div(class = "sheet", uiOutput("step_ui")),
  div(class = "sheet",
      tags$h2("Tapping timer"),
      div(id = "tap_panel", tabindex = "-1",
          div(id = "tap_message", "Confirm the participant ID to begin"),
          div(id = "tap_clock", "10.0 s"),
          div(id = "tap_count", "0 taps")),
      p(class = "small-note", "Only spacebar keypresses are recorded. Hold the hand still and lift only the index finger.")),
  div(class = "sheet",
      tags$h2("Accepted recordings"),
      uiOutput("run_badges"),
      tableOutput("summary_table")),
  tags$script(src = "tapping.js")
)

server <- function(input, output, session) {
  rv <- reactiveValues(
    phase = "identify", id = NULL, next_run = 0L,
    candidate = NULL, runs = list(), discards = list(),
    rest_until = NULL, exported = FALSE
  )

  run_label <- function() {
    if (rv$next_run == 0L) "Practice run" else
      paste("Recording", rv$next_run, "of", N_RUNS)
  }

  stage <- reactive({
    if (rv$phase == "identify") return(1L)
    if (rv$phase == "complete") return(4L)
    if (rv$next_run == 0L) 2L else 3L
  })

  output$workflow <- renderUI({
    steps <- c("1 · Participant", "2 · Practice", "3 · Five recordings", "4 · Save")
    div(class = "workflow", lapply(seq_along(steps), function(i) {
      div(class = paste("workflow-step", if (i == stage()) "current" else if (i < stage()) "past" else ""), steps[i])
    }))
  })

  output$run_badges <- renderUI({
    div(class = "run-badges", lapply(seq_len(N_RUNS), function(i) {
      div(class = paste("run-badge", if (i <= length(rv$runs)) "done" else ""),
          if (i <= length(rv$runs)) paste("✓ Run", i) else paste("Run", i))
    }))
  })

  rest_remaining <- reactive({
    if (rv$phase != "rest") return(NULL)
    invalidateLater(250, session)
    max(0L, ceiling(as.numeric(difftime(rv$rest_until, Sys.time(), units = "secs"))))
  })
  observe({
    if (rv$phase == "rest" && rest_remaining() == 0L) rv$phase <- "ready"
  })

  metric <- function(label, value) {
    div(class = "metric", div(class = "metric-label", label),
        div(class = "metric-number", value))
  }

  output$step_ui <- renderUI({
    if (rv$phase == "identify") return(NULL)
    switch(rv$phase,
      ready = tagList(
        tags$h2(run_label()),
        p(strong("Participant ID: "), rv$id),
        div(class = "instruction",
            "Sit at a desk with your dominant hand flat on the surface. ",
            "Lift only the index finger to tap the spacebar as many times as possible. ",
            "After pressing Begin, the first spacebar press starts the 10-second timer and counts as tap 1."),
        tags$div(style = "height:14px"),
        actionButton("begin_run", paste("Begin", tolower(run_label())), class = "btn-primary"),
        if (rv$next_run == 0L)
          p(class = "small-note", "The practice run is excluded from the five recorded measurements.")
      ),
      recording = tagList(
        tags$h2(run_label()),
        p("Press the spacebar to start, then continue tapping. Wait for the on-screen finish message."),
        p(class = "muted", "Do not change browser tabs or switch applications during the measurement.")
      ),
      review = {
        x <- rv$candidate
        tagList(
          tags$h2(paste("Review", tolower(run_label()))),
          div(class = "metrics",
              metric("Valid taps", x$taps),
              metric("Mean interval", format_ms(x$mean)),
              metric("Sample SD", format_ms(x$sd))),
          if (x$interrupted)
            div(class = "warning-note", strong("Interrupted measurement. "),
                "Discard and repeat this attempt."),
          if (x$taps < 3 && !x$interrupted)
            div(class = "warning-note", "With fewer than three taps, the sample SD is undefined. ",
                "The run can still be accepted if this reflects the participant's performance."),
          if (!x$interrupted)
            actionButton("accept_run", if (rv$next_run == 0L) "Accept practice run" else
                           paste("Accept recording", rv$next_run), class = "btn-success"),
          tags$hr(),
          textInput("discard_reason", "Reason for repeating this run (required)",
                    placeholder = "e.g. hand moved, interruption, wrong finger"),
          actionButton("discard_run", "Discard and repeat", class = "btn-default")
        )
      },
      rest = tagList(
        tags$h2("Rest period"),
        p("Keep the hand relaxed. The next run becomes available after the mandatory 30-second rest."),
        div(class = "rest-number", paste0(rest_remaining(), " s")),
        p(class = "muted", paste("Up next:", run_label()))
      ),
      complete = tagList(
        tags$h2("Five recordings completed"),
        p(strong("Participant ID: "), rv$id),
        p("Review the accepted measurements below. The practice run is not included."),
        if (rv$exported) div(class = "success-note", strong("Saved to REDCap and verified.")),
        if (!rv$exported && nzchar(config()$url) && nzchar(config()$token))
          actionButton("save_redcap", "Save all five recordings to REDCap", class = "btn-success"),
        if (!rv$exported && (!nzchar(config()$url) || !nzchar(config()$token)))
          div(class = "warning-note", "REDCap is not configured. Download a JSON backup; ",
              "upload will be available once server-side credentials are configured."),
        downloadButton("download_backup", "Download JSON backup", class = "btn-default"),
        if (rv$exported) tagList(tags$div(style = "height:12px"),
                                actionButton("next_participant", "Start next participant")),
        p(class = "small-note", "Do not close or refresh this page until the data have been saved and verified, or an approved backup has been secured.")
      )
    )
  })

  observeEvent(input$confirm_id, {
    if (rv$phase != "identify") return()
    a <- trimws(input$id_a)
    b <- trimws(input$id_b)
    if (!nzchar(a) || nchar(a) > 100 || a != b || grepl("[\\r\\n]", a)) {
      showNotification("Enter the same valid participant ID twice.", type = "error")
      return()
    }
    cfg <- config()
    if (nzchar(cfg$url) && nzchar(cfg$token)) {
      exists <- tryCatch({
        records <- redcap_read(a, cfg)
        any(vapply(records, function(r) identical(as.character(r[[cfg$id]]), a), logical(1)))
      }, error = function(e) {
        showNotification(paste("REDCap ID check failed:", conditionMessage(e)),
                         type = "error", duration = 12)
        FALSE
      })
      if (!exists) {
        showNotification("Participant ID not confirmed in REDCap.", type = "error")
        return()
      }
    }
    rv$id <- a
    rv$phase <- "ready"
    session$sendCustomMessage("participant_status", list(id = a))
  })

  observeEvent(input$begin_run, {
    if (rv$phase != "ready") return()
    rv$phase <- "recording"
    session$sendCustomMessage("arm_tapping", list(
      run_id = if (rv$next_run == 0L) "practice" else paste0("run_", rv$next_run)
    ))
  })

  observeEvent(input$tap_result, {
    if (rv$phase != "recording") return()
    response <- input$tap_result
    expected <- if (rv$next_run == 0L) "practice" else paste0("run_", rv$next_run)
    if (!identical(response$run_id, expected)) return()
    interrupted <- isTRUE(response$interrupted)
    x <- tryCatch(summarise_run(response$timestamps_ms), error = function(e) NULL)
    if (is.null(x)) {
      x <- list(times = numeric(), taps = 0L, mean = NA_real_, sd = NA_real_)
      interrupted <- TRUE
    }
    x$interrupted <- interrupted
    rv$candidate <- x
    rv$phase <- "review"
  })

  start_rest <- function() {
    rv$rest_until <- Sys.time() + REST_SECONDS
    rv$phase <- "rest"
  }

  observeEvent(input$accept_run, {
    if (rv$phase != "review" || rv$candidate$interrupted) return()
    if (rv$next_run > 0L) rv$runs[[rv$next_run]] <- rv$candidate
    rv$candidate <- NULL
    rv$next_run <- rv$next_run + 1L
    if (rv$next_run > N_RUNS) rv$phase <- "complete" else start_rest()
  })

  observeEvent(input$discard_run, {
    if (rv$phase != "review") return()
    reason <- trimws(input$discard_reason)
    if (!nzchar(reason)) {
      showNotification("A reason is required for discarded attempts.", type = "error")
      return()
    }
    rv$discards[[length(rv$discards) + 1L]] <- list(
      before_run = rv$next_run,
      reason = reason,
      timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      captured_taps = rv$candidate$taps
    )
    rv$candidate <- NULL
    start_rest()
  })

  output$summary_table <- renderTable({
    if (!length(rv$runs)) return(NULL)
    data.frame(
      Run = seq_along(rv$runs),
      Taps = vapply(rv$runs, function(r) r$taps, numeric(1)),
      `Mean interval (ms)` = vapply(rv$runs, function(r) round(r$mean, 2), numeric(1)),
      `Sample SD (ms)` = vapply(rv$runs, function(r) round(r$sd, 2), numeric(1)),
      check.names = FALSE
    )
  }, na = "—")

  output$download_backup <- downloadHandler(
    filename = function() paste0("finger_tapping_", gsub("[^A-Za-z0-9_-]", "_", rv$id), ".json"),
    content = function(file) {
      payload <- list(protocol_version = "1.0", record_id = rv$id,
                      duration_ms = DURATION_MS, runs = rv$runs,
                      discarded_attempts = rv$discards)
      writeLines(jsonlite::toJSON(payload, pretty = TRUE, auto_unbox = TRUE,
                                  na = "null", digits = 6), file, useBytes = TRUE)
    }
  )

  observeEvent(input$save_redcap, {
    if (rv$phase != "complete" || rv$exported || length(rv$runs) != N_RUNS) return()
    tryCatch({
      withProgress({
        redcap_export(rv$id, rv$runs, rv$discards)
      }, message = "Saving five recordings to REDCap...", value = 0.5)
      rv$exported <- TRUE
      showNotification("Saved and verified in REDCap.", type = "message", duration = 8)
    }, error = function(e) {
      showNotification(conditionMessage(e), type = "error", duration = NULL)
    })
  })

  observeEvent(input$next_participant, {
    if (rv$phase != "complete" || !rv$exported) return()
    rv$phase <- "identify"
    rv$id <- NULL
    rv$next_run <- 0L
    rv$candidate <- NULL
    rv$runs <- list()
    rv$discards <- list()
    rv$rest_until <- NULL
    rv$exported <- FALSE
    session$sendCustomMessage("participant_status", list(id = ""))
    session$sendCustomMessage("reset_tapping", list())
  })
}

shinyApp(ui, server)
