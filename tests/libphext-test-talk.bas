' libphext-test-talk.bas - talk.bas test harness.
' A minimal policy skeleton with libphext.bas and talk.bas
' concatenated after it (the include-by-concatenation contract).
' Run under the Polyworld headless runner against any stock bot
' with --verbose:
'   cac-headless --bot libphext-test-talk.bas --bot warrior.bas \
'     --seed 1 --verbose | grep TALKTEST
' Every assertion prints TALKTEST <id> PASS or FAIL with values.
' The harness plays no game: it ends its turns; assertions run on
' its first two decisions (both main decisions in a fresh match).
IF selectingClass THEN
  pickClass(1)
  deckCard("Bear", 4)
  deckCard("Swords", 4)
  deckCard("Shields", 4)
  deckCard("Duel", 4)
  deckCard("Tactician", 4)
  deckCard("Footsoldier", 4)
  deckCard("Commander", 4)
  deckCard("Rally", 4)
  deckCard("Banner", 4)
  deckCard("Pillage", 4)
  END
END IF

IF ttPhase = 0 THEN
  ttPhase = 1
  phStrLeft = 100000
  GOSUB tkInit
  ' P1: a well-formed OFFER parses into its five fields.
  tkMsg$ = "PX 1 3 1 12 1"
  GOSUB tkParse
  ttId$ = "P1-parse-offer"
  ttGot = tkOk * 1000000 + tkV * 10000 + tkS * 1000 + tkX * 100 + tkY * 10 + tkZ
  ttWant = 1013221
  GOSUB ttCheck
  ' P2: a negative field parses (ACCEPT with no agreed target).
  tkMsg$ = "PX 2 0 1 10 -1"
  GOSUB tkParse
  ttId$ = "P2-parse-negative"
  ttGot = tkOk * 100 + tkZ
  ttWant = 99
  GOSUB ttCheck
  ' P3: malformed input is rejected, never faulted: truncated,
  ' foreign text, and an over-long token list all fail the parse
  ' (tkOk = 0 for each).
  tkMsg$ = "PX 9 0"
  GOSUB tkParse
  ttOk1 = tkOk
  tkMsg$ = "hello world"
  GOSUB tkParse
  ttOk2 = tkOk
  tkMsg$ = "PX 1 2 3 4 5 6"
  GOSUB tkParse
  ttId$ = "P3-parse-malformed"
  ttGot = ttOk1 * 100 + ttOk2 * 10 + tkOk
  ttWant = 0
  GOSUB ttCheck
  ' S1: TALK store put/get/inc round trip (fam 3, seat 2, slot 4).
  tkSF = 3
  tkSS = 2
  tkSL = 4
  tkSP = 1
  tkSV = 4242
  GOSUB tkPut
  tkSV = 0
  GOSUB tkGet
  GOSUB tkInc
  GOSUB tkInc
  GOSUB tkGet
  ttId$ = "S1-store-roundtrip"
  ttGot = tkSV
  ttWant = 4244
  GOSUB ttCheck
  ' S2: trust lifecycle at seat 2 - init, one EWMA toward full,
  ' zeroed.
  tkSS = 2
  GOSUB tkTrustRead
  ttId$ = "S2a-trust-init"
  ttGot = tkTrustV
  ttWant = 32768
  GOSUB ttCheck
  tkTau = 65536
  GOSUB tkTrustEwma
  GOSUB tkTrustRead
  ttId$ = "S2b-trust-ewma"
  ttGot = tkTrustV
  ttWant = 36864
  GOSUB ttCheck
  GOSUB tkTrustZero
  GOSUB tkTrustRead
  ttId$ = "S2c-trust-zero"
  ttGot = tkTrustV
  ttWant = 0
  GOSUB ttCheck
  ' M1: a DM to our own inbox is a legal send (sendChat to
  ' mailboxSelf) and is counted.
  tkTo = mailboxSelf()
  tkText$ = "PX 5 0 2 8 3"
  GOSUB tkSendText
  ttId$ = "M1-send-self-dm"
  ttGot = tkTotalSent
  ttWant = 1
  GOSUB ttCheck
END IF
IF ttPhase = 1 THEN
  ttPhase = 2
  ' M2: the self-DM drains through the real mailbox and parses
  ' clean. (The handler deliberately ignores own traffic -
  ' tkFrom = selfPlayer returns before any handler - so the
  ' assertions are: inbox empty after the drain, and no parse
  ' failure recorded. Handler transitions are proven against
  ' the scripted personas in the table proof.)
  GOSUB tkDrain
  ttId$ = "M2-mailbox-roundtrip"
  ttGot = mailboxCount() * 10 + tkParseFail
  ttWant = 0
  GOSUB ttCheck
  PRINT "TALKTEST SUMMARY failures="; ttFails
END IF
endTurn()
END

ttCheck:
IF ttGot = ttWant THEN
  PRINT "TALKTEST "; ttId$; " PASS"
ELSE
  PRINT "TALKTEST "; ttId$; " FAIL got="; ttGot; " want="; ttWant
  ttFails = ttFails + 1
END IF
RETURN

