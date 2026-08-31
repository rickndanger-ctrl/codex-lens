# Codex Lens texting acceptance

Status observed on Richard's Mac mini 2 on 2026-08-26 at 20:24 PDT.

## 21:03 PDT live remote-readiness recheck

- The LaunchAgent remains running, Tailscale reports the home Mac online, and tailnet-only HTTPS returned gateway health `status: ok`.
- The authenticated remote readiness route again returned `ready: true`, Contacts accessible, one available iMessage account, one available SMS account, and no available RCS account.
- No message was prepared or sent. Actual iMessage and SMS delivery, locked cellular use, and replay rejection remain physical gates.

## 20:52 PDT remote-readiness recheck

- `com.codex-lens.gateway` remains running as a LaunchAgent (PID 81764).
- The home Mac Tailscale backend is `Running`, the Mac is online, and tailnet-only HTTPS proxies `/` to `127.0.0.1:8787`.
- The tailnet health route returns `status: ok` and gateway version `0.0.0`.
- The authenticated remote readiness route returns `ready: true`, Contacts accessible, one available iMessage account, one available SMS account, and no available RCS account.
- This proves the current Mac side is reachable and ready through the configured tailnet URL. It does not prove cellular delivery away from home; one explicitly approved iMessage and one explicitly approved SMS remain required. No message was sent during this check.

## What is proved

- The iPhone exposes two separate Realtime tools: `prepare_text_message` and
  `send_prepared_text`. Preparing cannot send.
- The phone accepts only the later, exact spoken phrase `Confirm text`. Generic
  phrases such as `yes`, `okay`, and `send it` are rejected.
- The phone binds the model's send call to its locally pending confirmation ID
  and digest, and consumes that local confirmation before making the network
  request.
- The authenticated gateway binds the digest to the resolved destination,
  exact body, expiry, and random confirmation ID. It consumes the preparation
  before invoking Messages, so a timeout or concurrent replay cannot cause an
  automatic duplicate.
- The send endpoint accepts only `confirmationId` and `digest`; a caller cannot
  replace the recipient or body at send time.
- Logs redact recipient, body, confirmation ID, digest, bearer token, and API
  credentials.
- The deployed Tailnet route passed a non-sending live dry-run with a reserved
  fictional `555-01xx` number: preparation returned `200`, the destination was
  masked, and a deliberately wrong digest returned `422` before Contacts or
  Messages ran.
- Focused gateway tests pass: 13/13. The complete CodexLensKit Swift tests pass:
  51/51.
- The LaunchAgent is running in Richard's GUI login session. Tailscale is online,
  HTTPS proxies to the loopback-only gateway, Messages is running, and system
  sleep is disabled while the Mac mini is on AC power.
- Live readiness reports Contacts accessible, one connected iMessage account,
  one connected SMS account, no connected RCS account, and `ready=true`.
- A real startup regression was repaired: when Contacts was not already running,
  AppleScript returned application error `-600` even though permission was
  granted. The deployed gateway now launches Contacts in the background before
  readiness or name lookup and launches Messages before account inspection or
  send. With Contacts fully stopped, the live readiness request launched it and
  returned `ready=true`.
- Text authorization is now valid only after the phone observes a completed
  spoken readback. Intervening speech, pre-readback confirmation, expiry,
  reconnect, and session rollover invalidate the pending send.

## What is not proved yet

1. **Actual Messages acceptance:** no real message was sent during this audit.
   Exactly one send invocation, exactly one resulting message, and recipient or
   carrier delivery are therefore unproved.
2. **RCS:** the gateway now selects only the exact requested service and the
   live Mac has one iMessage account and one SMS account, but no connected RCS
   account. Green-bubble SMS delivery remains physically unproved.
3. **Wearer identity:** Realtime transcription has no trusted speaker identity.
   During the short confirmation window, another nearby person saying the exact
   phrase `Confirm text` is indistinguishable from the wearer.
4. **Locked-phone cellular path:** locked-phone background voice, cellular
   Tailnet reachability, contact resolution, confirmation, and one Messages
   invocation have not been demonstrated together.
5. **Mac dependency:** this implementation sends through the Mac, not directly
   through the iPhone. It requires the Mac to remain powered, logged in, awake,
   online, connected to Tailscale, and signed into Messages. A gateway restart
   intentionally invalidates prepared messages instead of restoring them.
6. **Full iPhone wiring:** the green Swift tests cover the confirmation parser,
   attention gate, gateway client, and wire models, but no test target currently
   drives `SessionViewModel` from transcript through both Realtime tool calls.
   Those component tests do not replace physical voice acceptance.

## Safe next live acceptance

Do this with Richard physically at the Mac so any macOS permission sheet is
visible. Use Richard's own phone number as the destination for the first actual
delivery test.

1. Say a complete request: `Text my own number: Codex Lens delivery test one.`
2. Verify the assistant reads the resolved name or number, masked final four
   digits, and exact body. It must not send yet.
3. Say `Send it`. Verify no `/v1/messages/send` request appears.
4. Say `Confirm text` only after the preview is correct.
5. Verify exactly one `/v1/messages/send` request, exactly one message in the
   self-conversation, and no second message after repeating `Confirm text`.
6. Repeat once with the iPhone locked and using cellular rather than Wi-Fi.
7. Test an iMessage recipient and a green-bubble SMS/RCS recipient separately;
   one does not prove the other.

Do not call the feature reliable until all seven checks are observed. A `200`
from the gateway means only that Mac Messages accepted the AppleScript command;
it is not a carrier or recipient delivery receipt.
