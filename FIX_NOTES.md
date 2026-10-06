# QuietTube 1.3.0-exp.37 StreamFallback Fix — 2026-10-05

## Diagnosis from your new log (text.txt, 2026-10-05, 473 lines)

**Device:** YouTube 21.38.2, iOS 26.5, QuietTube 1.3.0-exp.34 (your installed build)
- Player hook: yes (2 calls, 2 no-op)
- Mode: WEB-persistent, armed=yes (useWebClient=on)
- But `StreamFallback: rewrites=0, successes=0, attempts=0`
- Playback error: `code 14 :1` at +36s → `web_mode_stall_unexpected` depth 99
- No `player_req` events logged (the detailed per-request log is absent)

**Root cause confirmed:** The fallback never fired.

### Why rewrites=0 even though armed=yes ?

Fixed-RealDylib's `QTStreamFallback.m` only hooked:
```objc
uploadTaskWithRequest:fromData:completionHandler:
```
via `dispatch_async(main)`. Your player InnerTube request on 21.38.2 goes via:
```
NSURLSession dataTaskWithRequest:completionHandler:
  req.HTTPBody = {"context":{"client":{"clientName":"IOS",...}}, ...}
```
(not `fromData:`). The dataTask hook was only *logged* as available:

```objc
OrigDataTaskCB = method_getImplementation(m2);
QTCount(@"streamFallback: dataTask hook available");
```

— no `method_setImplementation`, so no rewrite. The uploadTask hook also missed requests where body lives in `req.HTTPBody`.

The added `player_req` detailed logger lived only inside the uploadTask wrapper, so zero `player_req` lines proves the wrapper was never called.

### Fix in this zip (1ea0ba93)

`Sources/QTStreamFallback.m` now:

1. **Synchronous install** — `QTInstallBodyRewriteOnce()` runs directly on the `QTStart` main-queue block, not a second `dispatch_async`. Captures current IMP immediately.

2. **Three NSURLSession hooks:**
   - `uploadTaskWithRequest:fromData:completionHandler:` (body param)
   - `dataTaskWithRequest:completionHandler:` (HTTPBody)
   - `dataTaskWithRequest:` (no completion, delegate style)

3. **Body source agnostic** — tries `body ?: req.HTTPBody ?: HTTPBodyStream` (reads stream if needed). Handles both uploadTask and dataTask paths.

4. **Shared helper** `QTStreamFallbackTryRewrite()`:
   - checks `QTFallbackIsArmed()` + `youtubei.googleapis.com` + `/player|/next|/browse`
   - parses `srcBody` to log `origClient`
   - calls `QTRewriteInnertubeBody()` → if rewritten, sets `mutable.HTTPBody` or `newBody`, increments `QTFallbackRewrites`, emits `fallback_rewrite_WEB` + `player_req mode=WEB orig=IOS rewrote=yes/no`

5. **Race with QTIntegrity** — both use `dispatch_async`. Now StreamFallback schedules re-checks at 0.8s and 2.5s: if `QTIntegrity` overwrote our hook, we re-capture `cur` as new orig and reinstall, preserving chain `newOur -> integrity -> original`.

**Expected next log (after install):**
```
streamFallback: hooked uploadTaskWithRequest:fromData:completionHandler: :1
streamFallback: hooked dataTaskWithRequest:completionHandler: :1
streamFallback: hooked dataTaskWithRequest: :1
streamFallback: InnerTube body rewrite scheduled :1
...
player_req mode=WEB orig=IOS rewrote=yes   (for every /player)
fallback_rewrite_WEB :1
StreamFallback: mode=WEB-persistent attempts=0 successes=0 rewrites=1+ armed=yes
```
and **no** `web_mode_stall_unexpected`. If you still see code 14, the log will now show `orig=WEB rewrote=no` (already WEB) or `orig=IOS rewrote=yes` proving rewrite happened — then the stall is not PoToken but other.

## Install

```bash
unzip QuietTube-1.3.0-exp.37-StreamFallbackFixed.zip
cd QuietTube-main
git init
git add .
git commit -m "QuietTube 1.3.0-exp.37 — fix StreamFallback dataTask + sync rewrite (1ea0ba93)"
git branch -M main
git remote add origin https://github.com/mage09smith-dot/QuietTube.git
git push -u origin main --force
# GitHub Actions → Build QuietTube dylib only
```

On device: install new dylib, enable Quiet controls → useWebClient ON, restart YouTube, play. Check diagnostics: `rewrites` must be >0 and `player_req` lines present.
