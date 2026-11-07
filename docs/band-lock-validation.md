# Quectel band-list validation

Quectel QNWPREFCFG band setters require a non-empty list. An empty list is not
an unlock request: it produces a trailing comma with no value. The backend now
rejects malformed/empty input before invoking the AT transport and reports a
structured `result.success` / `result.error`, preserving `result.set_lockband`
for the raw acknowledgement or modem error.

Each Quectel band class advertises `allow_empty: false`. Both LuCI interfaces
use that capability instead of imposing Quectel semantics on other vendors
(such as Neoway, whose empty-list operation resets bands). Legacy Quectel LTE
`Lte` class names remain accepted. Unsupported model-specific positive band IDs
are still decided by the modem; the patch does not invent a universal band list.

## Automated regression checks

```sh
python3 tests/test_quectel_band_lock.py -v
node tests/test_band_lock_ui.js
sh application/qmodem/tests/test_vendor_cmds_boundary.sh
sh application/qmodem/tests/test_core_cmds.sh
bash application/qmodem/tests/test_vendor_fixtures.sh
```

The backend tests use the production vendor and command-wrapper functions with
a fake AT transport. The frontend tests execute production legacy class and
next-generation apply handlers, checking empty-list suppression, error display,
success handling, and preservation of other vendors' reset behavior. They do
not replace browser-rendering or radio-registration tests.

## Hardware verification (2026-11-07)

Tested on an Arcadyan AW1000 running NoobWRT / OpenWrt 25.12.5, Linux 6.12.94,
with a Quectel modem using the shared AT daemon. Its jq is built without
Oniguruma, so input validation deliberately uses portable shell/grep rather
than jq regex functions.

- Backed up original vendor/UI files and configuration off-router first.
- Confirmed empty input is rejected under the router's BusyBox shell with a
  transport trap, then through both installed modem_ctrl and ubus qmodem RPC.
- Queried the modem's current SA list and reapplied that same list through RPC;
  the modem returned OK and the backend reported success.
- Verified LTE, SA, NSA and network-mode query results were unchanged and the
  modem remained attached. No reflash, reboot or UCI configuration change.

The error/timeout cases use simulated responses, not deliberately disruptive
radio settings. This patch does not claim to resolve intermittent signal/status
reporting or establish why any particular user lost connectivity.
