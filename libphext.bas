' =====================================================================
' libphext-bas - BASIC PHEXT (generation 0)
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
' consumers): at most 256 string values may be live within one
' decision - every string-returning host call, concatenation,
' and slice spends one, and a single decision that overspends
' dies with "BASIC string count limit exceeded". Strings held in
' globals survive across decisions; the rest are reclaimed at
' restart. Consequences: the volume parse runs at setup (its own
' decision), the in-match observer (section 2) drains the event
' log under a hard budget of 140 string reads per decision, and
' phImplode is a setup/harness tool, never an in-match call.
' The parse itself spends about one string value per payload
' character (MID$+ASC is the dialect's only character access),
' so a single-shot setup parse supports roughly 220 payload
' characters inside the 256 budget - measured: 223-byte volume
' of 32 single-value scrolls parses, 279 bytes fails; 216 bytes
' of dense 4-value scrolls parses, 247 fails. Keep data volumes
' small; larger volumes want incremental parsing across
' decisions (named, not built in generation 0). A single string
' also caps at 1024 characters, and all string bytes created in
' one decision cap at 64 KiB cumulative - create-and-discard
' does not reclaim either budget mid-decision (all measured).
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
' phLoadVolume, then phParseVolume.
' =====================================================================

DIM phStore(2047)
DIM phCoord(8)

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
' Outside the data cell: count and skip. Inside: parse the
' payload's integer list and store value k at phase0+k.
IF phCoord(0) <> 1 OR phCoord(1) <> 1 OR phCoord(2) <> 1 OR phCoord(3) <> 1 OR phCoord(4) <> 1 THEN
  phForeign = phForeign + 1
  RETURN
END IF
phFam = phCoord(6) - 1
phSeat = phCoord(7) - 1
phSlot = phCoord(8) - 1
phPhase0 = phCoord(5) - 1
IF phFam < 0 OR phFam > 2 OR phSeat < 0 OR phSeat > 7 OR phSlot < 0 OR phSlot > 15 OR phPhase0 < 0 OR phPhase0 > 3 THEN
  phForeign = phForeign + 1
  RETURN
END IF
phScrolls = phScrolls + 1
phK = 0
phTokV = 0
phTokSgn = 1
phTokOn = 0
phTokDig = 0
phTokBad = 0
phI = 1
WHILE phI <= LEN(phText$) + 1
  phCh = 32
  IF phI <= LEN(phText$) THEN phCh = ASC(MID$(phText$, phI, 1))
  IF phCh = 32 OR phCh = 44 OR phCh = 9 OR phCh = 10 OR phCh = 13 THEN
    IF phTokOn = 1 THEN
      IF phTokBad = 1 OR phTokDig = 0 THEN
        phParseErr = phParseErr + 1
      ELSE
        phFam = phCoord(6) - 1
        phSeat = phCoord(7) - 1
        phSlot = phCoord(8) - 1
        phPhase = phPhase0 + phK
        IF phPhase > 3 THEN
          phParseErr = phParseErr + 1
        ELSE
          phVal = phTokSgn * phTokV
          GOSUB phReplace
        END IF
      END IF
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
  phI = phI + 1
WEND
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
' The host policy reads the thetas each decision via phRead into
' relBand, focSwingB, focScoreB, burnBand.

phPhaseSet:
phPhase = 0
IF phTurnN >= 5 THEN phPhase = 1
IF phTurnN >= 10 THEN phPhase = 2
RETURN

phInit:
' Load the volume (phLoadVolume, from the policy's data include)
' and parse it into the store. Called from the host's setup
' block - bassy reset() runs once before setup, so the loaded
' store carries into the match - or lazily at the first decision
' when the seat's setup never ran (classes-override rosters).
phReady = 1
GOSUB phTextInit
GOSUB phLoadVolume
GOSUB phParseVolume
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

phObserve:
' Drain the event log since our last decision, oldest first,
' inscribing observations at their coordinates, under the string
' budget (140 string-returning host calls this decision - see
' the string law in the header). Events past the budget are
' skipped and counted in phSkipped: the mechanism degrades in
' monster windows; it never dies there.
phStrLeft = 140
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
