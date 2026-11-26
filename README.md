# libphext-bas — BASIC PHEXT

A phext engine for the bassy BASIC dialect (the policy language of
Polyworld / Softmax *Cards and Casters*), mirroring the semantics of
libphext-rs. It parses a genuine phext volume held as text, navigates
by 9D coordinate, selects scrolls, and inscribes/updates scrolls in a
coordinate-addressed store that serializes back to phext text. A
policy built on it *learns within an episode*: it inscribes what it
observes, and its decision parameters drift exponentially toward what
the observations imply.

## The data plane

A hosted policy is a single `.bas` file, or a ZIP package holding
exactly one `.bas` plus data files. The phext volume rides in the
package as a data file for the record, and the same bytes ride inside
the `.bas`, because the source file is the only channel the engine
exposes to the script: bassy has no `DATA`/`READ`/`RESTORE`
statements, so the volume's data lines are string literals.
`phextwrap.py` wraps a volume mechanically — literal runs and
`CHR$` terms, no parsing, no re-encoding — into a `phLoadVolume`
subroutine that concatenates the volume into `phVol$` at setup, byte
for byte the volume file. The library's `phInit` then parses `phVol$`
as phext into the store. bassy's `reset()` runs once before setup and
`restart()` preserves globals across decisions, so the loaded store
carries into the match; nothing persists across episodes (a fresh
BotVm per episode), so the volume is reloaded every match. Offline,
the volume file is a real `.phext`, readable by SQ / libphext-rs
tooling unchanged.

## Coordinates and the store

Phext coordinates are 9D — (library, shelf, series, collection,
volume, book, chapter, section, scroll) — advanced by the dimension
breaks `\x01 \x1F \x1E \x1D \x1C \x1A \x19 \x18 \x17`; a break
increments its dimension (saturating at 999) and resets all lower
dimensions to 1, exactly the reference phext.py walker. bassy arrays
are one-dimensional with a single declared bound, so the store
projects coordinates onto a flat array by mixed-radix packing:
store coordinate `(family, seat, slot, phase)`, index
`((family * 8 + seat) * 16 + slot) * 4 + phase`. Data scrolls live in
the volume's first cell (dimensions 0–4 all 1) and project as
book = phase+1, chapter = family+1, section = seat+1, scroll =
slot+1. A data scroll's payload is a comma/whitespace-separated list
of int32 values; value *k* lands at phase+*k* of its slot. Scrolls
outside the cell are counted (`phForeign`) and skipped — a volume may
carry prose elsewhere.

Families: **0 LEDGER** (exact counts), **1 TENDENCY** (Q16.16
exponential moving averages of observations), **2 PARAMS** (Q16.16
adapted parameters).

## The drift law

Tendencies update per observation as an EWMA,
`E ← (7·E + x) \ 8` (γ = 0.875, exact in integer arithmetic,
~8-observation effective memory), and decay by the same factor per
own turn without confirmation. Parameters drift once per own turn
toward an observation-implied target τ,
`θ ← (7·θ + τ) \ 8`, clamped to `[0.5·θ0, 2·θ0]` — adaptation
modulates within the parent policy's proven envelope, never leaves
it in one episode. The whole adaptation is a deterministic function
of the episode's observed event stream: no floats, no `random()`,
no clock anywhere in the engine.

## bassy constraints the engine is built around

- **The string law** (measured): at most 256 string values may be
  live within one decision; every string-returning host call,
  concatenation, and slice spends one. A policy that drains its
  event log naively dies in a single long window. The CaC binding
  therefore observes under a hard budget of 140 string reads per
  decision, detects its own turn from numeric host data, and prices
  clocks from its ledger instead of scanning boards by name.
  The same budget bounds the setup parse: the text parser spends
  ~1 string value per payload character, so a single-shot setup
  parse supports roughly 220 payload characters (measured: a
  223-byte volume of 32 single-value scrolls parses; 279 bytes
  fails; dense 4-value scrolls: 216 bytes parses, 247 fails). A
  single string caps at 1,024 characters, and all string bytes
  created in one decision cap at 64 KiB cumulative —
  create-and-discard reclaims neither budget mid-decision.
  Larger volumes want incremental parsing across decisions
  (named, not built in generation 0).
- **Numbers**: values are int32 or Q16.16 fixed; `/` always promotes
  to fixed (which rejects integers > 32767), so the engine does all
  arithmetic in int32 with `\` and keeps Q16.16 quantities as raw
  int32 counts of 1/65536.
- **Budgets** (host-enforced): 256 KiB source, 5,000,000
  instructions + 5,000,000 work per decision, 64 MiB VM.

## API

All state lives in `ph`-prefixed globals; operations are `GOSUB`
contracts (see the header of `libphext.bas` for the full list):
`phTextInit`, `phParseVolume`, `phImplode`, `phPack`, `phUnpack`,
`phStep`, `phSelect`, `phReplace`, `phInscribe`, `phEwma`, `phDrift`.
Section 2 of the library is the Cards and Casters binding: the
event-log observer (`phObserve`), the τ rules (`phTurn`), and the
knob reads (`phRead`) for a v33-lineage Mage policy — a spent-card
ledger (Hail copies seen from a seat are a hard bound on remaining
threat), per-seat hail/clock/aggression tendencies, and four drifted
parameters (release band, focus swing/score bonuses, burn band)
whose initial values arrive as volume scrolls, never as code
constants.

## Including it

Concatenate, in order: your policy, `libphext.bas`, and one volume
include providing `phLoadVolume` (phextwrap output;
`phext-data-stub.bas` is an empty one for volume-less use). Your
setup block calls `GOSUB phInit`.

```
python3 phextwrap.py my-volume.phext -o my-volume-inc.bas
cat policy.bas libphext.bas my-volume-inc.bas > policy-built.bas
```

Package form: a ZIP containing the built `.bas` and the `.phext`
volume file itself — the same volume bytes in both forms.

## Tests

`tests/libphext-test.bas` is a harness policy (skeleton + library +
the wrapped fixture volume `tests/test-volume.phext`) that exercises
the text engine and the store API with exact-value assertions —
volume load, parse counts, multi-value scrolls, an
implode → re-parse round-trip, pack/unpack, inscribe/select,
EWMA rise/decay, drift and its clamp, and coordinate navigation.
Run it under the Polyworld headless runner against any stock bot:

```
cac-headless --bot tests/libphext-test.bas --bot warrior.bas \
  --seed 1 --verbose | grep LIBTEST
# LIBTEST DONE pass 18 fail 0
```

## Consumer

`examples/v36-data.phext` is the initial volume of
**v36-phextcore**, a Cards and Casters candidate built on this
library (v33-combined + libphext-bas): four drift parameters and the
data format version, five scrolls, 42 bytes. Its wrapped include is
`examples/v36-data-inc.bas`.

Generation 0. MIT (see LICENSE).
