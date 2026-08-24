# Publishing a Shrike release

The other side of [Verifying a release](README.md#verifying-a-release). That section is for anyone
downloading a build; this one is for whoever produces it, which for now is one person, because the
signing key lives on one machine and stays there.

The split is deliberate. GitHub Actions builds the binaries and computes their checksums. Everything
after that — download, verify, sign, publish — happens locally, driven by `sign-release.sh`.

> **`sign-release.sh` is not committed yet.** It sits untracked at the root of this repository. A
> release process that depends on a script only one working copy has is not a release process. Commit
> it before relying on any of this.

---

## 1. Dispatch the build

The Package workflow is `on: workflow_dispatch`. It is **not** tag driven, so **no tag is needed to
build** — you tag at the end, after you have seen what came out. Actions → Package → Run workflow, and
pick the branch. Or:

```bash
gh workflow run package.yaml --repo AcesHigh70/sparrow --ref blake2b-header
```

## 2. Expect a red run

The matrix is five platforms with `fail-fast: false`, and **both macOS arms fail**. That is expected
and, until the codesigning secrets exist, permanent. From run `32782169560`:

| Matrix leg          | Result  | Produces                                        |
| ------------------- | ------- | ----------------------------------------------- |
| `windows-2022`      | success | `.msi`, `.zip`                                  |
| `ubuntu-22.04`      | success | x86_64 `.tar.gz`, `.deb`, `.rpm`, + headless    |
| `ubuntu-22.04-arm`  | success | aarch64 `.tar.gz`, `.deb`, `.rpm`, + headless   |
| `macos-15-intel`    | failure | nothing                                         |
| `macos-14`          | failure | nothing                                         |
| `checksums`         | success | `SHA256SUMS`                                    |

**The macOS failure is not a compile failure.** `Build with Gradle` passes on both arms; the run stops
at `Codesign, package and notarize macOS distribution` for want of a certificate. The code is fine.

**A green `checksums` job under a red overall run is the success case.** Do not read the red cross on
the run as a reason to stop.

## 3. What the checksums job gives you

It runs regardless, via `if: ${{ !cancelled() }}`, because a job that waited for a clean matrix would
never run at all. It downloads every artifact that exists, refuses to continue if two of them carry the
same filename, and writes `SHA256SUMS` — **14 entries, sorted by filename**, covering the Windows and
Linux builds including the headless `shrikeserver` ones.

There are no macOS entries, and that is the mechanism by which their absence is handled as normal
rather than as an error: `SHA256SUMS` names only what was actually built, so nothing is missing from
it.

## 4. Sign and publish, locally

```bash
export GPG_TTY=$(tty)
./sign-release.sh <run-id> <tag>
```

**`export GPG_TTY=$(tty)` is what makes the passphrase prompt appear**, and is the reason signing
works over ssh. Without it gpg has no terminal to prompt on and fails with a bare
`signing failed: No such file or directory`, which reads like a missing file and is not one. A shell
with no controlling terminal at all — a CI runner, an automation harness — cannot sign for the same
reason, whatever `GPG_TTY` is set to.

The script, in order:

1. Checks `gh`, `gpg` and `sha256sum` exist and that the secret key is present.
2. Refuses a tag that already exists on the remote — **before downloading anything**, so a mistyped or
   reused tag costs you nothing.
3. Creates a temp directory, prints it, and downloads the run's artifacts into it. Nothing is written
   into a git tree.
4. Flattens the binaries alongside `SHA256SUMS`, taking the filenames from `SHA256SUMS` itself rather
   than a list held in the script.
5. Verifies with plain `sha256sum -c` — **not** `--ignore-missing`. Every listed file must be present.
6. Prints `SHA256SUMS` and its entry count, then **stops**. Nothing is signed before you have seen what
   you are about to attest to.
7. On `y`, signs with `gpg --detach-sign --armor`, then verifies its own signature with `gpg --verify`.
   It refuses to overwrite an existing `SHA256SUMS.asc` rather than quietly re-signing.
8. Prints the `gh release create` it would run. It creates nothing unless you pass `--publish`.

The key is:

```
C9E21BFB DFC040AB 9BE85AFB 2053BF48 10B0A6FB
```

## 5. Tag convention

`v<sparrow-base>-knots<build-tag>.<iteration>` — e.g. `v2.5.4-knots20260508rc2.1`, which pairs Sparrow
2.5.4 with Knots `v29.4.1.knots20260508rc2`, first iteration. Published as a **pre-release**.

Pair the tag with the Knots RC deliberately. A build carrying a different activation height declines to
opt in rather than signing under the wrong schedule, so the pairing is load bearing, not cosmetic.

---

## Things that will bite

**The September 1 mainnet push is two values, not one.** The activation height, and
`-blake2b_headline`. The second is mandatory at node startup with no default — a plain validating node
will not launch without it. The underscore is load bearing: `-blake2bheadline` is rejected outright.

**Building Knots from the sighash branch needs `-DRDTS_CONSENT`.** cmake configure fails outright
without it. This is the opposite of the rc2 advice under [Which build](README.md#which-build), which
tells you to drop the flag.

**macOS produces no dmg by any other route.** `skipInstaller = os.macOsX` in `build.gradle` means
jpackage builds no installer at all on macOS; the `codesign-macos` action is the sole source. That is
why the arm fails entirely rather than partially — there is no unsigned artifact to fall back on. The
action also still passes `app-name: Sparrow`, not `Shrike`.

**The Linux headless leg runs `clean jpackage`, wiping `build/`.** It runs *after* the non-headless
artifact has already uploaded, which is the only reason the non-headless binaries survive. Reordering
those steps, or dropping the `clean`, silently destroys one set of builds or mixes the two.

**GPG signing stays local, deliberately.** Do not add the key to Actions secrets. Doing so would move
it onto GitHub's infrastructure, and anyone who could trigger a workflow — or anyone who compromised
the repository or a single action in the chain — could then produce a signature in Mark's name. The
signature's whole value is that it attests to a human having looked at the checksums on a machine they
control. Automating it removes exactly the property it exists to provide.

---

## What has been executed, and what has not

Sections 1 to 4 were run end to end against run `32782169560` on 2026-08-24: the workflow dispatch, the
red-run behaviour, the 14 entry `SHA256SUMS`, and the script through download, flatten,
`sha256sum -c` (all 14 `OK`), the confirmation stop, signing, and the printed `gh release create`.

**The signature is proven with the release key**, in a real terminal, against tag
`v2.5.4-knots20260508rc2.99`:

```
== Verifying the signature ==
gpg: Signature made Mon 24 Aug 2026 10:54:17 PM UTC
gpg:                using EDDSA key C9E21BFBDFC040AB9BE85AFB2053BF4810B0A6FB
gpg: Good signature from "AcesHigh70 <6564423+AcesHigh70@users.noreply.github.com>" [ultimate]
```

The tag guard was confirmed separately, by it refusing `v2.5.4-knots20260508rc2.1` as already
published before downloading anything.

One thing is **not** verified:

- **`gh release create` has never been run.** Every rehearsal deliberately stopped before it. Nothing is
  known about how it behaves with 16 assets totalling roughly 1.4 GB.

---

## Open: are the binaries reproducible?

Run `32782169560` produced the **same 8 filenames** as the published `v2.5.4-knots20260508rc2.1`
release with **different hashes** for every one of them.

The likely explanation is simply later code — three commits and a merged PR sit between the tag and
that run. Nothing has confirmed it.

What sharpens the question: upstream Sparrow's `README.md` claims reproducibility "from v1.5.0 onwards
(pre codesigning and installer packaging)", and `docs/reproducible.md` narrows that further — only the
`.tar.gz` and `.zip` **contents** are expected to reproduce. The `.deb`, `.rpm` and `.exe` installers
explicitly are not, and the macOS binary is signed and cannot be. So of the 8 files compared, only
three — `Shrike-2.5.4.zip` and the two `.tar.gz` — fall under the claim at all. The other five
differing is consistent with the documented position and is not evidence of anything.

**To settle it:** build the `v2.5.4-knots20260508rc2.1` tag locally with Eclipse Temurin 25.0.2+10, per
`docs/reproducible.md`, and compare the `.tar.gz` and `.zip` against the published hashes. Matching
means the differences are later code and reproducibility holds where it is claimed. Not matching means
reproducibility is broken for this fork, which would be worth knowing before anyone relies on it.

Do not install the JDK from a system package manager for this — Linux packages replace the JDK's
bundled `cacerts` with a symlink to the system CA store, which alone makes the build non-reproducible.
