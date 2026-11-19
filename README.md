# DP-Next finger-tapping assessment – Shiny prototype (v3)

Minimal investigator-facing Shiny application. It is independent of the original click-speed/bot-detection application.

## Investigator workflow

1. Enter the participant's **existing REDCap record ID twice** and confirm it.
2. Explain the protocol: participant seated at a desk; dominant hand flat on the desk; use only the index finger to tap the **spacebar**. Maintain the hand position.
3. Click **Begin practice run**. The participant's **first spacebar keypress starts the 10-second timer and is counted as tap 1**.
4. Review the practice result. **Accept**, or **discard and repeat** after entering a reason. Practice measurements are not exported as study outcomes.
5. Wait for the enforced **30-second rest**. Run five recorded trials in the same way; after each trial, review and accept or discard with a reason. A discarded attempt is repeated and does **not** count among the five.
6. Review the results table, then click **Save all five recordings to REDCap**. The app writes the five repeating instances and reads them back to check they were stored. After successful verification, select **Start next participant**.
7. A **Download JSON backup** button is available when the five recordings are complete. Follow institutional policy before storing any research data locally.

**Important:** If REDCap API settings are missing, the application works in local test mode (including a JSON backup), but direct upload is unavailable.

## Outcomes (one row per accepted run)

| REDCap field | Recommended type | Content |
| --- | --- | --- |
| `ft_total_taps` | Text with integer validation | Number of valid spacebar keypresses during the 10-second run |
| `ft_mean_interval_ms` | Text with number validation (decimal) | Mean of successive inter-tap intervals in milliseconds |
| `ft_sd_interval_ms` | Text with number validation (decimal) | **Sample** SD of the successive intervals, in milliseconds |
| `ft_raw_json` | Notes (long text) | Per-tap elapsed timestamps and inter-tap intervals, in milliseconds, as JSON |
| `ft_discarded_json` | Notes (long text) | Recorded reasons for discarded attempts and limited metadata |

Configure the instrument's **unique name** as `finger_tapping` and enable **repeating instrument**. The existing record ID identifies each participant. Repeating instance numbers **1–5** correspond to the five accepted runs. The practice run is not exported as an outcome. Its discarded attempts, if any, are stored with run 1's `ft_discarded_json`.

The mean and sample SD are calculated on the **Shiny server** from successive timestamps: `diff(timestamps)`, `mean(intervals)` and `sd(intervals)` in R. Sample SD is not defined when fewer than **three** taps are recorded; this is saved as missing, not as zero.

A typical `ft_raw_json` value (illustrative):

```json
{"protocol_version":"1.0","duration_ms":10000,"key":"Space","timestamps_ms":[0,180,375,565],"intervals_ms":[180,195,190]}
```

All recorded timestamps are measured **relative to the first keypress**. Values are stored to 3 decimal places (milliseconds). All taps satisfy `0 <= t < 10000`; a keypress at the end boundary is excluded. Holding the key down does not count as repeated tapping.

## Files

- `app.R` – Shiny user interface, research workflow, server calculations, and REDCap API communication.
- `www/tapping.js` – keyboard input and high-resolution event timestamps. No mouse or bot detector code.

No Chart.js, database package, or additional front-end framework is required.

## Local setup

1. Install R and the required packages once:

   ```r
   install.packages(c("shiny", "httr", "jsonlite"))
   ```

2. In R or RStudio, run the application:

   ```r
   shiny::runApp("path/to/dpnext_finger_tapping_shiny")
   ```

   Alternatively, open `app.R` in RStudio and select **Run App**.

3. Without API credentials, the app clearly indicates **local test mode**. Use a synthetic participant ID for demonstration, and export a JSON backup for inspection. Do not enter real participant data into unapproved local environments.

## REDCap API configuration

Set the following **environment variables on the Shiny server**, not in repository files:

| Variable | Default / meaning |
| --- | --- |
| `REDCAP_API_URL` | Required. Official REDCap API endpoint |
| `REDCAP_API_TOKEN` | Required. Token with API export and import/update permissions |
| `REDCAP_ID_FIELD` | `record_id` |
| `REDCAP_INSTRUMENT` | `finger_tapping` |
| `REDCAP_EVENT` | Leave empty for classic projects; set to the correct **unique event name** in longitudinal projects |
| `REDCAP_COUNT_FIELD` | `ft_total_taps` |
| `REDCAP_MEAN_FIELD` | `ft_mean_interval_ms` |
| `REDCAP_SD_FIELD` | `ft_sd_interval_ms` |
| `REDCAP_RAW_FIELD` | `ft_raw_json` |
| `REDCAP_DISCARDED_FIELD` | `ft_discarded_json` |

The app first confirms the record exists (when API settings are available), prevents automatic overwriting of existing target instances 1–5, sends all five accepted runs in one API import call, and reads back the stored fields for verification.

A failed or timed-out API request may have **actually imported data**. The app does not silently retry or overwrite. **Check REDCap before attempting another upload**. Use the JSON backup if manual reconciliation is needed.

## Testing and limitations

This is a **development prototype, not yet validated for collection of participant research data**.

- Keyboard handling has been tested with simulated JavaScript events: first tap, separate presses, key auto-repeat, strict 10-second cutoff, interruption, and reset.
- The complete R/Shiny interface has **not** been executed in the authoring environment (R unavailable), and the REDCap API has **not** been tested against the DP-Next project.
- Complete end-to-end testing is required with a dedicated test REDCap project/record, including five repeats, rejected attempts, missing SD, read-back verification, and API error/timeout recovery.
- A browser event timestamp is not the actual physical time at which the finger contacts the key. Keyboard and OS event latency can affect intervals. Keep keyboard, browser, OS, and workstation consistent and validate with a physical timing reference if precise interval measurement is scientifically important.
- After a page refresh or a lost Shiny session, unsaved records held in memory are lost. Use a managed, access-controlled deployment and an approved recovery/backup workflow. The downloadable JSON is not a replacement for secure server-side persistence.
- Verify use with DP-Next's information security, research governance and data-management requirements. The public GitHub repository must not contain participant data, REDCap tokens, or credentials.


## Version 3 troubleshooting (participant ID / spacebar)

Version 3 uses **permanent participant ID fields** rather than generating those inputs
inside an R `renderUI` output, and registers keyboard message handlers whether
or not the `shiny:connected` event has already fired. The source `tapping.js` is
loaded **after** the app markup and Shiny dependencies.

To run it, extract the entire folder (including the `www` subfolder) and use:

```r
install.packages(c("shiny", "httr", "jsonlite")) # only once
shiny::runApp("path/to/DPNext_finger_tapping_Shiny_v3", launch.browser = TRUE)
```

In the opened **browser** (not a static preview), the top of the page should say
`Shiny: connected` and `Keyboard: ready`. If either is absent, the app is not
connected properly: inspect the R console and the browser developer console
(F12) for errors. Please report those messages if problems continue.

**Use test IDs only** until REDCap configuration, hosting, and end-to-end
validation are approved. The app has not been executed against a live Shiny
server or REDCap in the authoring environment.
