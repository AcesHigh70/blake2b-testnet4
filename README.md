# Mining the BLAKE2b hardfork on testnet4

A working setup: Bitcoin Knots node, DATUM Gateway, and a miner, all pointed at
testnet4 across the BLAKE2b activation at **height 149460**.

Everything here was verified on a live testnet4 node running
`v29.4.1.knots20260508rc1`. Where something is unverified it says so.

> **Status:** the fork is unmerged and under active review. Branches force-push,
> option names may change, and nothing here should be assumed stable. Check the
> upstream PRs before trusting a detail.

---

## What you need

| Component | Why |
|---|---|
| Bitcoin Knots, BLAKE2b build | Serves block templates and validates. Activation height is compiled in. |
| DATUM Gateway, BLAKE2b build | Turns templates into stratum jobs. Selects the PoW algorithm. |
| A miner | Optional pre-activation. See [Miners](#miners) for the post-activation problem. |

A single Linux box is fine. Disk: testnet4 is ~14 GB as of August 2026, unpruned.

---

## 1. The node

### Which build

The activation height is **hardcoded in the release tag**, not in the base
development branch. This is the single most common way to waste an evening:

- `v29.4.1.knots20260508rc1` — activates on testnet4 at height 149460
- `__base_29_blake2` — sets activation on **regtest only**

If you build the base branch and point it at testnet4, the boundary passes
silently and nothing happens.

There are **no published binaries** for that RC. You must build from source.

```bash
git clone https://github.com/bitcoinknots/bitcoin.git
cd bitcoin
git checkout -b rc1 v29.4.1.knots20260508rc1

cmake -B build-rc1 -DBUILD_GUI=OFF -DRDTS_CONSENT=IMPLICIT \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build build-rc1 -j$(nproc)
```

Build into a named directory rather than `build/` if you also keep a development
branch checked out — the two builds are not interchangeable and mixing them up is
the failure mode described above.

`-DRDTS_CONSENT=IMPLICIT` is required; the RC will not configure without an
explicit RDTS consent value. Drop `-DCMAKE_CXX_COMPILER_LAUNCHER=ccache` if you
don't have ccache installed.

Binaries land in `build-rc1/bin/`.

### Config

`~/testnet4/bitcoin.conf`:

```ini
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

**`blake2b_headline`** — consensus commit `b6b6848a68` requires this string to
appear in the coinbase of the **first BLAKE2b block**. It's a config-file
requirement, not optional plumbing.

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
"subversion": "/Satoshi:29.4.1/Knots:20260508rc1/"
```

and, in `getdeploymentinfo`:

```json
"hardfork": { "height": 149460, "active": false }
```

`hardfork` sits at the **top level**, not inside `deployments` — it is neither a
versionbits nor a buried deployment, so it doesn't appear alongside `csv` and
`segwit`. You'll also see `reduced_data` as a `flagday` deployment at the same
height; that's the RDTS side of the fork landing simultaneously.

If `hardfork` is missing, you have the wrong build. Stop and fix that first.

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
bitcoin-cli ... getblockchaininfo | grep -E 'blocks|initialblockdownload'
```

You want `"initialblockdownload": false`.

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
        "pow_algorithm": "auto",
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

**`pow_algorithm`** — read this carefully; the default may not do what you want.

Valid values are `auto`, `blake2b`, `sha256d`. Default is `auto`.

`auto` stays on SHA256d unless GBT advertises blake2b via one of five signals:
`powalgorithm`, `header_version`, `rules`, `coinbaseaux.blake2b_headline`, or
version bit `0x80000000`. The fork's own README warns that Knots on the blake2b
PoW branch still emits a plain BIP22 template and does **not** send
`powalgorithm` or `xor_key`, and recommends setting `blake2b` explicitly.

That leaves a genuine trade-off:

| Setting | Before 149460 | At 149460 |
|---|---|---|
| `auto` | SHA256d work, ordinary miners fine | Flips **only if** GBT advertises. Otherwise silently keeps issuing SHA256d. |
| `blake2b` | BLAKE2b work against SHA256d templates — SHA256d miners break immediately | Correct |

If you have a BLAKE2b hasher and nothing else, set `blake2b` now and don't think
about it again. If you're running SHA256d hardware up to the boundary, run `auto`
and be ready to restart with `blake2b` at activation. Either way, check your
node's template for those five signals rather than assuming — see
[Capturing the activation](#4-capturing-the-activation).

**`vardiff_min`** — 16384 is right for an ASIC. For a CPU miner set it to `1` or
you will never submit a share. Don't leave it at 1 when you attach real hardware.

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

---

## 3. Miners

### Before activation

Testnet4 is still SHA256d, so ordinary miners work.

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

**Every SHA256d ASIC stops working at 149460.** S19-class hardware is
fixed-function silicon; no firmware update makes it compute BLAKE2b. Expect
rejects or a stall. That transition is itself a clean confirmation the algorithm
switched.

`cpuminer` also stops working. It hashes SHA256d over an 80-byte header; the fork
uses BLAKE2b over a 164-byte v2 header. That's a code change, not a flag.

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

### Shares are not blocks

A share meets the gateway's vardiff target. A block meets the network target.
At `bits: 190295cb` — difficulty ~1.7 billion, roughly 12 PH/s on testnet4 — the
gap is about nine orders of magnitude from a CPU.

The exception is real and worth knowing: testnet4 keeps the 20-minute
min-difficulty rule, so after a slow stretch the next block may be mineable at
difficulty 1. Those windows are genuinely within CPU reach. Check whether you're
in one:

```bash
bitcoin-cli ... getblockchaininfo | grep -E 'bits|difficulty'
```

`"bits": "1d00ffff"` with `"difficulty": 1` means the window is open.

---

## 4. Capturing the activation

Run this before the boundary so you have a record whether or not you're watching.
Use `screen` or `tmux` so it survives a dropped session:

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
      getblocktemplate '{"rules":["segwit"]}' > gbt/$H.json 2>&1
  sleep 20
done
```

Files are named by **tip height**. The template in `<H>.json` is for the block
being built, i.e. height `H+1`. So:

- `gbt/149458.json` → template for 149459, old rules
- `gbt/149459.json` → template for **149460**, first block under the new rules

`hardfork.active` flipping `false` → `true` in the `deploy-*.json` files is your
unambiguous marker, independent of how the template happens to represent the
change.

Note the loop puts the RPC password in `ps` output. Kill it when you're done.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Gateway logs a `DATUM Server MOTD` | `pool_host` isn't `""`. You're pooling. |
| `getblockcount` lower than the template height | Not a reorg. Template height is tip + 1. |
| Dashboard hashrate stuck at `0.00 Th/s` | Display floor is 10 Gh/s. Watch `DiffA`. |
| Miner connects, never submits | `vardiff_min` too high for the hardware. |
| Node serving templates while far behind | IBD guard is skipped on test chains. Check `initialblockdownload`. |
| `Could not locate RPC credentials` | Password auth configured, so no cookie exists. Pass `-rpcuser`/`-stdinrpcpass`. |
| Gateway reads the wrong config after an edit | `-c` is relative to cwd. Use an absolute path. |
| `bind [::1]:PORT` on `ssh -L` | IPv6 unavailable locally. Harmless; the IPv4 forward works. Use `ssh -4`. |

---

## Wallets

Wallet support for this fork is a separate problem from mining, and largely
unsolved. Sparrow-derived wallets need BLAKE2b digest support, 164-byte v2 header
parse/serialize, and PoW verification routed by header version before they can
follow the chain at all.

Separately, PR #357 ("Consensus: Unified opt-in sighash for all transaction
types") introduces `SIGHASH_UNIFIED = 0x20`. Wallets without it keep spending
normally but get no replay protection, and cannot verify or complete PSBTs
carrying an opted-in signature. Hardware signers reject non-`ALL`/`DEFAULT`
sighash types at the firmware level, so that gap is not fixable in wallet
software alone.

---

## References

- Bitcoin Knots: <https://github.com/bitcoinknots/bitcoin>
- DATUM Gateway, BLAKE2b fork: <https://github.com/justinfilip/datum_gateway>
- DATUM Gateway, upstream: <https://github.com/OCEAN-xyz/datum_gateway>
- cpuminer: <https://github.com/pooler/cpuminer>
- Unified opt-in sighash: <https://github.com/bitcoinknots/bitcoin/pull/357>

<!-- TODO: add the PR link for the BLAKE2b PoW change -->

---

*Corrections welcome. Nothing here is stable until the fork merges.*