' ==== LIBPHEXT-BAS INCLUDE BEGIN (verbatim libphext.bas) ====
' =====================================================================
' libphext-bas - BASIC PHEXT (generation 1: + chunked volumes,
' incremental parsing across decisions, phReadBase)
' A phext engine for the bassy BASIC dialect (Polyworld / Softmax
' Cards and Casters policies), mirroring libphext-rs semantics.
' The engine works on a genuine phext volume held as TEXT: it
' parses the volume's scroll delimiters and 9D coordinates,
' navigates by coordinate, selects scrolls, and inscribes/updates
' scrolls in a coordinate-addressed store that serializes back to
' phext text (phImplode). Offline, the same volume file is read by
' SQ / libphext-rs tooling unchanged - it is a real .phext, not a
' BASIC-specific shadow of one.
'
' THE DATA PLANE (how the volume reaches the BASIC environment).
' A policy ships as one .bas file, or as a ZIP package holding
' exactly one .bas plus data files; the .phext volume rides in
' the package as a data file for the record, and the SAME BYTES
' ride inside the .bas, because the source file is the only
' channel the engine exposes to the script. bassy 0.1.0 has no
' DATA / READ / RESTORE statements (its keyword table contains
' none of them), so the volume's data lines are string literals:
' phextwrap (in this repo) splits the volume mechanically into
' literal runs and CHR$ terms - no parsing, no re-encoding - and
' emits a phLoadVolume subroutine that concatenates them into
' phVol$ at setup, byte for byte the volume file. bassy reset()
' runs once before setup and restart() preserves globals across
' decisions, so the loaded volume and the store built from it
' carry into the match. Nothing persists across episodes (a
' fresh BotVm per episode): the volume is reloaded every match.
'
' THE STRING LAW (measured on the local runner, stated for
' consumers): at most 256 string values and 64 KiB of string
' bytes exist per runtime, 1,024 chars per string. TRANSIENT
' strings are reclaimed at restart() - bassy.nim's restart
' gathers the roots and compacts the pool (texts.nim reset) -
' so each decision starts with the pool minus its roots.
' ROOTED strings are the per-episode consumable: string
' globals, string array cells, and every materialized literal
' persist for the whole episode and shrink every later
' decision's headroom (probe, EE ~950: 180 literals evaluated
' at setup plus 100 creations on decision 1 dies with "BASIC
' string count limit exceeded"; 200 transient slices on each
' of 11 decisions lives). Consequences: the in-match observer
' (section 2) drains the event log under a hard budget of
' string reads per decision (140 by default; phInit lowers it
' for chunked volumes - see phObsBudget), phImplode is a
' setup/harness tool, never an in-match call, and a chunked
' volume spends exactly ONE literal per chunk.
' The parse itself spends about one string value per payload
' character (MID$+ASC is the dialect's only character access),
' so a single-shot setup parse supports roughly 220 payload
' characters inside the 256 budget - measured: 223-byte volume
' of 32 single-value scrolls parses, 279 bytes fails; 216 bytes
' of dense 4-value scrolls parses, 247 fails. A single string
' also caps at 1024 characters, and all string bytes created in
' one decision cap at 64 KiB cumulative - create-and-discard
' does not reclaim either budget mid-decision (all measured).
'
' CHUNKED VOLUMES AND INCREMENTAL PARSING (generation 1). A
' volume too large for one string rides as CHUNKS: phextwrap
' --chunked emits a phLoadVolume that sets phChunked = 1 and
' phChunkN and assigns one literal per chunk into phChunk$()
' (fixed <= 1000-char slices of the volume - the walker is a
' resumable byte stream, so a chunk boundary may fall
' mid-scroll, mid-token, or mid-break-run without changing
' the parse - and each chunk is one materialized literal,
' one rooted span per chunk). phInit
' then runs phParseReset and a first phParseStep inside the
' setup invocation (budget 170; 48 when phInit is reached
' lazily at a decision, where selectingClass = 0), and
' phObserve spends up to 32 more string creations per decision
' on phParseStep until phPxDone. Walker state (coordinate,
' chunk, offset, tokenizer) lives in globals, which restart()
' preserves, so the parse resumes exactly where it stopped.
' Data-cell scrolls are fed char by char; foreign (prose)
' scrolls are skipped by INSTR position at zero string cost.
' Order the volume so the data cell comes first (canonical
' coordinate order does): parameters land in the setup step.
' The embeddable ceiling is now set by the rooted budget -
' chunks + code literals + break strings must leave the
' observer and the parse step their per-decision headroom;
' 24 chunks x 1000 chars plus full observer load is
' probe-verified, and phInit's adaptive phObsBudget
' (149 - phChunkN, floored at 60, capped at 140) keeps the
' worst-case decision inside 256 by construction.
'
' COORDINATES AND THE STORE. Phext coordinates are 9D:
' (library, shelf, series, collection, volume, book, chapter,
' section, scroll), each 1..999, advanced by dimension breaks
' \x01 \x1F \x1E \x1D \x1C \x1A \x19 \x18 \x17 (dimensions 0..8);
' a break increments its dimension (saturating at 999) and
' resets all lower dimensions to 1 - the reference phext.py
' walker semantics, mirrored exactly. bassy arrays are
' one-dimensional with a single declared bound, so the store
' projects coordinates onto a flat array by mixed-radix packing:
'   store coordinate = (family, seat, slot, phase)
'   index = ((family * 8 + seat) * 16 + slot) * 4 + phase
' Data scrolls live in the volume's first cell (dimensions 0..4
' all 1) and project as: book = phase+1, chapter = family+1,
' section = seat+1, scroll = slot+1. Scrolls outside the cell
' are counted (phForeign) and skipped - a volume may carry prose
' elsewhere; the store holds the data cell. A data scroll's
' payload is a comma/whitespace-separated list of int32 values;
' value k lands at phase+k of its slot. The three families are
' the store's scroll classes:
'   0 LEDGER    exact integer counts (inscribe-only growth)
'   1 TENDENCY  Q16.16 exponential moving averages
'   2 PARAMS    Q16.16 adapted parameters (the drift law)
'
' NUMBERS. bassy values are int32 or Q16.16 fixed; '/' always
' promotes to fixed (which rejects integers > 32767), so the
' core does ALL arithmetic in int32 with '\' (division toward
' zero) and keeps Q16.16 quantities as raw int32 counts of
' 1/65536. No floats, no random(), no clock in the engine: every
' update is a deterministic function of the observed events.
'
' DRIFT LAW. Tendencies update per observation as an EWMA,
'   E <- (7*E + x) \ 8        (gamma = 0.875, x in {0, 65536})
' and decay by the same factor per own turn without
' confirmation. Parameters drift once per own turn toward a
' target tau, theta <- (7*theta + tau) \ 8, clamped to
' caller-supplied [phLo, phHi] - by convention
' [0.5*theta0, 2*theta0], the parent policy's proven envelope.
'
' API (all state in ph-prefixed globals; GOSUB contracts):
'   phTextInit   build the dimension-break strings
'   phParseVolume  parse phVol$ (phext text) into the store
'   phParseReset   zero the incremental-parse walker state
'   phParseStep    parse a bounded slice of the chunked volume
'                  (caller sets phParseBudget; state persists
'                  across decisions in globals)
'   phImplode    serialize the store's data cell to phOut$
'   phPack     (phFam, phSeat, phSlot, phPhase) -> phIdx
'   phUnpack   phIdx -> (phFam, phSeat, phSlot, phPhase)
'   phStep     phIdx += phDelta, then unpack (navigation)
'   phSelect   packed coord -> phVal = store value
'   phReplace  store phVal at packed coord
'   phInscribe ledger-style increment at packed coord
'   phEwma     tendency update at packed coord toward phX
'   phDrift    param at packed coord drifts toward phTau,
'              clamped to [phLo, phHi]
' INCLUDE CONTRACT: a policy concatenates, in order, its own
' code, this library, and ONE volume include providing
' phLoadVolume (phextwrap output; this repo also ships an empty
' stub for volume-less use). The binding's phInit calls
' phLoadVolume, then phParseVolume - or, when the include is
' a chunked one (phChunked = 1), phParseReset + phParseStep.
' =====================================================================

DIM phStore(2047)
DIM phCoord(8)
DIM phChunk$(63)

' ==== SECTION 1: CORE - STORE ====

phPack:
phIdx = ((phFam * 8 + phSeat) * 16 + phSlot) * 4 + phPhase
RETURN

phUnpack:
phPhase = phIdx MOD 4
phTmp = phIdx \ 4
phSlot = phTmp MOD 16
phTmp = phTmp \ 16
phSeat = phTmp MOD 8
phFam = phTmp \ 8
RETURN

phStep:
phIdx = phIdx + phDelta
GOSUB phUnpack
RETURN

phSelect:
GOSUB phPack
phVal = phStore(phIdx)
RETURN

phReplace:
GOSUB phPack
phStore(phIdx) = phVal
RETURN

phInscribe:
GOSUB phPack
phStore(phIdx) = phStore(phIdx) + 1
RETURN

phEwma:
GOSUB phPack
phStore(phIdx) = (7 * phStore(phIdx) + phX) \ 8
RETURN

phDrift:
GOSUB phPack
phNew = (7 * phStore(phIdx) + phTau) \ 8
IF phNew < phLo THEN phNew = phLo
IF phNew > phHi THEN phNew = phHi
phStore(phIdx) = phNew
RETURN

' ==== SECTION 1: CORE - PHEXT TEXT ENGINE ====

phTextInit:
' Dimension breaks 0..8 (library..scroll), as one-char strings.
phBrk0$ = CHR$(1)
phBrk1$ = CHR$(31)
phBrk2$ = CHR$(30)
phBrk3$ = CHR$(29)
phBrk4$ = CHR$(28)
phBrk5$ = CHR$(26)
phBrk6$ = CHR$(25)
phBrk7$ = CHR$(24)
phBrk8$ = CHR$(23)
RETURN

phBreakFor:
' phDim -> phBrk$ (the break string for that dimension).
phBrk$ = phBrk0$
IF phDim = 1 THEN phBrk$ = phBrk1$
IF phDim = 2 THEN phBrk$ = phBrk2$
IF phDim = 3 THEN phBrk$ = phBrk3$
IF phDim = 4 THEN phBrk$ = phBrk4$
IF phDim = 5 THEN phBrk$ = phBrk5$
IF phDim = 6 THEN phBrk$ = phBrk6$
IF phDim = 7 THEN phBrk$ = phBrk7$
IF phDim = 8 THEN phBrk$ = phBrk8$
RETURN

phParseVolume:
' Walk phVol$ as phext: each maximal run of non-break text is a
' scroll at the current 9D coordinate (starting at all 1s);
' breaks between runs advance the coordinate. Data-cell scrolls
' are projected and stored by phScrollIn; others are counted in
' phForeign. Sets phScrolls (stored scrolls) and phParseErr
' (bad payload tokens / phase overruns).
phScrolls = 0
phForeign = 0
phParseErr = 0
phD = 0
WHILE phD < 9
  phCoord(phD) = 1
  phD = phD + 1
WEND
phLen = LEN(phVol$)
phPos = 1
WHILE phPos <= phLen
  phNext = 0
  phNextDim = -1
  phDim = 0
  WHILE phDim < 9
    GOSUB phBreakFor
    phP = INSTR(phPos, phVol$, phBrk$)
    IF phP > 0 AND (phNext = 0 OR phP < phNext) THEN
      phNext = phP
      phNextDim = phDim
    END IF
    phDim = phDim + 1
  WEND
  IF phNext = 0 THEN phRunEnd = phLen + 1
  IF phNext > 0 THEN phRunEnd = phNext
  IF phRunEnd > phPos THEN
    phText$ = MID$(phVol$, phPos, phRunEnd - phPos)
    GOSUB phScrollIn
  END IF
  IF phNext = 0 THEN
    phPos = phLen + 1
  ELSE
    IF phCoord(phNextDim) + 1 < 1000 THEN phCoord(phNextDim) = phCoord(phNextDim) + 1
    phD = phNextDim + 1
    WHILE phD < 9
      phCoord(phD) = 1
      phD = phD + 1
    WEND
    phPos = phNext + 1
  END IF
WEND
RETURN

phScrollIn:
' One scroll's text (phText$) at the walker's 9D coordinate.
' Outside the data cell: count and skip. Inside: capture the
' projection, feed the payload's characters through the shared
' tokenizer (phFeedCh), and flush the final token.
GOSUB phPxGateFromCoord
IF phPxForeign = 1 THEN
  phForeign = phForeign + 1
  RETURN
END IF
phScrolls = phScrolls + 1
phTokV = 0
phTokSgn = 1
phTokOn = 0
phTokDig = 0
phTokBad = 0
phK = 0
phI = 1
WHILE phI <= LEN(phText$)
  phCh = ASC(MID$(phText$, phI, 1))
  GOSUB phFeedCh
  phI = phI + 1
WEND
phCh = 32
GOSUB phFeedCh
RETURN

phPxGateFromCoord:
' The data-cell test, shared by phScrollIn and the incremental
' walker: sets phPxForeign, and on a data scroll captures the
' projection (phPxFam, phPxSeat, phPxSlot, phPxPhase0) from the
' walker's current coordinate phCoord.
phPxForeign = 0
IF phCoord(0) <> 1 OR phCoord(1) <> 1 OR phCoord(2) <> 1 OR phCoord(3) <> 1 OR phCoord(4) <> 1 THEN phPxForeign = 1
IF phPxForeign = 0 THEN
  phPxFam = phCoord(6) - 1
  phPxSeat = phCoord(7) - 1
  phPxSlot = phCoord(8) - 1
  phPxPhase0 = phCoord(5) - 1
  IF phPxFam < 0 OR phPxFam > 2 OR phPxSeat < 0 OR phPxSeat > 7 OR phPxSlot < 0 OR phPxSlot > 15 OR phPxPhase0 < 0 OR phPxPhase0 > 3 THEN phPxForeign = 1
END IF
RETURN

phFeedCh:
' One payload character (phCh, an ASC code) for the scroll
' whose projection was captured in phPxFam / phPxSeat /
' phPxSlot / phPxPhase0. Separators (space, comma, tab, LF,
' CR) close the current token; digits and a leading minus
' build it; anything else marks it bad.
IF phCh = 32 OR phCh = 44 OR phCh = 9 OR phCh = 10 OR phCh = 13 THEN
  IF phTokOn = 1 THEN
    GOSUB phFlushTok
    phK = phK + 1
    phTokV = 0
    phTokSgn = 1
    phTokOn = 0
    phTokDig = 0
    phTokBad = 0
  END IF
ELSE
  phTokOn = 1
  IF phCh >= 48 AND phCh <= 57 THEN
    phTokV = phTokV * 10 + phCh - 48
    phTokDig = phTokDig + 1
  ELSE
    IF phCh = 45 AND phTokDig = 0 AND phTokV = 0 THEN
      phTokSgn = -1
    ELSE
      phTokBad = 1
    END IF
  END IF
END IF
RETURN

phFlushTok:
' Store the finished token at phase (phPxPhase0 + phK) of the
' captured projection, or count it as a parse error (bad
' token, no digits, or a phase overrun past phase 3).
IF phTokBad = 1 OR phTokDig = 0 THEN
  phParseErr = phParseErr + 1
  RETURN
END IF
phFam = phPxFam
phSeat = phPxSeat
phSlot = phPxSlot
phPhase = phPxPhase0 + phK
IF phPhase > 3 THEN
  phParseErr = phParseErr + 1
  RETURN
END IF
phVal = phTokSgn * phTokV
GOSUB phReplace
RETURN

phImplode:
' Serialize the store's data cell back to phext text in phOut$:
' one scroll per (family, seat, slot) holding a nonzero value,
' in coordinate order, payload = the phase run from phase 0 to
' the last nonzero phase, comma-separated. A stored 0 reads as
' an absent scroll, so implode emits nonzero scrolls only.
' Setup/harness tool: it builds strings; do not call in-match.
phOut$ = ""
phD = 0
WHILE phD < 9
  phCoord(phD) = 1
  phD = phD + 1
WEND
phFam = 0
WHILE phFam < 3
  phSeat = 0
  WHILE phSeat < 8
    phSlot = 0
    WHILE phSlot < 16
      phLastNz = -1
      phPhase = 0
      WHILE phPhase < 4
        GOSUB phSelect
        IF phVal <> 0 THEN phLastNz = phPhase
        phPhase = phPhase + 1
      WEND
      IF phLastNz >= 0 THEN
        ' Advance the walker to (1,1,1, 1,1,1, fam+1, seat+1,
        ' slot+1): only dimensions 6..8 ever move.
        phT6 = phFam + 1
        phT7 = phSeat + 1
        phT8 = phSlot + 1
        WHILE phCoord(6) < phT6
          phDim = 6
          GOSUB phBreakFor
          phOut$ = phOut$ + phBrk$
          phCoord(6) = phCoord(6) + 1
          phCoord(7) = 1
          phCoord(8) = 1
        WEND
        WHILE phCoord(7) < phT7
          phDim = 7
          GOSUB phBreakFor
          phOut$ = phOut$ + phBrk$
          phCoord(7) = phCoord(7) + 1
          phCoord(8) = 1
        WEND
        WHILE phCoord(8) < phT8
          phDim = 8
          GOSUB phBreakFor
          phOut$ = phOut$ + phBrk$
          phCoord(8) = phCoord(8) + 1
        WEND
        phPay$ = ""
        phPhase = 0
        WHILE phPhase <= phLastNz
          GOSUB phSelect
          IF phPhase > 0 THEN phPay$ = phPay$ + ","
          phPay$ = phPay$ + TRIM$(STR$(phVal))
          phPhase = phPhase + 1
        WEND
        phOut$ = phOut$ + phPay$
      END IF
      phSlot = phSlot + 1
    WEND
    phSeat = phSeat + 1
  WEND
  phFam = phFam + 1
WEND
RETURN

' ==== SECTION 1: CORE - INCREMENTAL PARSE (CHUNKED VOLUMES) ====
' The walker below reads the chunked volume (phChunk$ /
' phChunkN, filled by a phextwrap --chunked include) with the
' same coordinate semantics as phParseVolume, a bounded slice
' per call. State lives in globals (phPxChunk, phPxOff,
' phPxState, phCoord, the tokenizer globals), so a parse
' interrupted by the end of a decision resumes exactly where
' it stopped at the next one. Costs: one string creation per
' data-payload character fed (MID$), zero for foreign scrolls
' (skipped by INSTR position) and zero for breaks.

phParseReset:
' Zero the walker: coordinate back to all 1s, cursor at the
' first chunk, counters cleared.
phScrolls = 0
phForeign = 0
phParseErr = 0
phD = 0
WHILE phD < 9
  phCoord(phD) = 1
  phD = phD + 1
WEND
phPxChunk = 0
phPxOff = 0
phPxState = 0
phPxDone = 0
phPxMore = 0
phParsedChars = 0
phTokV = 0
phTokSgn = 1
phTokOn = 0
phTokDig = 0
phTokBad = 0
phK = 0
RETURN

phParseStep:
' Parse until phParseBudget string creations are spent, the
' volume is exhausted (phPxDone = 1), or 24 runs were handled
' (a work bound, so a step is bounded even where foreign
' scrolls cost no strings). Caller sets phParseBudget.
phSpent = 0
phPxRuns = 0
WHILE phSpent < phParseBudget AND phPxDone = 0 AND phPxRuns < 24
  IF phPxState = 0 THEN
    GOSUB phPxScan
  ELSE
    GOSUB phPxFeed
  END IF
WEND
RETURN

phPxScan:
' State 0 (between runs): advance past an exhausted chunk, a
' break sitting at the cursor (coordinate advance, no string
' cost), or position on the next run - foreign runs are
' skipped by position, data runs capture their projection
' and switch to state 1.
IF phPxOff >= LEN(phChunk$(phPxChunk)) THEN
  phPxChunk = phPxChunk + 1
  phPxOff = 0
  IF phPxChunk >= phChunkN THEN phPxDone = 1
  RETURN
END IF
GOSUB phPxFindBrk
IF phNext = phPxOff + 1 THEN
  IF phCoord(phNextDim) + 1 < 1000 THEN phCoord(phNextDim) = phCoord(phNextDim) + 1
  phD = phNextDim + 1
  WHILE phD < 9
    phCoord(phD) = 1
    phD = phD + 1
  WEND
  phPxOff = phPxOff + 1
  RETURN
END IF
phPxMore = 0
IF phNext = 0 THEN phPxRunEnd = LEN(phChunk$(phPxChunk))
IF phNext = 0 AND phPxChunk < phChunkN - 1 THEN phPxMore = 1
IF phNext > 0 THEN phPxRunEnd = phNext - 1
phPxRuns = phPxRuns + 1
GOSUB phPxGateFromCoord
IF phPxForeign = 1 THEN
  WHILE phPxMore = 1
    GOSUB phPxExtend
  WEND
  phForeign = phForeign + 1
  phPxOff = phPxRunEnd
  RETURN
END IF
phScrolls = phScrolls + 1
phTokV = 0
phTokSgn = 1
phTokOn = 0
phTokDig = 0
phTokBad = 0
phK = 0
phPxState = 1
RETURN

phPxFeed:
' State 1 (inside a data run): feed characters until the
' step's budget is spent or the run ends; at the run's end,
' flush the final token and return to state 0.
WHILE phPxOff < phPxRunEnd AND phSpent < phParseBudget
  phCh = ASC(MID$(phChunk$(phPxChunk), phPxOff + 1, 1))
  phSpent = phSpent + 1
  phParsedChars = phParsedChars + 1
  GOSUB phFeedCh
  phPxOff = phPxOff + 1
WEND
IF phPxOff >= phPxRunEnd THEN
  IF phPxMore = 1 THEN
    GOSUB phPxExtend
  ELSE
    phCh = 32
    GOSUB phFeedCh
    phPxState = 0
  END IF
END IF
RETURN

phPxFindBrk:
' The earliest dimension break in the current chunk at or
' after the cursor: phNext = its 1-based position (0 = none),
' phNextDim = its dimension.
phNext = 0
phNextDim = -1
phDim = 0
WHILE phDim < 9
  GOSUB phBreakFor
  phP = INSTR(phPxOff + 1, phChunk$(phPxChunk), phBrk$)
  IF phP > 0 AND (phNext = 0 OR phP < phNext) THEN
    phNext = phP
    phNextDim = phDim
  END IF
  phDim = phDim + 1
WEND
RETURN

phPxExtend:
' The current run reaches the end of a chunk and continues
' into the next: advance the chunk and recompute the run's
' end there, WITHOUT flushing - the tokenizer state carries
' across the boundary, even mid-token.
phPxChunk = phPxChunk + 1
phPxOff = 0
GOSUB phPxFindBrk
phPxMore = 0
IF phNext = 0 THEN phPxRunEnd = LEN(phChunk$(phPxChunk))
IF phNext = 0 AND phPxChunk < phChunkN - 1 THEN phPxMore = 1
IF phNext > 0 THEN phPxRunEnd = phNext - 1
RETURN

' ==== SECTION 2: CARDS AND CASTERS BINDING ====
' Scroll map for this binding:
'   ledger slots: 0 Hail of Arrows, 1 Post, 2 Overwork, 3 Bubble,
'     4 Sharpshooter, 5 Sniper, 6 Burnout (summons, by owner),
'     7 Plan, 8 Study - counted per seat from play/discard events.
'     Hail seen is a hard bound: a deck holds at most 4 copies,
'     so remaining Hail = 4 - seen.
'   tendency slots: 0 hail, 1 clock, 2 aggression - per seat,
'     phase-indexed (phase of turn: <=4 -> 0, 5..9 -> 1, >=10 -> 2).
'   param slots (seat 0, phase 0): 0 release band (theta0 8),
'     1 focus swing bonus (theta0 3), 2 focus score bonus
'     (theta0 2), 3 burn discount band (theta0 4) - these four
'     arrive as DATA: the policy's volume carries them as
'     scrolls, phInit loads them, the code names no constants.
'     Param slot 15 holds the data format version.
'   baseline extension (generation 1, read by phReadBase):
'     param slots (seat 0, phase 0): 4 focus weight wP (2),
'     5 focus weight wC (1), 6 focus weight wH (2), 7 deck
'     Hail copies (4 - the ledger threat bound), 9 overflow
'     release count (7), 10 composition shift compRel (2),
'     11 composition shift compFoc (1). Slot 8 documents the
'     drift gamma (0.875, Q16.16); the law itself is code.
' The host policy reads the thetas each decision via phRead into
' relBand, focSwingB, focScoreB, burnBand.

phPhaseSet:
phPhase = 0
IF phTurnN >= 5 THEN phPhase = 1
IF phTurnN >= 10 THEN phPhase = 2
RETURN

phInit:
' Load the volume (phLoadVolume, from the policy's data
' include) and parse it into the store. Called from the host's
' setup block - bassy reset() runs once before setup, so the
' loaded store carries into the match - or lazily at the first
' decision when the seat's setup never ran (classes-override
' rosters). A chunked include (phChunked = 1) parses
' incrementally: a first step here (budget 170 at setup, where
' this invocation is its own generation; 48 when reached
' lazily inside a decision), the rest inside phObserve.
phReady = 1
GOSUB phTextInit
GOSUB phLoadVolume
IF phChunked = 1 THEN
  phObsBudget = 149 - phChunkN
  IF phObsBudget < 60 THEN phObsBudget = 60
  IF phObsBudget > 140 THEN phObsBudget = 140
  GOSUB phParseReset
  phParseBudget = 48
  IF selectingClass THEN phParseBudget = 170
  GOSUB phParseStep
ELSE
  phObsBudget = 140
  GOSUB phParseVolume
END IF
RETURN

phRead:
phFam = 2
phSeat = 0
phPhase = 0
phSlot = 0
GOSUB phSelect
relBand = (phVal + 32768) \ 65536
phSlot = 1
GOSUB phSelect
focSwingB = (phVal + 32768) \ 65536
phSlot = 2
GOSUB phSelect
focScoreB = (phVal + 32768) \ 65536
phSlot = 3
GOSUB phSelect
burnBand = (phVal + 32768) \ 65536
RETURN

phReadBase:
' Baseline binding extension: the generation-1 PARAMS (seat 0,
' phase 0, slots 4..11) the baseline policy consults beside
' phRead's four thetas - the scored-focus weights (D4), the
' ledger Hail bound, the overflow release count (D14), and the
' composition shifts (D29). All Q16.16, rounded like phRead.
phFam = 2
phSeat = 0
phPhase = 0
phSlot = 4
GOSUB phSelect
focWP = (phVal + 32768) \ 65536
phSlot = 5
GOSUB phSelect
focWC = (phVal + 32768) \ 65536
phSlot = 6
GOSUB phSelect
focWH = (phVal + 32768) \ 65536
phSlot = 7
GOSUB phSelect
hailCopies = (phVal + 32768) \ 65536
phSlot = 9
GOSUB phSelect
releaseN = (phVal + 32768) \ 65536
phSlot = 10
GOSUB phSelect
compRel = (phVal + 32768) \ 65536
phSlot = 11
GOSUB phSelect
compFoc = (phVal + 32768) \ 65536
RETURN

phObserve:
' First, a slice of the incremental parse (chunked volumes
' only): up to 32 string creations, so the data cell completes
' over the match's first decisions while the drain keeps its
' own budget. Then drain the event log since our last
' decision, oldest first, inscribing observations at their
' coordinates, under the string budget (phObsBudget
' string-returning host calls this decision - 140 by default,
' lowered by phInit for chunked volumes; see the string law
' in the header). Events past the budget are skipped and
' counted in phSkipped: the mechanism degrades in monster
' windows; it never dies there.
IF phChunked = 1 AND phPxDone = 0 THEN
  phParseBudget = 32
  GOSUB phParseStep
END IF
phStrLeft = phObsBudget
phEv = 0
WHILE phEv < logCount()
  IF phStrLeft <= 0 THEN
    phSkipped = phSkipped + logCount() - phEv
    phEv = logCount()
  ELSE
    phKind$ = logKind$(phEv)
    phStrLeft = phStrLeft - 1
    phActor = logPlayer(phEv)
    IF phKind$ = "play" OR phKind$ = "discard" THEN
      IF phStrLeft > 0 THEN
        phCard$ = logCard$(phEv)
        phStrLeft = phStrLeft - 1
        phSeat = phActor
        GOSUB phLedger
      END IF
    END IF
    IF phKind$ = "summon" THEN
      IF phStrLeft > 0 THEN
        phCard$ = logCard$(phEv)
        phStrLeft = phStrLeft - 1
        IF phCard$ = "Burnout" THEN
          phSeat = logOwner(phEv)
          phFam = 0
          phSlot = 6
          phPhase = 0
          GOSUB phInscribe
          phTurnN = logTurn(phEv)
          GOSUB phPhaseSet
          phFam = 1
          phSlot = 1
          phX = 65536
          GOSUB phEwma
        END IF
      END IF
    END IF
    IF phKind$ = "attack" AND phActor <> selfPlayer THEN
      IF logTargetCount(phEv) > 0 THEN
        IF logTargetKind(phEv, 0) = 2 AND logTargetOwner(phEv, 0) = selfPlayer THEN
          phSeat = phActor
          phTurnN = logTurn(phEv)
          GOSUB phPhaseSet
          phFam = 1
          phSlot = 2
          phX = 65536
          GOSUB phEwma
        END IF
      END IF
    END IF
    phEv = phEv + 1
  END IF
WEND
' Own-turn drift step, detected from numeric host data alone:
' exactly one step per own turn, immune to drain truncation.
IF currentPlayer = selfPlayer AND turnNumber > phLastMine THEN
  phLastMine = turnNumber
  GOSUB phTurn
END IF
RETURN

phLedger:
' One seen copy of phCard$ from seat phSeat (a play or a discard):
' the ledger counts it; Hail also feeds the hail tendency.
phSlot = -1
IF phCard$ = "Hail of Arrows" THEN phSlot = 0
IF phCard$ = "Post" THEN phSlot = 1
IF phCard$ = "Overwork" THEN phSlot = 2
IF phCard$ = "Bubble" THEN phSlot = 3
IF phCard$ = "Sharpshooter" THEN phSlot = 4
IF phCard$ = "Sniper" THEN phSlot = 5
IF phCard$ = "Plan" THEN phSlot = 7
IF phCard$ = "Study" THEN phSlot = 8
IF phSlot < 0 THEN RETURN
phFam = 0
phPhase = 0
GOSUB phInscribe
IF phSlot = 0 THEN
  phTurnN = logTurn(phEv)
  GOSUB phPhaseSet
  phFam = 1
  phSlot = 0
  phX = 65536
  GOSUB phEwma
END IF
RETURN

phTurn:
' Own turn start: decay every tendency prior x7/8 (an index sweep
' over the tendency family's coordinate block, via phStep), then
' drift each theta once toward its observation-implied target.
' All reads are numeric or from the store: no string host calls.
phIdx = 512
WHILE phIdx <= 970
  phStore(phIdx) = (7 * phStore(phIdx)) \ 8
  phDelta = 1
  GOSUB phStep
WEND
phTurnN = turnNumber
GOSUB phPhaseSet
phCurPhase = phPhase
phFocus = -1
phFocusLife = -1
phTp = 0
WHILE phTp < playerCount
  IF phTp <> selfPlayer AND playerDead(phTp) = 0 THEN
    IF playerLife(phTp) > phFocusLife THEN
      phFocusLife = playerLife(phTp)
      phFocus = phTp
    END IF
  END IF
  phTp = phTp + 1
WEND
' Clock totals from the ledger (summons by owner seat).
phLedTot = 0
phSeat = 0
WHILE phSeat < playerCount
  phFam = 0
  phSlot = 6
  phPhase = 0
  GOSUB phSelect
  phLedTot = phLedTot + phVal
  IF phSeat = selfPlayer THEN phBurnMe = phVal
  phSeat = phSeat + 1
WEND
' tau: release band. 12 when our own clock has started (ledger:
' a Burnout we own exists - it never expires), 10 under observed
' aggression pressure, 5 on a quiet clockless field past turn 6.
phTauRel = 524288
IF phBurnMe >= 1 THEN phTauRel = 786432
IF phBurnMe = 0 THEN
  phAgg = 0
  phSeat = 0
  WHILE phSeat < playerCount
    phFam = 1
    phSlot = 2
    phPhase = phCurPhase
    GOSUB phSelect
    IF phVal > phAgg THEN phAgg = phVal
    phSeat = phSeat + 1
  WEND
  IF phAgg >= 22938 THEN phTauRel = 655360
  IF phAgg < 22938 AND turnNumber >= 6 AND phLedTot = 0 THEN phTauRel = 327680
END IF
' tau: focus bonuses. Press (5) when the focus seat's hail
' tendency >= 0.25 with Hail copies still unseen; ease (2) when
' its Hail is spent (4 seen) or it is a clock runner whose own
' clock is working (clock tendency >= 0.35, hail quiet).
phTauFoc = 196608
phHailSeen = 0
phHailT = 0
phClockT = 0
IF phFocus >= 0 THEN
  phSeat = phFocus
  phFam = 0
  phSlot = 0
  phPhase = 0
  GOSUB phSelect
  phHailSeen = phVal
  phSeat = phFocus
  phFam = 1
  phSlot = 0
  phPhase = phCurPhase
  GOSUB phSelect
  phHailT = phVal
  phSeat = phFocus
  phFam = 1
  phSlot = 1
  phPhase = phCurPhase
  GOSUB phSelect
  phClockT = phVal
  IF phHailT >= 16384 AND phHailSeen < 4 THEN phTauFoc = 327680
  IF phHailSeen >= 4 THEN phTauFoc = 131072
  IF phHailT < 16384 AND phClockT >= 22938 THEN phTauFoc = 131072
END IF
' tau: burn band. 6 when any opponent has started 2+ clocks
' (ledger), 3 when no clock has been seen by turn 8, else 4.
phTauBurn = 262144
phMaxBurn = 0
phSeat = 0
WHILE phSeat < playerCount
  IF phSeat <> selfPlayer THEN
    phFam = 0
    phSlot = 6
    phPhase = 0
    GOSUB phSelect
    IF phVal > phMaxBurn THEN phMaxBurn = phVal
  END IF
  phSeat = phSeat + 1
WEND
IF phMaxBurn >= 2 THEN phTauBurn = 393216
IF phMaxBurn = 0 AND turnNumber >= 8 AND phLedTot = 0 THEN phTauBurn = 196608
' Drift all four thetas (clamps are [0.5*theta0, 2*theta0]).
phFam = 2
phSeat = 0
phPhase = 0
phSlot = 0
phTau = phTauRel
phLo = 262144
phHi = 1048576
GOSUB phDrift
phSlot = 1
phTau = phTauFoc
phLo = 98304
phHi = 393216
GOSUB phDrift
phSlot = 2
phTau = phTauFoc - 65536
IF phTau < 65536 THEN phTau = 65536
phLo = 65536
phHi = 327680
GOSUB phDrift
phSlot = 3
phTau = phTauBurn
phLo = 131072
phHi = 524288
GOSUB phDrift
' phTurn ends here
RETURN

' ==== LIBPHEXT-BAS INCLUDE END ====

' ==== TALK.BAS INCLUDE BEGIN (verbatim talk.bas) ====
' =====================================================================
' talk.bas - TABLE TALK for the phext line (libphext-bas companion
' include, generation 0, EE 931). Will's directive: explicitly offer
' table talk, extend our capabilities as an offer, accept input from
' both the game and the participants - with a strategic layer that
' supports allies, deceives enemies, and keeps trust evidence-driven.
'
' PLACEMENT (include contract): policy code, libphext.bas, THIS
' module, the volume include. The host policy adds four binding
' hooks (the v37 hunks, each a few lines):
'   H-main:  GOSUB tkStep once per main decision (after phReadBase).
'   H-team:  in teamcalc, a protection pre-pass (tkFree) and, after
'            ebScore is computed, the threat/agree terms and the
'            protection shove (tkProt).
'   H-tail:  in score: and swing:, after the partner zeroing, one
'            tkProt check zeroes value against a protected seat.
'   H-obs:   in phObserve's attack branch, GOSUB tkObserveHook with
'            tkSeat = attacker, tkHookTarget = target owner.
' Everything else lives here. All talk state is in the phext store:
' trust is a TENDENCY (family 1, slot 4, phase 0, Q16.16, neutral
' 32768, obeying the family law - it decays x7/8 per own turn in
' phTurn's sweep and is refreshed only by evidence); discrete talk
' state is family 3 (TALK), per seat:
'   slot 0: p0 class (0 unknown, 1 ally, 2 enemy), p1 trust-init,
'           p2 replies received, p3 declines received
'   slot 1: p0 agreement (0 none, 1 honest NAP, 2 feigned NAP),
'           p1 expiry turn, p2 honor checks (consecutive),
'           p3 breaches by them
'   slot 2: p0 messages from seat, p1 messages to seat (DM),
'           p2 last message turn, p3 last verb from seat
'   slot 3: p0 last INFO named seat + 1, p1 INFO turn,
'           p2 true INFO count, p3 false INFO count
'   slot 4: p0 agreed target + 1, p1 agreed turn,
'           p2 their attacks on the agreed target, p3 coord
'           proposes we sent them
'   slot 5 (self row): p0 false INFO sent, p1 victim + 1,
'           p2 false INFO turn, p3 decoy target + 1
'   slot 6 (self row): p0 decoy turn, p1 decoy reply turn,
'           p2 our feigned breaches, p3 our breach turn
'   slot 15 (self row): p0 broadcasts sent, p1 total received,
'           p2 parse failures, p3 total sent
'
' GRAMMAR (compact, numeric, hand-parsed - no VAL): a message is
'   PX <v> <s> <x> <y> <z>
' five integers after the PX tag, single-space separated (the
' parser tolerates space runs). s is the declared sender; for
' direct messages mailboxId() is authoritative and wins any
' disagreement; for broadcasts (-2) the declared seat is all
' there is and is recorded as unverifiable. Verbs:
'   1 OFFER   (broadcast) x = 1 bundle (NAP + coordination),
'             y = window in turns, z = grammar version (1)
'   2 ACCEPT  (DM) x = offerer seat, y = window, z = agreed
'             target seat or -1
'   3 DECLINE (DM) x = offerer seat
'   4 INFO    (any) x = named threat seat, y = named seat's life
'             as claimed (0 = unclaimed), z = 0
'   5 PROPOSE (DM) x = terms (1 NAP, 2 coordination),
'             y = window (terms 1), z = target seat (terms 2)
' A message that fails to parse, or whose fields are out of
' range, is inscribed as raw evidence (a counter) and never
' acted on. Our own broadcast echo (mailboxId -2, declared
' sender = us) is recognized and ignored.
'
' MECHANISMS (pre-stated; each is trace-measurable):
'   M1 OFFER: one broadcast on our first own turn; one reminder
'      at our 3rd own turn if the table stayed silent. Cap: 2
'      broadcasts, 8 sends total per match.
'   M2 Agreements: an ACCEPT of our offer/propose forms an
'      HONEST non-aggression agreement. A PROPOSE (NAP) from an
'      ally forms an honest one too; from an UNKNOWN seat we
'      ACCEPT but mark it FEIGNED (M8); from an enemy, no reply.
'   M3 Protection: while an agreement is live, the seat is
'      excluded from our focus (teamcalc) and zeroed as a card /
'      attack target (score/swing tails, ping branch, aim
'      fallback) whenever any unprotected living outsider
'      exists (tkFree >= 1). If none exists, protection lapses
'      by necessity - last-hero-standing is the game.
'   M4 Honor/breach: each own turn an agreement survives with
'      no attack by the partner on us (any attack event whose
'      target owner is us, seen by phObserve) is an honor check:
'      trust EWMAs toward 65536. An attack under a live
'      agreement is a BREACH: agreement void, trust set to 0,
'      classification enemy, all PRINTed.
'   M5 Classification (evidence-gated; decay alone never
'      convicts): ally = honest agreement + >= 2 honor checks +
'      trust >= 45000. Enemy = a breach (until redeemed by a
'      later honest agreement with >= 3 honor checks and trust
'      >= 45000), or trust <= 20000 with >= 1 negative evidence
'      (decline, breach, or false INFO). Else unknown.
'   M6 Shared threat: INFO is truth-checked at receipt against
'      the life table (named seat must hold the max life among
'      living seats, ties count true). A true INFO from an ally
'      (or a seat with trust >= 40000) sets the threat seat:
'      teamcalc subtracts 3 from that seat's focus score for
'      12 turns. False INFO is inscribed against the sender
'      (trust toward 16384) and never moves our focus.
'   M7 Coordination: a coordination PROPOSE accepted (either
'      direction) sets the agreed target - same -3 focus term,
'      same 12-turn freshness. An ally attacking the agreed
'      target's hero is coordination honor (trust toward
'      57344, counted at slot 4 p2).
'   M8 Feigned breach (deception): a feigned agreement converts
'      to honest at 3 honor checks (evidence wins). Before
'      that, if our flood completes (boardCount(self) >= 6) on
'      an own turn with >= 1 honor check and >= 2 turns of
'      window left, we breach: agreement void, our breach
'      inscribed (slot 6), the seat unprotected from that turn.
'   M9 Decoy (deception): at our 3rd own turn we DM a NAP
'      PROPOSE to the highest-life unknown seat - a probe. Any
'      reply is inscribed with its latency; an ACCEPT forms an
'      honest agreement (a decoy accepted becomes real: our
'      word stays good).
'   M10 Genuine INFO (support): with an ally alive and a clear
'      leader who is not us, we broadcast the leader's identity
'      (on change, or every 15 turns, cap 3) - true information,
'      shared with the whole table.
'   M11 False INFO (deception): once per match, with an enemy
'      alive and (we are the life leader OR that enemy's
'      aggression tendency toward us is high), we broadcast an
'      INFO naming the highest-board-power non-leader outsider
'      who is not the enemy and not an ally - a credible wrong
'      threat, sent to pull focus off the real one.
'
' COST DISCIPLINE: sendChat and pullMailbox$ cost 256 work units
' each (the joint-highest in the host schedule) against a 5M
' decision budget - work is not the constraint; strings are.
' The drain is capped at 1 message per decision, the parse scan
' at 24 characters, and the drain runs only when phStrLeft
' (phObserve's leftover string budget) is >= 40, so in monster
' windows talk simply waits - the mailbox persists. Every path
' is failure-proof: empty mailbox, oversized or malformed
' messages, dead or invalid seats, and expiry edges all return
' without fault (C5: a failed decision zeroes the match; the
' league disqualifies at 3 consecutive failures).
' =====================================================================

