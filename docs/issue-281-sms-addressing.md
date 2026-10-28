# Issue #281: configurable SMS country calling codes

The SMS compose dialog and conversation reply form provide an optional country
calling code and show the actual destination before sending. The legacy Lua SMS
page offers the same control. Each modem has its own `sms_country_code` option in
`/etc/config/qmodem`. Its default is empty; no country is preselected or inferred
from browser language, SIM, operator or number length.

Typing a code changes the current send only. **Save for this modem** explicitly
persists the value. Saving an empty value clears it. Accept either digits or a
leading `+`, for example `1`, `44`, `49`, `86` or `91`. A code must contain one to
three digits and cannot start with zero. Switching modems reloads that modem's
setting and ignores late responses from an earlier selection.

| Phone number | Country code | Actual destination |
| --- | --- | --- |
| `2025550123` | empty | `2025550123` |
| `2025550123` | `1` | `+12025550123` |
| `7911123456` | `44` | `+447911123456` |
| `+447911123456` | `1` | `+447911123456` |
| `12345` | empty | `12345` |

A complete `+` number takes precedence over the code. For short/service numbers,
clear the code. No domestic trunk prefix is removed automatically: when adding a
country code, enter the national significant number without the domestic dialing
prefix. `00` is not automatically converted to `+`. Spaces, tabs, parentheses and
hyphens are accepted as number formatting. International numbers are limited to
15 digits; local/service addresses to the SMS address field's 20 digits.

## Encoding and backend behavior

- `main`: `qmodem.sms.configure`/`config_get` save/read `country_code`. Sending
  resolves the configured code unless a per-call `country_code` is supplied;
  an explicit empty string bypasses the saved code. The C encoder strips `+`
  only after selecting international type of address `0x91`. Bare digits use
  unknown type `0x81`, including long local numbers and short service numbers.
- `stable`: `qmodem_sms.get_country_code`/`set_country_code` save/read the same
  option. `send_sms` validates and rebuilds the PDU destination from the resolved
  recipient, preserving the message body and multipart header. Both JavaScript
  PDU encoders support `+` and the corresponding address type.
- The frontend sends its resolved destination with `country_code: ""`, so a
  temporary override or clearing the field cannot be overridden by a saved code.
  Saving only a country code does not reapply modem AT settings on `main`.

## Conversation identity and history

The actual destination is recorded in sent history. An explicit reply also
records `conversation_contact`, linking its original local contact to the chosen
international destination. Identical complete digits with and without `+` share
a conversation. No suffix matching or speculative country conversion is used.
Conflicting explicit associations remain separate to avoid merging recipients.

`main` upgrades SQLite schema v3 to v4 by adding a nullable
`conversation_contact` column. Existing message IDs, contents and read status are
preserved. `stable` adds the optional field to new JSON sent-history records;
existing JSON files remain readable. Direct mode keeps its existing behavior of
not retaining sent history; the selected code remains available for subsequent
replies while the form is open.

## Verification

Run on either branch:

```sh
node luci/luci-app-qmodem-next/tests/test_sms_addressing.js
```

On `main`:

```sh
node luci/luci-app-qmodem-next/tests/test_sms_service.js
make -C application/libqmodem-sms/tests
make -C application/qmodem_smsd/tests
```

On `stable`, with the OpenWrt ucode interpreter available:

```sh
ucode -L "$PWD/luci/luci-app-qmodem-next/root/usr/share/ucode" \
  luci/luci-app-qmodem-next/tests/test_sms_number.uc
```

The tests cover multiple calling codes, no preset country, explicit save/clear,
cross-modem response races, international precedence, local/service addresses,
PDU address type and BCD digits, explicit reply associations, ambiguous
associations, invalid input, and database upgrade/reopen without losing history.
These are host tests; delivery through a real modem and carrier still requires
device verification.

Validation performed on 2026-10-24: the Node tests on both branches, C encoder
and database tests, a complete host build of `qmodem-smsd`, ucode tests and RPC
script compilation, Lua syntax checks and translation format checks passed.
Isolated host integration also exercised `main` through a private ubus socket
and `stable` through the real ucode RPC handlers, with temporary UCI/history and
a fake modem transport. Captured PDUs matched the configured, overridden and
cleared destinations. Real modem/carrier delivery was not run.
