# DigiByte Core hashes for DigiNode Tools

DigiNode Setup checks every DigiByte Core binary it downloads against the SHA256 hashes in this repo. If the hash doesn't match, it won't install it.

A GitHub Action checks for new DigiByte Core releases every day. When it finds one, it downloads the Linux binaries (`x86_64` and `aarch64`) and only pins the hash if every available source agrees:

- the hash of the downloaded file
- the hash GitHub calculated when the file was uploaded (releases from mid-2025 onwards)
- the `SHA256SUMS` file published with the release (from v9.26.6rc2 onwards)
- the hash already pinned here, which must never change

It also checks the file was uploaded by a trusted DigiByte developer (`TRUSTED_UPLOADERS` in `scripts/update.sh`). Anyone who has left the project is listed in `FORMER_UPLOADERS` and only trusted for older releases. If the uploader isn't trusted, the release is put on hold.

## Files

| File | What it is |
|---|---|
| `hash0.json` | Staging. Every verified release. Used by `diginode-setup.sh --updatetest`. |
| `hash1.json` – `hash4.json` | One per update group. A new release reaches the four groups in a random order, 3, 7, 11 and 15 days after it's published. |
| `releases0.json` – `releases4.json` | The same releases as the matching `hash` file, newest first, with everything needed to install each one: version, publish date, pre-release flag, and for each architecture the real file name, download URL, SHA256, size and the folder inside the tarball. Also `latest` and `latest_release`: the newest versions on GitHub, which may not have reached that group yet. |
| `hashes.json` | Everything the Action knows: pinned hashes, where they were verified, status and rollout dates. |

DigiNode Setup v0.12.0 onwards reads `https://raw.githubusercontent.com/DigiNode-Tools/digibyte-hashes/main/releases<group>.json`. Older versions read `hash<group>.json`, which keeps its original format.

Each tarball must contain a single folder with `bin/digibyted` and `bin/digibyte-cli` in it, or it isn't published. The folder name varies between releases (some use a commit hash), so DigiNode Setup unpacks it into a folder of its own rather than relying on it.

## If something goes wrong

**An alarm issue has been opened.** A hash didn't match, a release has more than one binary for an architecture, or an unexpected account uploaded it. Nothing that failed has been published. Read the issue and close it once it's sorted.

**Stop a release while it's rolling out.** Edit `hashes.json` on GitHub and change the release's `"status"` from `"active"` to `"hold"`. It stays in `hash0.json` for testing but no update group gets it. Change it back to `"active"` to carry on; any group whose date has passed gets it straight away.

**Withdraw a release that turned out to be bad.** Set its `"status"` to `"revoked"`. It's removed from every hash file, so DigiNode Setup won't install it.

## Running it yourself

```bash
scripts/update.sh             # same as the daily run
scripts/update.sh --recheck   # re-download and re-verify everything
scripts/update.sh --dry-run   # check without writing any files
```

Needs `curl` and `jq`. Works on macOS and Linux. Uses your `gh` login if you have one, to avoid API rate limits.

The schedule can also be started by hand from the Actions tab (**Run workflow**), with an option to recheck everything.