tkInit:
tkReady = 1
tkOffered = 0
tkReminded = 0
tkOwnTurns = 0
tkLastMine = -1
tkTotalRecv = 0
tkTotalSent = 0
tkParseFail = 0
tkThreat = -1
tkThreatTurn = -100
tkAgreeT = -1
tkAgreeTurn = -100
tkLastInfoLead = -1
tkLastInfoTurn = -100
tkInfoCount = 0
tkFalseDone = 0
tkDecoyDone = 0
tkFree = 0
tkP = 0
tkT = 0
WHILE tkT < 8
  phFam = 1
  phSeat = tkT
  phSlot = 4
  phPhase = 0
  phVal = 32768
  GOSUB phReplace
  tkT = tkT + 1
WEND
RETURN

tkGet:
phFam = tkSF
phSeat = tkSS
phSlot = tkSL
phPhase = tkSP
GOSUB phSelect
tkSV = phVal
RETURN

tkPut:
phFam = tkSF
phSeat = tkSS
phSlot = tkSL
phPhase = tkSP
phVal = tkSV
GOSUB phReplace
RETURN

tkInc:
phFam = tkSF
phSeat = tkSS
phSlot = tkSL
phPhase = tkSP
GOSUB phInscribe
RETURN

tkTrustRead:
phFam = 1
phSeat = tkSS
phSlot = 4
phPhase = 0
GOSUB phSelect
tkTrustV = phVal
RETURN

