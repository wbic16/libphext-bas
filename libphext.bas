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
