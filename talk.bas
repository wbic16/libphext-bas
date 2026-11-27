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