tkTrustEwma:
phFam = 1
phSeat = tkSS
phSlot = 4
phPhase = 0
phX = tkTau
GOSUB phEwma
RETURN

tkTrustZero:
phFam = 1
phSeat = tkSS
phSlot = 4
phPhase = 0
phVal = 0
GOSUB phReplace
RETURN

tkSendText:
' Send tkText$ to tkTarget (a seat, or -2 broadcast), counted
' against the match send cap. Refuses silently past the cap.
IF tkTotalSent >= 8 THEN RETURN
tkTmp = sendChat(tkTarget, tkText$)
tkTotalSent = tkTotalSent + 1
tkSF = 3
tkSS = selfPlayer
tkSL = 15
tkSP = 3
tkSV = tkTotalSent
GOSUB tkPut
IF tkTarget >= 0 THEN
  tkSF = 3
  tkSS = tkTarget
  tkSL = 2
  tkSP = 1
  GOSUB tkInc
END IF
RETURN

tkLeader:
' tkLead = a living seat holding the max life (first such on
' ties), tkLeadLife = that life. All seats, us included.
' Uses its own loop variable (tkLT): callers loop on tkT.
tkLead = -1
tkLeadLife = -1
tkLT = 0
WHILE tkLT < playerCount
  IF playerDead(tkLT) = 0 AND playerLife(tkLT) > tkLeadLife THEN
    tkLeadLife = playerLife(tkLT)
    tkLead = tkLT
  END IF
  tkLT = tkLT + 1
