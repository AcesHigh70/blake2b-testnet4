# Mining the BLAKE2b hardfork on testnet4

A working setup: Bitcoin Knots node, DATUM Gateway, and a miner, all pointed at
testnet4 across the BLAKE2b activation at **height 149537**.

Everything here was verified on a live testnet4 node running
`v29.4.1.knots20260508rc2`. Where something is unverified it says so.

> **Status:** the fork is unmerged and under active review. Branches force-push,
> option names change, and nothing here should be assumed stable. Check the
> upstream PRs before trusting a detail.

> **rc1 users: your chain is gone.** rc1 activated at height 149460. rc2 moved
> activation to 149537, and the chain that formed under rc1 was replaced —
> `getblockhash 149460` now returns a different block than it did under rc1.
> This is not a reorg you can wait out. Rebuild against rc2 and resync.

---

## What you need

| Component                    | Why                                                                             |
| ---------------------------- | ------------------------------------------------------------------------------- |
| Bitcoin Knots, BLAKE2b build | Serves block templates and validates. Activation height is compiled in.         |
| DATUM Gateway, BLAKE2b build | Turns templates into stratum jobs. Selects the PoW algorithm.                   |
| A miner                      | Optional pre-activation. See [Miners](#3-miners) for the post-activation problem. |

A single Linux box is fine. Disk: testnet4 is ~14 GB as of August 2026, unpruned.

---

## 1. The node

### Which build

The activation height is **hardcoded in the release tag**, not in the base
development branch. This is the single most common way to waste an evening:

- `v29.4.1.knots20260508rc2` — activates on testnet4 at height 149537
- `v29.4.1.knots20260508rc1` — activated at 149460, on a chain that no longer exists
- `__base_29_blake2` — sets activation on **regtest only**

If you build the base branch and point it at testnet4, the boundary passes
silently and nothing happens.

There are **no published binaries** for the RC. You must build from source.

```bash
git clone https://github.com/bitcoinknots/bitcoin.git
cd bitcoin
git checkout -b rc2 v29.4.1.knots20260508rc2

cmake -B build-rc2 -DBUILD_GUI=OFF -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build build-rc2 -j$(nproc)
```

Build into a named directory rather than `build/` if you also keep a development
branch checked out — the two builds are not interchangeable and mixing them up is
the failure mode described above.

Drop `-DCMAKE_CXX_COMPILER_LAUNCHER=ccache` if you don't have ccache installed.

Binaries land in `build-rc2/bin/`.

**Do not pass `-DRDTS_CONSENT`.** rc1 required it. rc2 does not — the option was
added and then reverted, and `RDTS_CONSENT` appears nowhere in the rc2 tree.
Passing it to rc2 is merely unused, but commit `c2a6a67e1f` adds a `FATAL_ERROR`
for it, so any build that includes that commit will refuse to configure if the
variable is set. If you're carrying an old command line, drop the flag; if it's
already in your CMake cache, clear it with `-U RDTS_CONSENT`.

### Config

`~/testnet4/bitcoin.conf`:

```
testnet4=1
server=1

[testnet4]
rpcuser=YOURUSER
rpcpassword=YOURPASSWORD
rpcport=48332
blocknotify=killall -USR1 datum_gateway
blake2b_headline=YOUR_HEADLINE
```

Two of those matter more than they look.

**`blocknotify`** — without it the gateway falls back to polling and you mine
stale work across the boundary. Run the gateway as the same user as the node and
make sure `killall` is installed (`psmisc` on Debian-likes). If node and gateway
are on different machines, use the gateway's `NOTIFY` API endpoint instead.

**`blake2b_headline`** — **required to start the node at all**, mining or not.
`AppInitParameterInteraction` in `src/init.cpp` returns
`This version requires blake2b_headline set manually` if the option is unset, so
a plain validating node won't launch without it. This is not just coinbase
plumbing.

Separately, it carries a consensus rule: `CheckBlock` requires the string to
appear in the coinbase scriptSig of the block at **exactly** the activation
height. The check is `==`, not `>=`, so it applies to one block and no others.

An empty value satisfies both. `-blake2b_headline=` passes the startup check
(`IsArgSet` only tests for presence) and passes the consensus check vacuously
(an empty needle always "matches"). The unit test framework relies on this. If
you don't care what goes in the coinbase, an empty value is legitimate — but set
it deliberately rather than discovering it by accident.

On mainnet the consensus rule is currently inert: `Blake2bHeight` defaults to
`INT_MAX` and is only assigned in `CTestNet4Params` (`chainparams.cpp:387`,
`consensus.Blake2bHeight = 149537`) and in regtest from `activation_heights`. So
a mainnet node must still set the option to start, but no block height will ever
trigger the check. Whether the final release assigns a mainnet height is a
release-process question, not visible in the source.

### Start and verify

```bash
bitcoind -datadir=$HOME/testnet4 -daemon
```

Confirm you have the right binary and the right activation. Both checks:

```bash
bitcoin-cli -datadir=$HOME/testnet4 -testnet4 -rpcport=48332 \
    getnetworkinfo | grep -i subversion

bitcoin-cli -datadir=$HOME/testnet4 -testnet4 -rpcport=48332 \
    getdeploymentinfo
```

You want:

```
"subversion": "/Satoshi:29.4.1/Knots:20260508rc2/"
```

and, in `getdeploymentinfo`:

```json
"hardfork": { "height": 149537, "active": true }
```

`hardfork` sits at the **top level**, not inside `deployments` — it is neither a
versionbits nor a buried deployment, so it doesn't appear alongside `csv` and
`segwit`. You'll also see `reduced_data` as a `flagday` deployment at the same
height; that's the RDTS side of the fork landing simultaneously.

If `hardfork` is missing, you have the wrong build. Stop and fix that first. If
it reports height 149460, you're on rc1 and on a dead chain.

### Peering

The fork chain is not the chain your DNS seeds will hand you. Post-activation,
non-upgraded testnet4 nodes reject BLAKE2b blocks outright — their PoW check
fails on a 164-byte v2 header — so you can sit with eight healthy-looking peers
and never advance.

Add known fork nodes manually. This takes effect immediately and needs no
restart:

```bash
bitcoin-cli ... addnode "HOST:48333" "add"
```

Then confirm you actually got fork peers rather than sockets:

```bash
bitcoin-cli ... getpeerinfo | jq -r '.[] | select(.subver | test("20260508rc2"))
  | "\(.addr)  headers=\(.synced_headers)"'
```

Empty output means you're isolated. A peer showing `version: 0`,
`subver: ""`, and `synced_headers: -1` has an open socket but never completed
the version handshake — that's their side, not yours.

Once a few fork peers are established, address gossip takes over and more arrive
on their own. Manual peering is a bootstrap crutch, not a permanent requirement.
Runtime `addnode` does not survive a restart; put the entries in your config if
you want them to persist.

### RPC credentials gotcha

If `bitcoin.conf` sets `rpcuser`/`rpcpassword`, Core does **not** write a
`.cookie` file, and `bitcoin-cli` will fail with *"Could not locate RPC
credentials"* unless you pass them. Use stdin so the password stays out of your
shell history and out of `ps`:

```bash
bitcoin-cli -datadir=$HOME/testnet4 -testnet4 -rpcport=48332 \
    -rpcuser=YOURUSER -stdinrpcpass getblockcount
```

If you use `rpcauth=` instead, the hash can't be reversed — you must always
supply the password explicitly.

### Templates work during sync, and that's a trap

Core skips the peer-count and IBD guards on test chains:

```cpp
if (!Params().IsTestChain()) {
    ...
    if (active_chainstate.IsInitialBlockDownload()) {
        throw JSONRPCError(RPC_CLIENT_IN_INITIAL_DOWNLOAD, ...);
    }
}
```

On mainnet a syncing node refuses to serve templates. On testnet4 it serves them
happily, on a tip that may be tens of thousands of blocks stale. Your gateway
will start, log new blocks, and look completely healthy while mining nothing
useful.

Confirm sync before trusting anything:

```bash
bitcoin-cli ... getblockchaininfo | jq -c '{blocks, headers, initialblockdownload}'
```

You want `blocks` equal to `headers` and `"initialblockdownload": false`.

---

## 2. DATUM Gateway

Upstream DATUM does not support BLAKE2b. Use justinfilip's fork:

```bash
sudo apt install cmake pkgconf libcurl4-openssl-dev libjansson-dev \
    libsodium-dev libmicrohttpd-dev psmisc

git clone https://github.com/justinfilip/datum_gateway.git
cd datum_gateway
cmake . && make
```

(`psmisc` provides `killall`, which the `blocknotify` line above depends on.)

Always confirm the option names against your build rather than trusting a guide:

```bash
./datum_gateway -?
```

### Config

`datum_gateway_config.json`, in the gateway's directory:

```json
{
    "bitcoind": {
        "rpcuser": "YOURUSER",
        "rpcpassword": "YOURPASSWORD",
        "rpcurl": "http://127.0.0.1:48332",
        "work_update_seconds": 10,
        "notify_fallback": true
    },
    "stratum": {
        "listen_port": 23334,
        "vardiff_min": 16384
    },
    "mining": {
        "pool_address": "YOUR_TESTNET_ADDRESS",
        "coinbase_tag_primary": "testnet4",
        "coinbase_tag_secondary": "blake2b test",
        "pow_algorithm": "blake2b",
        "allow_hasher_time_rolling": false,
        "save_submitblocks_dir": "/home/YOU/testnet4/submitted"
    },
    "api": {
        "admin_password": "SOMETHING_REAL",
        "listen_addr": "127.0.0.1",
        "listen_port": 7152,
        "modify_conf": false
    },
    "logger": {
        "log_to_console": true,
        "log_to_file": true,
        "log_file": "/home/YOU/testnet4/datum.log",
        "log_level_console": 2,
        "log_level_file": 1
    },
    "datum": {
        "pool_host": "",
        "pooled_mining_only": false
    }
}
```

### The four settings that actually matter

**`pool_host: ""`** — this is the one everybody gets wrong. Omitting the key does
*not* mean "no pool": it falls back to the compiled-in default, which is a live
production OCEAN host. Your gateway will connect to it and hand it work built
from a testnet4 chain. Setting `pooled_mining_only: false` alone does **not**
disable pooling — it only adds a solo *fallback* for when the pool is
unreachable. You need both.

Verify on the dashboard: `Status: ● Non-Pooled Mode`, `Pool Host: N/A`. If you
see a `DATUM Server MOTD` line at startup, it's still pooling.

**`pow_algorithm`** — valid values are `auto`, `blake2b`, `sha256d`. Default is
`auto`.

Post-activation, **`auto` and `blake2b` both work; `sha256d` breaks the gateway
entirely.** The reasoning is worth understanding, because the rc1-era advice on
this was wrong in both directions.

The node now refuses to serve a template to a client that hasn't declared the
rule:

```
error code: -8
error message:
Support for 'blake2b' rule requires explicit client support
```

The gateway handles that. `datum_gbt_advertise_blake2b()` in
`datum_blocktemplates.c` returns true for any `pow_algorithm` that isn't
`"sha256d"`, and the caller then sends `{"rules":["segwit","blake2b"]}` rather
than segwit alone. So `auto` declares the rule too — it is not a passive setting.

Detection then happens on the response. Of the five signals `auto` looks for,
two are unavailable: `getblocktemplate` returns `powalgorithm: null` and
`xor_key: null` even on a genuine v2 template. What it does return is
`version: 2684354560` — `0xA0000000`, bit 31 set — and that is the signal `auto`
actually keys off.

Setting `sha256d` explicitly is the one dangerous choice: the gateway then
declares only segwit, the node refuses, and you get no template at all.

`blake2b` is still worth setting explicitly for clarity of intent, and because it
removes any dependence on the detection path.

**`vardiff_min`** — 16384 is right for an ASIC. For a CPU miner set it to `1` or
you will never submit a share. Don't leave it at 1 when you attach real hardware.
(Post-activation this is moot for CPU miners — see [Miners](#3-miners).)

**`save_submitblocks_dir`** — writes every submitted block as a `submitblock`
JSON file. Free ground truth for cross-checking header construction, and the
unambiguous answer to "did I actually find a block?" Create the directory
yourself; the gateway won't.

### Run it

`-c` resolves relative to the working directory, so either `cd` first or use an
absolute path:

```bash
cd /path/to/datum_gateway
./datum_gateway -c datum_gateway_config.json
```

Dashboard at `http://127.0.0.1:7152`. With `listen_addr` set to localhost you'll
need a tunnel from another machine:

```bash
ssh -4 -L 7152:127.0.0.1:7152 user@yourbox
```

### Reading the dashboard: `Version: 20000000` is correct

The Status page shows `Version: 20000000` even when the gateway is serving
BLAKE2b work, and this looks exactly like the failure you're worried about. It
isn't one.

The gateway parses the template's version, records bit 31 as "this is blake2b",
and then **strips it**, keeping v2-ness in a separate `header_version` field —
the same split the node and the wallet libraries use, where the version word
carries the flag on the wire but is stored stripped:

```c
if (tdata->version & 0x80000000) {
    want_blake2b = true;
    tdata->version &= ~0x80000000;
}
```

The dashboard renders the stripped value and doesn't currently expose
`header_version`, so there's no positive confirmation available there. To check
the algorithm for real, look at the stratum job rather than the dashboard:

```bash
(printf '{"id":1,"method":"mining.subscribe","params":["probe"]}\n'; sleep 5) \
  | timeout 8 nc 127.0.0.1 23334
```

A v2 job carries more data in the ntime position than the 8 hex characters a v1
job would — that difference is why v1 miners reject the notify outright.

---

## 3. Miners

### Before activation

Testnet4 was SHA256d before 149537, so ordinary miners worked. This section is
retained for anyone bringing up a regtest chain with an activation height ahead
of them.

**ASIC** — point it at `yourbox:23334`, username = your testnet address,
password anything. Leave `vardiff_min` at 16384 or higher.

**CPU** — useful for verifying the stack end to end without hardware:

```bash
sudo apt install -y automake autoconf pkg-config \
    libcurl4-openssl-dev libjansson-dev libssl-dev libgmp-dev make g++

git clone https://github.com/pooler/cpuminer.git
cd cpuminer
./autogen.sh && ./configure CFLAGS="-O3" && make

./minerd -a sha256d -o stratum+tcp://127.0.0.1:23334 \
    -u YOUR_TESTNET_ADDRESS -p x -t 4
```

Set `vardiff_min: 1` first. At difficulty 1 expect roughly one share every one
to three minutes on a few cores. `accepted: n/n (100.00%)` in the miner and
`DiffA` climbing on the Clients tab means the whole chain works.

Note the dashboard's hashrate column reads in Th/s to two decimals, so anything
under 10 Gh/s displays as `0.00` forever. Watch `DiffA`, not hashrate.

### After activation — read this before planning anything

**Every SHA256d ASIC stopped working at 149537.** S19-class hardware is
fixed-function silicon; no firmware update makes it compute BLAKE2b. Expect
rejects or a stall.

**`cpuminer` also stopped working**, and its failure mode is distinctive. It logs

```
[timestamp] Stratum notify: invalid parameters
```

once per template refresh — every 10 seconds with the config above. That's the
v1 job parser rejecting a v2 notify, not a connectivity problem. It hashes
SHA256d over an 80-byte header; the fork uses BLAKE2b over a 164-byte v2 header.
That's a code change, not a flag. Stop it; it will never recover.

**What does work: Sia-style BLAKE2b hashers.** The gateway's README names the
**Antminer A3** specifically, and says "or other Sia-style BLAKE2b hasher." The
header is described in the config help as *BLAKE2b / BLAKE2b-sia header v2* —
the PoW was shaped so existing BLAKE2b-Sia mining silicon can be repurposed
rather than requiring new hardware.

In practice that means the BLAKE2b-Sia families:

- **Bitmain Antminer A3** — named explicitly. Bricked by Sia's 2018 hardfork,
  so these exist in quantity and cost almost nothing.
- **Goldshell SC series** (SC-BOX, SC Lite, SC5 Pro, SC6 SE) and **iBeLink
  BM-S** series — current-generation BLAKE2b-Sia machines.

Two caveats. Silicon that computes BLAKE2b is necessary but not sufficient — the
stratum job format and header layout have to match what the firmware expects, and
the four ASIC profiles in the PoW implementation exist precisely because these
families differ. Test before you buy in quantity. And set
`allow_hasher_time_rolling: false`; per the README it only matters once the node
commits `UseTimeOffset` in header 1.

### Difficulty across the boundary

The fork resets the target rather than carrying SHA256d's retarget state into
BLAKE2b — reasonable, since SHA256d difficulty is meaningless to a Sia ASIC.
Expect the value at the activation block to bear no relation to the block before
it.

Two things follow that will look alarming and aren't:

**Timestamps can appear to go backwards at the boundary.** Pre-fork testnet4
blocks are often stamped 20 minutes and one second apart, farming the
min-difficulty rule, which pushes them well ahead of real time. The first v2
block stamps honestly against median-time-past, so it can be an hour "earlier"
than its parent. Consensus only requires exceeding MTP, so this is valid.

**Blocks can arrive far faster than the target.** Immediately after activation
the chain moved several thousand blocks in about an hour, with timestamps pinned
at `mediantime + 1`. That's miners clamping to the earliest permitted value while
real time catches up to the inflated pre-fork stamps, not a difficulty failure.

### Shares are not blocks

A share meets the gateway's vardiff target. A block meets the network target.
The gap from a CPU is many orders of magnitude.

The exception is real and worth knowing: testnet4 keeps the 20-minute
min-difficulty rule, so after a slow stretch the next block may be mineable at
difficulty 1. Check whether you're in one:

```bash
bitcoin-cli ... getblockchaininfo | jq -c '{bits, difficulty}'
```

`"bits": "1d00ffff"` with `"difficulty": 1` means the window is open. Note that
this only helps you if you have hardware that can compute the right algorithm.

---

## 4. Capturing an activation

If you're bringing up a regtest chain or a future release with an activation
ahead of it, run this before the boundary so you have a record whether or not
you're watching. Use `screen` or `tmux` so it survives a dropped session:

```bash
mkdir -p ~/testnet4/gbt
cd ~/testnet4

while true; do
  H=$(bitcoin-cli -datadir=$HOME/testnet4 -testnet4 -rpcport=48332 \
      -rpcuser=U -rpcpassword=P getblockcount)
  bitcoin-cli -datadir=$HOME/testnet4 -testnet4 -rpcport=48332 \
      -rpcuser=U -rpcpassword=P getdeploymentinfo > gbt/deploy-$H.json 2>&1
  bitcoin-cli -datadir=$HOME/testnet4 -testnet4 -rpcport=48332 \
      -rpcuser=U -rpcpassword=P \
      getblocktemplate '{"rules":["segwit","blake2b"]}' > gbt/$H.json 2>&1
  sleep 20
done
```

**The `blake2b` rule is required.** An rc1-era loop asking for `["segwit"]` alone
will get `Support for 'blake2b' rule requires explicit client support` for every
sample once the fork is active, and you'll capture nothing but errors at exactly
the moment you cared about.

Files are named by **tip height**. The template in `<H>.json` is for the block
being built, i.e. height `H+1`. So:

- `gbt/149535.json` → template for 149536, old rules
- `gbt/149536.json` → template for **149537**, first block under the new rules

`hardfork.active` flipping `false` → `true` in the `deploy-*.json` files is your
unambiguous marker, independent of how the template happens to represent the
change.

Note the loop puts the RPC password in `ps` output. Kill it when you're done.

### Capturing v2 headers

Worth doing separately, and worth doing early. `getblockheader` on rc2 exposes
the v2 fields directly:

```bash
for h in $(seq START END); do
  hash=$(bitcoin-cli ... getblockhash $h)
  bitcoin-cli ... getblockheader $hash        > headers/$h.json
  bitcoin-cli ... getblockheader $hash false  > headers/$h.hex
done
```

The JSON carries `header_version`, `nonce2`, `nonce3`, `extranonce`,
`time_offset`, `header_flags`, `xor_key_mask_clear_bits`, `xor_key` and
`mm_rhs`. The raw form is the 164-byte serialized header, 328 hex characters.

Two things make this more useful than it looks. Header/hash pairs from a public
chain are expected values no implementation can regenerate to match itself, which
makes them far stronger test vectors than a fixture copied out of the reference
implementation. And the blinding fields are only populated once real miners are
on the chain — immediately after activation `xor_key` was zero on every block,
and only later did blocks start carrying non-zero keys. If you want coverage of
the blinded path, capture after the network has hashpower on it, not before.

---

## Troubleshooting

| Symptom                                        | Cause                                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------------------- |
| Node won't start, "requires blake2b_headline"  | Every node needs the option set, mining or not. An empty value is accepted.     |
| CMake fails on `RDTS_CONSENT`                  | rc1 flag, removed in rc2 and a hard error in later commits. Drop it, `-U` it.   |
| `hardfork` height reads 149460                 | You're on rc1. That chain no longer exists.                                     |
| Healthy peer count, chain not advancing        | Your peers are non-fork nodes. Add fork peers with `addnode`.                   |
| Peer with `version: 0`, `synced_headers: -1`   | Socket open, handshake never completed. Their end.                              |
| `Support for 'blake2b' rule requires...`       | GBT call didn't declare the rule. Use `["segwit","blake2b"]`.                   |
| Dashboard shows `Version: 20000000`            | Correct. Bit 31 is stripped by design and carried in `header_version`.          |
| `Stratum notify: invalid parameters` every 10s | v1 miner receiving v2 jobs. It cannot be fixed; the algorithm changed.          |
| Gateway logs a `DATUM Server MOTD`             | `pool_host` isn't `""`. You're pooling.                                         |
| `getblockcount` lower than the template height | Not a reorg. Template height is tip + 1.                                        |
| Dashboard hashrate stuck at `0.00 Th/s`        | Display floor is 10 Gh/s. Watch `DiffA`.                                        |
| Miner connects, never submits                  | `vardiff_min` too high for the hardware.                                        |
| Node serving templates while far behind        | IBD guard is skipped on test chains. Check `initialblockdownload`.              |
| `Could not locate RPC credentials`             | Password auth configured, so no cookie exists. Pass `-rpcuser`/`-stdinrpcpass`. |
| Gateway reads the wrong config after an edit   | `-c` is relative to cwd. Use an absolute path.                                  |
| `bind [::1]:PORT` on `ssh -L`                  | IPv6 unavailable locally. Harmless; the IPv4 forward works. Use `ssh -4`.       |

---

## Wallets

This has moved considerably since rc1, when it was largely unsolved.

**Following the chain works.** Sparrow-derived wallets need BLAKE2b digest
support, 164-byte v2 header parse and serialize, and PoW verification routed by
header version. All three exist in drongo now, and a wallet built on it syncs
past activation against a live node and tracks the tip.

### Shrike

A Sparrow fork carrying that work, for testing this fork:

- Source: <https://github.com/AcesHigh70/sparrow>
- Releases: <https://github.com/AcesHigh70/sparrow/releases>

Each release is tagged with the Knots RC it was built against — the tag
`v2.5.4-knots20260508rc2.1` pairs with `v29.4.1.knots20260508rc2` and its
activation height of 149537. A build carrying a different height will decline to
opt in rather than sign under the wrong schedule, so pair them deliberately.

Read the following before running it.

**Testnet4 only. Do not point this at mainnet or at any wallet holding real
coins.** It is a fork build of a wallet, tracking an unmerged consensus change,
and it has not been audited by anyone.

**The binaries are unsigned in the code-signing sense.** No Authenticode on
Windows, no notarization on macOS. SmartScreen will warn. That is expected for a
fork build, not a sign that something is wrong — but it also means the operating
system gives you no assurance about what you're running. GitHub Actions built
these; nobody, including whoever published the release, can verify the binary
corresponds to the source any better than you can. **Building from source
yourself is the stronger option and is not difficult** — see below.

**No macOS build.** The codesign step needs Apple Developer credentials that only
exist in the upstream Sparrow repository.

### Verifying a release

`SHA256SUMS` is signed with the same key that signs the release tags and commits,
so GitHub shows those as Verified — a second place to check the fingerprint
agrees:

```
C9E21BFB DFC040AB 9BE85AFB 2053BF48 10B0A6FB
```

```bash
gpg --keyserver hkps://keys.openpgp.org \
    --recv-keys C9E21BFBDFC040AB9BE85AFB2053BF4810B0A6FB
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

Be clear about what this buys you: it establishes that the same identity signed
this release, the previous one, and the commits behind them. It does not
establish that the binary matches the source, and it is not a substitute for
building it yourself.

**Building it yourself.** You do not compile anything by hand; Gradle does it:

```bash
git clone --recursive https://github.com/AcesHigh70/sparrow.git
cd sparrow
git checkout v2.5.4-knots20260508rc2.1
git submodule update --init --recursive
./gradlew run
```

`--recursive` matters — the drongo and lark submodules are where the actual
BLAKE2b work lives, and a plain clone leaves you with empty directories and a
confusing failure. You need a **JDK 22 or newer**, not just a JRE: the build uses
`_` as a lambda parameter and fails outright on 17. `./gradlew jpackage` produces
installable artifacts instead of launching.

Check out the tag rather than the `blake2b-header` branch unless you want the
moving target — the branch changes under you and two people following this a week
apart would get different code.

**Selecting testnet4.** The command-line `--network=testnet4` flag and the
`BITCOIN_NETWORK` environment variable are both read at startup, but a flag file
in the config directory is checked afterwards and overrides them:

```bash
touch ~/.shrike/network-testnet4
```

Verify before doing anything else: a testnet4 receive address starts `tb1`. If
you see `bc1`, you are on mainnet regardless of what you passed on the command
line. Wallet files for a non-mainnet network live under a network subdirectory
(`~/.shrike/testnet4/wallets/`); anything landing in `~/.shrike/wallets/` was
created on mainnet.

Shrike uses its own configuration and data directories, separate from an existing
Sparrow install, so the two can coexist.

One bug is worth knowing about if you're building on a drongo fork of your own,
because it produced a green test suite and a wallet that could not sync: the
PoW hash must commit to the **complete** version word including the v2 flag, not
the stripped value that parsing leaves behind. The same split that makes the
DATUM dashboard read `20000000` applies here — store stripped, hash complete.
The failure is total rather than subtle, so if every header mismatches, look
there first.

**Signing is a different story.** PR #357 introduces `SIGHASH_UNIFIED = 0x20`,
an opt-in per-signature hash type with a BIP341-shaped message that provides
replay protection and commits to input amounts for the older script types that
never got that guarantee.

The catch is hardware. BitBox02 rejects non-`ALL`/`DEFAULT` hash types at the
firmware level. Trezor and Ledger are worse: they sign the legacy message while
the PSBT declares the new one, so it fails verification later as an unexplained
invalid PSBT. Neither is fixable in wallet software.

The practical consequence is that a wallet should decline to opt in unless
**every** keystore is software-held — a single hardware signer in a multisig
quorum means the whole wallet signs the legacy way, because a PSBT declares one
hash type for all signers and a mixed quorum produces signatures that don't
agree.

A wallet also shouldn't opt in purely because it sees a v2 chain tip. A hostile
or intercepted Electrum server can serve a forged difficulty-1 v2 header on
mainnet today; a wallet that treats that as activation will produce signatures
the network rejects as an undefined hash type. Gate on a compiled-in activation
height as well as the tip, and cross-check that height against the connected
node so a stale build declines rather than guesses.

---

## References

- Bitcoin Knots: <https://github.com/bitcoinknots/bitcoin>
- DATUM Gateway, BLAKE2b fork: <https://github.com/justinfilip/datum_gateway>
- DATUM Gateway, upstream: <https://github.com/OCEAN-xyz/datum_gateway>
- cpuminer: <https://github.com/pooler/cpuminer>
- Unified opt-in sighash: [bitcoinknots/bitcoin#357](https://github.com/bitcoinknots/bitcoin/pull/357)
- v2 header fields in RPC: [bitcoinknots/bitcoin#363](https://github.com/bitcoinknots/bitcoin/pull/363)

---

*Corrections welcome. Nothing here is stable until the fork merges.*