# Privacy and support data

QuietTube adds no analytics endpoint, activation server or automatic diagnostic upload. That says nothing about the network/data practices of YouTube, Google sign-in, your installer, GitHub or a file host.

## What reports contain

Reports can include settings flags, internal class/template names, relative event times, wall-clock timestamps and error categories/codes. The logger does not intentionally print raw payloads, explicit video-ID fields, credentials or signed-URL fields.

Template matching is not a privacy-proof parser. Names that look like identifiers can still contain sensitive clues. **Review a report before sharing it.**

Enhanced logging is the single logger. Presets turn it **off**. Updates preserve saved choices. One master toggle starts/stops daily capture — no separate *Record feed activity* / *Record template clues* switches.

## Where data stays

| Data | Lifetime |
| --- | --- |
| Preferences (including Enhanced logging master) | Local app storage; ordinary restarts and updates keep them. A data reset, removal or new app/container identity can lose them. No cloud settings backup. Master auto-resumes after relaunch until you turn it off. |
| Older event rings | Memory only; reset on process restart. |
| Enhanced log history | Three private cache files of 256 KiB each (768 KiB total, auto-rotates). Seven-day expiry is applied on cleanup, not while a closed app is unable to run. iOS can evict them. |
| Exported reports/screenshots | Wherever you save or share them. Clearing QuietTube’s files cannot remove those copies. |

When the master is on, it auto-resumes after relaunch. Export includes recent disk events (last 3 sessions) and the current support snapshot. Clear deletes the 3 files (and briefly stops, then resumes if master is still on). Check failure counts rather than assume a failed filesystem operation succeeded.

[Recording, expiry and sampling limits](DIAGNOSTICS.md).

## Builds and public releases

The IPA workflow downloads the URL you supply on GitHub’s runner, validates the exact input and publishes the result in your fork. It also attaches the compiled dylib. A public fork produces public release assets.

The dylib-only workflow downloads no base app and releases no YouTube IPA. It publishes the library, notices, checksums and build metadata in the original repository or a fork, with that repository’s visibility.

Both clean up temporary outputs. That does **not** delete releases, past runs, GitHub logs, workflow metadata or repository history.

The base URL is a workflow input, **not a GitHub secret**. The downloader masks its own output and avoids URL-bearing exception messages, but GitHub may retain the input. Do not put passwords or sensitive long-lived tokens in it. These workflows do not request Apple credentials or signing certificates.

## File hosts

Uploading to [Catbox](https://catbox.moe/legal.php) means sending a file to a third party. Anyone with the resulting link may be able to download it; anonymous uploads are not private storage. Upload only what you have permission to share. QuietTube neither manages nor removes those uploads.

## SponsorSkip (off by default)

When off, QuietTube makes no SponsorBlock calls and stores no SponsorBlock data.

When on, for each video it hashes the videoID with SHA256 and sends only the first 4 hex characters to `https://sponsor.ajay.app/api/skipSegments/<prefix>`. The server returns segments for all videos sharing that prefix; QuietTube filters locally for your exact videoID and skips locally. The full videoID is not sent. Responses are cached in `Library/Caches/QuietTube/SponsorSkip` (up to 100 videos, 7-day, excluded from backup, cleared with Disable all).

Segment data is community-submitted (CC BY-NC-SA 4.0) and can be wrong or abused — see the disclaimer in **You → Settings → General → Quiet controls → SponsorSkip**.

## If you exposed something sensitive

Remove it and revoke affected credentials or tokens where applicable. Use GitHub’s removal/reporting process where needed; don’t repost the material while asking for help. Issues should not contain app binaries, account identifiers, passwords, cookies, tokens or unreviewed full captures.