WEND
RETURN

tkBoardPow:
' tkBP = total board power of seat tkSeat.
tkBP = 0
tkB = 0
WHILE tkB < boardCount(tkSeat)
  tkBP = tkBP + boardPower(tkSeat, tkB)
  tkB = tkB + 1
WEND
RETURN

tkProt:
' tkP = 1 iff seat tkSeat is under a live agreement with us
' (honest or feigned - we honor a feint until its trigger).
tkP = 0
IF tkSeat < 0 OR tkSeat = selfPlayer THEN RETURN
tkSF = 3
tkSS = tkSeat
tkSL = 1
tkSP = 0
GOSUB tkGet
IF tkSV = 0 THEN RETURN
tkSP = 1
GOSUB tkGet
IF turnNumber <= tkSV THEN tkP = 1
RETURN

tkClass:
' Recompute the classification of seat tkSeat from evidence and
' store it (family 3, slot 0, phase 0). Result also in tkCls.
tkSS = tkSeat
GOSUB tkTrustRead
tkSF = 3
tkSS = tkSeat
tkSL = 1
tkSP = 0
GOSUB tkGet
tkState = tkSV
tkSP = 2
GOSUB tkGet
tkHon = tkSV
tkSP = 3
GOSUB tkGet
tkBr = tkSV
tkSL = 0
tkSP = 3
GOSUB tkGet
tkNeg = tkSV
tkSL = 3
tkSP = 3
GOSUB tkGet
tkNeg = tkNeg + tkSV + tkBr
tkCls = 0
IF tkBr >= 1 THEN
  tkCls = 2
  IF tkState = 1 AND tkHon >= 3 AND tkTrustV >= 45000 THEN tkCls = 1
ELSE
  IF tkState = 1 AND tkHon >= 2 AND tkTrustV >= 45000 THEN tkCls = 1
  IF tkCls = 0 AND tkTrustV <= 20000 AND tkNeg >= 1 THEN tkCls = 2
END IF
tkSF = 3
tkSS = tkSeat
tkSL = 0
tkSP = 0
tkSV = tkCls
GOSUB tkPut
RETURN

tkStep:
IF tkReady = 0 THEN GOSUB tkInit
IF tossCount > 0 OR triggerTargets > 0 THEN RETURN
IF phStrLeft >= 40 THEN GOSUB tkDrain
IF currentPlayer = selfPlayer AND turnNumber > tkLastMine THEN
  tkLastMine = turnNumber
  tkOwnTurns = tkOwnTurns + 1
  GOSUB tkTurn
END IF
RETURN

tkDrain:
IF mailboxCount() = 0 THEN RETURN
tkMsg$ = pullMailbox$()
tkId = mailboxId()
IF tkMsg$ = "" THEN RETURN
GOSUB tkHandle
RETURN

tkParse:
' Parse tkMsg$ as PX v s x y z into tkV tkS tkX tkY tkZ.
' Hand-rolled scanner (ASC/MID$, the library's idiom); scan
' capped at 24 characters - the grammar's longest well-formed
' message is 16. Any defect: tkOk = 0, nothing else touched.
tkOk = 0
tkL = LEN(tkMsg$)
IF tkL < 11 OR tkL > 24 THEN RETURN
IF MID$(tkMsg$, 1, 2) <> "PX" THEN RETURN
IF MID$(tkMsg$, 3, 1) <> " " THEN RETURN
tkI = 4
tkN = 0
WHILE tkN < 5
  WHILE tkI <= tkL AND MID$(tkMsg$, tkI, 1) = " "
    tkI = tkI + 1
  WEND
  IF tkI > tkL THEN RETURN
  tkSgn = 1
  IF MID$(tkMsg$, tkI, 1) = "-" THEN
    tkSgn = -1
    tkI = tkI + 1
  END IF
  tkDig = 0
  tkNum = 0
  tkBad = 0
  WHILE tkI <= tkL AND tkBad = 0
    tkCh = ASC(MID$(tkMsg$, tkI, 1))
    IF tkCh >= 48 AND tkCh <= 57 THEN
      tkNum = tkNum * 10 + tkCh - 48
      tkDig = tkDig + 1
      tkI = tkI + 1
    ELSE
      tkBad = 1
    END IF
  WEND
  IF tkDig = 0 OR tkNum > 9999 THEN RETURN
  tkNum = tkSgn * tkNum
  IF tkN = 0 THEN tkV = tkNum
  IF tkN = 1 THEN tkS = tkNum
  IF tkN = 2 THEN tkX = tkNum
  IF tkN = 3 THEN tkY = tkNum
  IF tkN = 4 THEN tkZ = tkNum
  tkN = tkN + 1
WEND
WHILE tkI <= tkL
  IF MID$(tkMsg$, tkI, 1) <> " " THEN RETURN
  tkI = tkI + 1
WEND
tkOk = 1
RETURN

tkHandle:
GOSUB tkParse
IF tkOk = 0 THEN
  tkParseFail = tkParseFail + 1
  tkSF = 3
  tkSS = selfPlayer
  tkSL = 15
  tkSP = 2
  tkSV = tkParseFail
  GOSUB tkPut
  RETURN
END IF
IF tkV < 1 OR tkV > 5 THEN
  tkParseFail = tkParseFail + 1
  tkSF = 3
  tkSS = selfPlayer
  tkSL = 15
  tkSP = 2
  tkSV = tkParseFail
  GOSUB tkPut
  RETURN
END IF
IF tkId >= 0 THEN tkFrom = tkId ELSE tkFrom = tkS
IF tkFrom = selfPlayer THEN RETURN
IF tkFrom < 0 OR tkFrom >= playerCount THEN
  tkParseFail = tkParseFail + 1
  tkSF = 3
  tkSS = selfPlayer
  tkSL = 15
  tkSP = 2
  tkSV = tkParseFail
  GOSUB tkPut
  RETURN
END IF
tkTotalRecv = tkTotalRecv + 1
tkSF = 3
tkSS = tkFrom
tkSL = 2
tkSP = 0
GOSUB tkInc
tkSP = 2
tkSV = turnNumber
GOSUB tkPut
tkSP = 3
tkSV = tkV
GOSUB tkPut
tkSF = 3
tkSS = selfPlayer
tkSL = 15
tkSP = 1
tkSV = tkTotalRecv
GOSUB tkPut
PRINT "TK RX turn "; turnNumber; " from "; tkFrom; " verb "; tkV; " x "; tkX; " y "; tkY; " z "; tkZ
' Decoy reply? Any verb from the decoy target counts.
tkSF = 3
tkSS = selfPlayer
tkSL = 5
tkSP = 3
GOSUB tkGet
IF tkSV = tkFrom + 1 THEN
  tkSL = 6
  tkSP = 1
  GOSUB tkGet
  IF tkSV = 0 THEN
    tkSV = turnNumber
    GOSUB tkPut
    tkSP = 0
    GOSUB tkGet
    PRINT "TK DECOY-REPLY turn "; turnNumber; " from "; tkFrom; " latency "; turnNumber - tkSV
  END IF
END IF
IF tkV = 2 THEN GOSUB tkOnAccept
IF tkV = 3 THEN GOSUB tkOnDecline
IF tkV = 4 THEN GOSUB tkOnInfo
IF tkV = 5 THEN GOSUB tkOnPropose
RETURN

tkOnAccept:
' ACCEPT of our offer/propose. x must name us.
IF tkX <> selfPlayer THEN RETURN
tkWin = tkY
IF tkWin < 1 OR tkWin > 40 THEN tkWin = 10
tkSF = 3
tkSS = tkFrom
tkSL = 1
tkSP = 0
GOSUB tkGet
IF tkSV = 0 THEN
  tkSV = 1
  GOSUB tkPut
  tkSP = 2
  tkSV = 0
  GOSUB tkPut
END IF
tkSP = 1
tkSV = turnNumber + tkWin
GOSUB tkPut
tkSL = 0
tkSP = 2
GOSUB tkInc
tkSS = tkFrom
tkTau = 49152
GOSUB tkTrustEwma
PRINT "TK NAP turn "; turnNumber; " seat "; tkFrom; " state 1 exp "; turnNumber + tkWin
IF tkZ >= 0 AND tkZ < playerCount AND tkZ <> selfPlayer AND tkZ <> tkFrom THEN
  tkAgreeT = tkZ
  tkAgreeTurn = turnNumber
  tkSF = 3
  tkSS = tkFrom
  tkSL = 4
  tkSP = 0
  tkSV = tkZ + 1
  GOSUB tkPut
  tkSP = 1
  tkSV = turnNumber
  GOSUB tkPut
  PRINT "TK AGREE turn "; turnNumber; " seat "; tkFrom; " target "; tkZ
END IF
RETURN

tkOnDecline:
IF tkX <> selfPlayer THEN RETURN
tkSF = 3
tkSS = tkFrom
tkSL = 0
tkSP = 3
GOSUB tkInc
tkSS = tkFrom
tkTau = 16384
GOSUB tkTrustEwma
tkSeat = tkFrom
GOSUB tkClass
PRINT "TK DECLINE turn "; turnNumber; " seat "; tkFrom; " class "; tkCls
RETURN

tkOnInfo:
' INFO truth-checked against the life table at receipt.
IF tkX < 0 OR tkX >= playerCount THEN
  tkParseFail = tkParseFail + 1
  tkSF = 3
  tkSS = selfPlayer
  tkSL = 15
  tkSP = 2
  tkSV = tkParseFail
  GOSUB tkPut
  RETURN
END IF
GOSUB tkLeader
tkSF = 3
tkSS = tkFrom
tkSL = 3
tkSP = 0
tkSV = tkX + 1
GOSUB tkPut
tkSP = 1
tkSV = turnNumber
GOSUB tkPut
IF playerDead(tkX) = 0 AND playerLife(tkX) = tkLeadLife THEN
  tkSP = 2
  GOSUB tkInc
  tkSS = tkFrom
  GOSUB tkTrustRead
  tkWasAlly = 0
  tkSF = 3
  tkSS = tkFrom
  tkSL = 0
  tkSP = 0
  GOSUB tkGet
  IF tkSV = 1 THEN tkWasAlly = 1
  tkSS = tkFrom
  tkTau = 49152
  GOSUB tkTrustEwma
  PRINT "TK INFO-TRUE turn "; turnNumber; " from "; tkFrom; " named "; tkX
  IF tkX <> selfPlayer AND (tkWasAlly = 1 OR tkTrustV >= 40000) THEN
    tkThreat = tkX
    tkThreatTurn = turnNumber
    PRINT "TK THREAT turn "; turnNumber; " seat "; tkX
  END IF
ELSE
  tkSF = 3
  tkSS = tkFrom
  tkSL = 3
  tkSP = 3
  GOSUB tkInc
  tkSS = tkFrom
  tkTau = 16384
  GOSUB tkTrustEwma
  PRINT "TK INFO-FALSE turn "; turnNumber; " from "; tkFrom; " named "; tkX
END IF
RETURN

tkOnPropose:
IF tkX = 1 THEN
  ' NAP propose. Enemy: recorded, never answered.
  tkSeat = tkFrom
  tkSF = 3
  tkSS = tkFrom
  tkSL = 0
  tkSP = 0
  GOSUB tkGet
  IF tkSV = 2 THEN
    PRINT "TK PROPOSE-REJ turn "; turnNumber; " seat "; tkFrom
    RETURN
  END IF
  tkWin = tkY
  IF tkWin < 1 OR tkWin > 40 THEN tkWin = 10
  tkState = 2
  IF tkSV = 1 THEN tkState = 1
  tkSF = 3
  tkSS = tkFrom
  tkSL = 1
  tkSP = 0
  tkSV = tkState
  GOSUB tkPut
  tkSP = 1
  tkSV = turnNumber + tkWin
  GOSUB tkPut
  tkSP = 2
  tkSV = 0
  GOSUB tkPut
  tkText$ = "PX 2 " + STR$(selfPlayer) + " " + STR$(tkFrom) + " " + STR$(tkWin) + " -1"
  tkTarget = tkFrom
  GOSUB tkSendText
  PRINT "TK NAP turn "; turnNumber; " seat "; tkFrom; " state "; tkState; " exp "; turnNumber + tkWin
  RETURN
END IF
IF tkX = 2 THEN
  ' Coordination propose: z names the target.
  IF tkZ < 0 OR tkZ >= playerCount THEN RETURN
  IF tkZ = selfPlayer OR tkZ = tkFrom THEN RETURN
  IF playerDead(tkZ) THEN RETURN
  tkAgreeT = tkZ
  tkAgreeTurn = turnNumber
  tkSF = 3
  tkSS = tkFrom
  tkSL = 4
  tkSP = 0
  tkSV = tkZ + 1
  GOSUB tkPut
  tkSP = 1
  tkSV = turnNumber
  GOSUB tkPut
  tkSS = tkFrom
  tkTau = 49152
  GOSUB tkTrustEwma
  tkText$ = "PX 2 " + STR$(selfPlayer) + " " + STR$(tkFrom) + " 0 " + STR$(tkZ)
  tkTarget = tkFrom
  GOSUB tkSendText
  PRINT "TK AGREE turn "; turnNumber; " seat "; tkFrom; " target "; tkZ
  RETURN
END IF
RETURN

tkObserveHook:
' Called from phObserve's attack branch: tkSeat attacked, and
' tkHookTarget owns the attack's first target. No strings.
IF tkSeat < 0 OR tkSeat >= playerCount THEN RETURN
IF tkHookTarget = selfPlayer THEN
  tkSF = 3
  tkSS = tkSeat
  tkSL = 1
  tkSP = 0
  GOSUB tkGet
  IF tkSV = 0 THEN RETURN
  tkSP = 1
  GOSUB tkGet
  IF turnNumber > tkSV THEN RETURN
  ' Breach: agreement void, trust zeroed, class recomputed.
  tkSF = 3
  tkSS = tkSeat
  tkSL = 1
  tkSP = 0
  tkSV = 0
  GOSUB tkPut
  tkSP = 2
  tkSV = 0
  GOSUB tkPut
  tkSP = 3
  GOSUB tkInc
  tkSS = tkSeat
  GOSUB tkTrustZero
  GOSUB tkClass
  PRINT "TK BREACH-THEM turn "; turnNumber; " seat "; tkSeat
  RETURN
END IF
IF tkHookTarget >= 0 THEN
  ' Coordination honor: the actor hit its agreed target.
  tkSF = 3
  tkSS = tkSeat
  tkSL = 4
  tkSP = 0
  GOSUB tkGet
  IF tkSV = tkHookTarget + 1 THEN
    tkSP = 2
    GOSUB tkInc
    tkSS = tkSeat
    tkTau = 57344
    GOSUB tkTrustEwma
  END IF
END IF
RETURN

tkTurn:
' Own-turn bookkeeping: offer, agreements, deception, support.
' 1. The offer, once; the reminder, once, if the table is silent.
IF tkOffered = 0 THEN
  tkText$ = "PX 1 " + STR$(selfPlayer) + " 1 10 1"
  tkTarget = -2
  GOSUB tkSendText
  tkOffered = 1
  tkSF = 3
  tkSS = selfPlayer
  tkSL = 15
  tkSP = 0
  tkSV = 1
  GOSUB tkPut
  PRINT "TK OFFER turn "; turnNumber; " seat "; selfPlayer
ELSE
  IF tkReminded = 0 AND tkOwnTurns >= 3 AND tkTotalRecv = 0 THEN
    tkText$ = "PX 1 " + STR$(selfPlayer) + " 1 10 1"
    tkTarget = -2
    GOSUB tkSendText
    tkReminded = 1
    tkSF = 3
    tkSS = selfPlayer
    tkSL = 15
    tkSP = 0
    tkSV = 2
    GOSUB tkPut
    PRINT "TK REMIND turn "; turnNumber; " seat "; selfPlayer
  END IF
END IF
' 2. Agreements: lapse, honor checks, conversion, our breach.
tkT = 0
WHILE tkT < playerCount
  IF tkT <> selfPlayer THEN
    tkSF = 3
    tkSS = tkT
    tkSL = 1
    tkSP = 0
    GOSUB tkGet
    tkState = tkSV
    IF tkState > 0 THEN
      tkSP = 1
      GOSUB tkGet
      tkExp = tkSV
      tkSP = 2
      GOSUB tkGet
      tkHon = tkSV
      IF turnNumber > tkExp THEN
        tkSP = 0
        tkSV = 0
        GOSUB tkPut
        tkSP = 2
        tkSV = 0
        GOSUB tkPut
        PRINT "TK NAP-LAPSE turn "; turnNumber; " seat "; tkT
        tkState = 0
      ELSE
        tkHon = tkHon + 1
        tkSP = 2
        tkSV = tkHon
        GOSUB tkPut
        tkSS = tkT
        tkTau = 65536
        GOSUB tkTrustEwma
        IF tkState = 2 AND tkHon >= 3 THEN
          tkSF = 3
          tkSS = tkT
          tkSL = 1
          tkSP = 0
          tkSV = 1
          GOSUB tkPut
          tkState = 1
          PRINT "TK CONVERT turn "; turnNumber; " seat "; tkT
        END IF
        IF tkState = 2 AND tkHon >= 1 AND boardCount(selfPlayer) >= 6 AND turnNumber <= tkExp - 2 THEN
          tkSF = 3
          tkSS = tkT
          tkSL = 1
          tkSP = 0
          tkSV = 0
          GOSUB tkPut
          tkSF = 3
          tkSS = selfPlayer
          tkSL = 6
          tkSP = 2
          GOSUB tkInc
          tkSP = 3
          tkSV = turnNumber
          GOSUB tkPut
          tkSS = tkT
          tkTau = 16384
          GOSUB tkTrustEwma
          PRINT "TK BREACH-OURS turn "; turnNumber; " seat "; tkT; " board "; boardCount(selfPlayer)
          tkState = 0
        END IF
      END IF
    END IF
    tkSeat = tkT
    GOSUB tkClass
  END IF
  tkT = tkT + 1
WEND
' 3. Decoy probe at our 3rd own turn: highest-life unknown seat.
IF tkDecoyDone = 0 AND tkOwnTurns >= 3 THEN
  tkDecoyDone = 1
  tkBest = -1
  tkBestLife = -1
  tkT = 0
  WHILE tkT < playerCount
    IF tkT <> selfPlayer AND playerDead(tkT) = 0 THEN
      tkSF = 3
      tkSS = tkT
      tkSL = 0
      tkSP = 0
      GOSUB tkGet
      IF tkSV = 0 AND playerLife(tkT) > tkBestLife THEN
        tkBestLife = playerLife(tkT)
        tkBest = tkT
      END IF
    END IF
    tkT = tkT + 1
  WEND
  IF tkBest >= 0 THEN
    tkText$ = "PX 5 " + STR$(selfPlayer) + " 1 8 -1"
    tkTarget = tkBest
    GOSUB tkSendText
    tkSF = 3
    tkSS = selfPlayer
    tkSL = 5
    tkSP = 3
    tkSV = tkBest + 1
    GOSUB tkPut
    tkSL = 6
    tkSP = 0
    tkSV = turnNumber
    GOSUB tkPut
    PRINT "TK DECOY turn "; turnNumber; " to "; tkBest
  END IF
END IF
' 4. Coordination propose to an ally, once per ally, when a
' clear leader exists who is neither of us.
tkT = 0
WHILE tkT < playerCount
  IF tkT <> selfPlayer AND playerDead(tkT) = 0 THEN
    tkSF = 3
    tkSS = tkT
    tkSL = 0
    tkSP = 0
    GOSUB tkGet
    IF tkSV = 1 THEN
      tkSL = 4
      tkSP = 3
      GOSUB tkGet
      IF tkSV = 0 THEN
        GOSUB tkLeader
        IF tkLead >= 0 AND tkLead <> selfPlayer AND tkLead <> tkT THEN
          tkText$ = "PX 5 " + STR$(selfPlayer) + " 2 0 " + STR$(tkLead)
          tkTarget = tkT
          GOSUB tkSendText
          tkSF = 3
          tkSS = tkT
          tkSL = 4
          tkSP = 3
          GOSUB tkInc
          PRINT "TK COORD-PROPOSE turn "; turnNumber; " to "; tkT; " target "; tkLead
        END IF
      END IF
    END IF
  END IF
  tkT = tkT + 1
WEND
' 5. Genuine INFO (support) - and, failing that, false INFO.
' At most one INFO broadcast per own turn; support first.
tkInfoDone = 0
GOSUB tkLeader
tkAllyAlive = 0
tkT = 0
WHILE tkT < playerCount
  IF tkT <> selfPlayer AND playerDead(tkT) = 0 THEN
    tkSF = 3
    tkSS = tkT
    tkSL = 0
    tkSP = 0
    GOSUB tkGet
    IF tkSV = 1 THEN tkAllyAlive = 1
  END IF
  tkT = tkT + 1
WEND
IF tkAllyAlive = 1 AND tkLead >= 0 AND tkLead <> selfPlayer AND tkInfoCount < 3 THEN
  IF tkLead <> tkLastInfoLead OR turnNumber - tkLastInfoTurn >= 15 THEN
    tkText$ = "PX 4 " + STR$(selfPlayer) + " " + STR$(tkLead) + " " + STR$(tkLeadLife) + " 0"
    tkTarget = -2
    GOSUB tkSendText
    tkLastInfoLead = tkLead
    tkLastInfoTurn = turnNumber
    tkInfoCount = tkInfoCount + 1
    tkInfoDone = 1
    PRINT "TK INFO-OUT turn "; turnNumber; " named "; tkLead; " genuine 1"
  END IF
END IF
IF tkInfoDone = 0 AND tkFalseDone = 0 THEN
  tkEnemy = -1
  tkT = 0
  WHILE tkT < playerCount
    IF tkT <> selfPlayer AND playerDead(tkT) = 0 THEN
      tkSF = 3
      tkSS = tkT
      tkSL = 0
      tkSP = 0
      GOSUB tkGet
      IF tkSV = 2 THEN tkEnemy = tkT
    END IF
    tkT = tkT + 1
  WEND
  IF tkEnemy >= 0 THEN
    tkFire = 0
    IF tkLead = selfPlayer THEN tkFire = 1
    phTurnN = turnNumber
    GOSUB phPhaseSet
    phFam = 1
    phSeat = tkEnemy
    phSlot = 2
    GOSUB phSelect
    IF phVal >= 22938 THEN tkFire = 1
    IF tkFire = 1 THEN
      tkBest = -1
      tkBestBP = -1
      tkT = 0
      WHILE tkT < playerCount
        IF tkT <> selfPlayer AND tkT <> tkEnemy AND tkT <> tkLead AND playerDead(tkT) = 0 AND boardCount(tkT) >= 2 THEN
          tkSF = 3
          tkSS = tkT
          tkSL = 0
          tkSP = 0
          GOSUB tkGet
          IF tkSV <> 1 THEN
            tkSeat = tkT
            GOSUB tkBoardPow
            IF tkBP > tkBestBP THEN
              tkBestBP = tkBP
              tkBest = tkT
            END IF
          END IF
        END IF
        tkT = tkT + 1
      WEND
      IF tkBest >= 0 THEN
        tkText$ = "PX 4 " + STR$(selfPlayer) + " " + STR$(tkBest) + " " + STR$(playerLife(tkBest)) + " 0"
        tkTarget = -2
        GOSUB tkSendText
        tkFalseDone = 1
        tkSF = 3
        tkSS = selfPlayer
        tkSL = 5
        tkSP = 0
        tkSV = 1
        GOSUB tkPut
        tkSP = 1
        tkSV = tkBest + 1
        GOSUB tkPut
        tkSP = 2
        tkSV = turnNumber
        GOSUB tkPut
        PRINT "TK INFO-OUT turn "; turnNumber; " named "; tkBest; " genuine 0"
      END IF
    END IF
  END IF
END IF
PRINT "TK STATE turn "; turnNumber; " threat "; tkThreat; " agree "; tkAgreeT; " free "; tkFree; " sent "; tkTotalSent; " recv "; tkTotalRecv
RETURN
' ==== TALK.BAS INCLUDE END ====

' ==== VOLUME INCLUDE: the repo's empty stub for volume-less use ====
phLoadVolume:
phVol$ = ""
RETURN
