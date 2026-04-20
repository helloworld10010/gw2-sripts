#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn

; Power Boon Chronomancer (Greatsword / Dagger+Sword)
; MButton = start / stop
; F7  = reset loop state
; F10 = exit script
;
; Notes:
; 1. This script uses pixel color to decide whether a skill is ready.
; 2. "Not black" means ready, based on the coordinates you provided.
; 3. Weapon swap is attempted at the end of each loop. Current weapon is
;    detected by pixel color, so restarting mid-fight can still recover.
; 4. Updated bindings:
;    5 -> f, 6/7/8/9/0 -> c/q/e/r/z, F4 -> v, F5 -> x.
; 5. Weapon swap key cooldown pixel: 650,1025.

CoordMode("Pixel", "Screen")
SendMode("Event")
SetKeyDelay(30, 30)

global TargetWindow := "ahk_exe Gw2-64.exe"
global Running := false
global BusyUntil := 0
global TimingScale := 1.1
global LastWeapon := ""
global LastSwapAttempt := 0
global LastWeaponSwapTick := 0
global LastAction := ""
global LastActionTick := 0
global LastF5Tick := 0
global AwaitingSwap := false
global ExpectedWeapon := ""
global SwapPendingTick := 0
global SwapWaitMs := ScaleMs(1800)
global SwapConfirmMs := ScaleMs(450)
global CurrentWeapon := ""
global LogFilePath := ""
global F5Armed := false
global F5ArmedTick := 0
global OpenerActive := false
global OpenerInProgress := false
global OpenerStep := 1
global OpenerPlan := [
    ["3"],
    ["5", "2"],
    ["SWAP"],
    ["2"],
    ["4", "F5"],
    ["6", "4"],
    ["7", "8"],
    ["2", "3"],
    ["0", "F5"],
    ["4", "7"],
    ["8", "6"],
    ["4", "2"],
    ["3"],
    ["SWAP"]
]

global CastBuffer := 90
global UtilityBuffer := 120
global SwapRetryMs := ScaleMs(700)
global SwapSend := "{vkC0}"
global CastRepeatMs := ScaleMs(60)

global WeaponIndicator := [818, 1037]
global IllusionIndicator := [827, 946]
global FullIllusionColor := 0x212429
global PowerSpikeIndicator := [1194, 1023]
global PowerSpikeFullColor := 0xFFFFFF

global SkillPixels := Map(
    "1", [691, 1024],
    "2", [741, 1021],
    "3", [791, 1020],
    "4", [841, 1020],
    "5", [889, 1022],
    "6", [1029, 1023],
    "7", [1076, 1024],
    "8", [1127, 1023],
    "9", [1176, 1022],
    "0", [1226, 1024],
    "SWAP", [650, 1025],
    "F1", [711, 967],
    "F2", [751, 969],
    "F3", [790, 966],
    "F4", [831, 968],
    "F5", [878, 967]
)

global ActionSend := Map(
    "1", "1",
    "2", "2",
    "3", "3",
    "4", "4",
    "5", "f",
    "6", "c",
    "7", "q",
    "8", "e",
    "9", "r",
    "0", "z",
    "F1", "{F1}",
    "F2", "{F2}",
    "F3", "{F3}",
    "F4", "v",
    "F5", "x",
    "SWAP", SwapSend
)

global GSDelays := Map(
    "1", 1000,
    "2", 750,
    "3", 250,
    "4", 1050,
    "5", 500
)

global DSDelays := Map(
    "1", 500,
    "2", 0,
    "3", 0,
    "4", 2250,
    "5", 1050
)

; Snow Crows loop:
; Greatsword: 4 2 -> 3 -> filler -> 2 -> filler -> 3 4 2 -> swap
; Dagger/Sword: 2 5 -> c 5 2 -> filler -> 2 -> filler -> 2 -> filler -> 5 3 2 -> swap
; Readiness is only used to decide whether the current planned step can be cast
; and where to re-enter the loop after starting mid-rotation.
global GSPlan := ["4", "2", "3", "FILL", "2", "FILL", "3", "4", "2", "SWAP"]
global DSPlan := ["2", "5", "6", "5", "2", "FILL", "2", "FILL", "2", "FILL", "5", "3", "2", "SWAP"]

global GsStep := 0
global DsStep := 0

; Filler windows use q/e/z, then r on full charges, then auto attack.
global FillerPriority := ["7", "8", "0"]

if (A_Args.Length && A_Args[1] = "--syntax-check")
    ExitApp()

SetTimer(RotationTick, 30)

MButton:: {
    ToggleRotation()
}

F7:: {
    ResetLoopState()
    ShowTip("Chrono loop state reset")
}

F6:: {
    ShowDebugState()
}

F10:: {
    ExitApp()
}

ToggleRotation() {
    global Running, BusyUntil, GsStep, DsStep, AwaitingSwap, ExpectedWeapon, CurrentWeapon, LastWeapon, OpenerActive, OpenerStep, F5Armed, F5ArmedTick, LogFilePath

    Running := !Running
    BusyUntil := 0

    if Running {
        GsStep := 0
        DsStep := 0
        AwaitingSwap := false
        ExpectedWeapon := ""
        CurrentWeapon := DetectWeapon()
        LastWeapon := CurrentWeapon
        OpenerActive := (CurrentWeapon = "DS")
        OpenerStep := 1
        F5Armed := false
        F5ArmedTick := 0

        ; create new log file per start
        now := A_Now
        date := SubStr(now,1,8)
        time := SubStr(now,9,6)
        LogFilePath := "D:\\Code\\GW2Scripts\\chrono_log_" . date . "_" . time . ".txt"
        FileAppend("[START] " . SubStr(now,1,4) . "-" . SubStr(now,5,2) . "-" . SubStr(now,7,2) . " " . SubStr(now,9,2) . ":" . SubStr(now,11,2) . ":" . SubStr(now,13,2) . "`n", LogFilePath)
        LogEvent("START", CurrentWeapon, "Opener=" . (OpenerActive ? "1" : "0"))
        ShowTip("Chrono loop ON")
    } else {
        ShowTip("Chrono loop OFF")
    }
}

ResetLoopState() {
    global GsStep, DsStep, LastWeapon, LastSwapAttempt, LastWeaponSwapTick, BusyUntil, LastAction, LastActionTick, LastF5Tick, AwaitingSwap, ExpectedWeapon, SwapPendingTick, CurrentWeapon, F5Armed, F5ArmedTick, OpenerActive, OpenerStep

    GsStep := 0
    DsStep := 0
    LastWeapon := ""
    LastSwapAttempt := 0
    LastWeaponSwapTick := 0
    BusyUntil := 0
    LastAction := ""
    LastActionTick := 0
    LastF5Tick := 0
    AwaitingSwap := false
    ExpectedWeapon := ""
    SwapPendingTick := 0
    CurrentWeapon := DetectWeapon()
    LastWeapon := CurrentWeapon
    F5Armed := false
    F5ArmedTick := 0
    OpenerActive := false
    OpenerStep := 1
}

RotationTick() {
    global Running, BusyUntil, LastWeapon, LastWeaponSwapTick, GsStep, DsStep, TargetWindow, AwaitingSwap, ExpectedWeapon, SwapPendingTick, SwapWaitMs, SwapConfirmMs, CurrentWeapon, F5Armed, F5ArmedTick, OpenerActive, OpenerStep

    if !Running
        return

    if !WinActive(TargetWindow)
        return

    if (A_TickCount < BusyUntil) {
        if (!OpenerActive && !AwaitingSwap && TryPrioritySkills(CurrentWeapon))
            return
        return
    }

    ; quick sync: if UI shows a different weapon than internal state, adopt it immediately
    detected := DetectWeapon()
    if (CurrentWeapon = "") {
        CurrentWeapon := detected
        LastWeapon := CurrentWeapon
    } else if (detected != CurrentWeapon) {
        CurrentWeapon := detected
        LastWeapon := CurrentWeapon
        SetLoopStep(CurrentWeapon, 1)
        BusyUntil := A_TickCount + ScaleMs(80)
    }

    weapon := CurrentWeapon

    if F5Armed && (A_TickCount - F5ArmedTick > 1500)
        F5Armed := false

    if AwaitingSwap {
        if (A_TickCount - SwapPendingTick >= SwapConfirmMs) {
            CurrentWeapon := ExpectedWeapon
            weapon := CurrentWeapon
            LastWeapon := weapon
            LastWeaponSwapTick := A_TickCount
            AwaitingSwap := false
            SwapPendingTick := 0
            ExpectedWeapon := ""
            SetLoopStep(weapon, 1)
            BusyUntil := A_TickCount + ScaleMs(300)
            if (OpenerActive && OpenerStep > OpenerPlan.Length) {
                OpenerActive := false
                OpenerStep := 1
                return
            }
        } else if (A_TickCount - SwapPendingTick >= SwapWaitMs) {
            AwaitingSwap := false
            SwapPendingTick := 0
            CurrentWeapon := weapon
            LastWeapon := weapon
            LastWeaponSwapTick := A_TickCount
            ExpectedWeapon := ""
            SetLoopStep(weapon, 1)
            BusyUntil := A_TickCount + ScaleMs(300)
            if (OpenerActive && OpenerStep > OpenerPlan.Length) {
                OpenerActive := false
                OpenerStep := 1
                return
            }
        } else {
            return
        }
    }

    if TryPrioritySkills(weapon)
        return

    if OpenerActive {
        global OpenerInProgress
        if !OpenerInProgress {
            OpenerInProgress := true
            RunOpener(CurrentWeapon)
            OpenerInProgress := false
        }
        return
    }

    if TrySequence(weapon)
        return
}

TryPrioritySkills(weapon) {
    return false
}

TryOpenerSequence(weapon) {
    global OpenerPlan, OpenerStep, LastSwapAttempt, SwapRetryMs, OpenerActive

    if (OpenerStep < 1 || OpenerStep > OpenerPlan.Length)
        return false

    group := OpenerPlan[OpenerStep]

    if (group.Length = 1 && group[1] = "SWAP") {
        if (A_TickCount - LastSwapAttempt >= SwapRetryMs && IsReady("SWAP")) {
            LastSwapAttempt := A_TickCount
            if CastAction("SWAP", weapon) {
                OpenerStep += 1
                return true
            }
        }
        return false
    }

    if !ExecuteStepGroup(group, weapon)
        return false

    OpenerStep += 1
    return true
}

ExecuteStepGroup(group, weapon) {
    global ActionSend, BusyUntil, Running, TargetWindow, CastRepeatMs, LastAction, LastActionTick

    castSkill := ""

    for _, action in group {
        if (action = "F5") {
            SendEvent(ActionSend[action])
            LogEvent(action, CurrentWeapon)
            LastAction := action
            LastActionTick := A_TickCount
            continue
        }

        if !ActionSend.Has(action)
            return false

        SendEvent(ActionSend[action])
        LogEvent(action, CurrentWeapon)
        LastAction := action
        LastActionTick := A_TickCount

        if (castSkill = "" && GetActionDelay(action, weapon) > 0)
            castSkill := action
    }

    if (castSkill = "")
        return true

    castMs := GetActionDelay(castSkill, weapon)
    bufferMs := GetActionBuffer(castSkill)
    repeatKey := ActionSend[castSkill]
    startTick := A_TickCount
    nextTick := startTick + CastRepeatMs

    while (A_TickCount - startTick < castMs) {
        if !Running
            return false
        if !WinActive(TargetWindow)
            return false

        if (A_TickCount >= nextTick) {
            SendEvent(repeatKey)
            nextTick += CastRepeatMs
            continue
        }

        Sleep(10)
    }

    BusyUntil := A_TickCount + bufferMs
    return true
}

TrySequence(weapon) {
    global GSPlan, DSPlan, LastSwapAttempt, SwapRetryMs

    plan := (weapon = "GS") ? GSPlan : DSPlan
    step := GetLoopStep(weapon)
    if (step < 1 || step > plan.Length) {
        step := 1
        SetLoopStep(weapon, step)
    }

    action := plan[step]

    if (action = "FILL") {
        nextAction := plan[step + 1]
        if IsReady(nextAction) {
            SetLoopStep(weapon, step + 1)
            return false
        }
        return TryFiller(weapon)
    }

    if (action = "SWAP") {
        if (A_TickCount - LastSwapAttempt >= SwapRetryMs && IsReady("SWAP")) {
            LastSwapAttempt := A_TickCount
            if CastAction("SWAP", weapon)
                return true
        }
        return TryFiller(weapon)
    }

    if !IsReady(action)
        return TryFiller(weapon)

    if !CastAction(action, weapon)
        return false

    step += 1
    if (step > plan.Length)
        step := 1
    SetLoopStep(weapon, step)

    return true
}

TryFiller(weapon) {
    global FillerPriority

    if HasFullIllusions() {
        if IsReady("F1") {
            if CastAction("F1", weapon)
                return true
        }

        if (!IsReady("F1") && IsReady("F2")) {
            if CastAction("F2", weapon)
                return true
        }
    }

    for _, action in FillerPriority {
        if IsReady(action) {
            if CastAction(action, weapon)
                return true
        }
    }

    if CanCastPowerSpike() {
        if CastAction("9", weapon)
            return true
    }

    return false
}

CastAction(action, weapon) {
    global ActionSend, BusyUntil, LastAction, LastActionTick, LastF5Tick, AwaitingSwap, ExpectedWeapon, SwapPendingTick, CurrentWeapon, LastWeapon, LastWeaponSwapTick, F5Armed, F5ArmedTick, OpenerActive

    if !ActionSend.Has(action)
        return false

    castMs := GetActionDelay(action, weapon)
    bufferMs := GetActionBuffer(action)

    SendDuringCast(action, castMs)
    BusyUntil := A_TickCount + bufferMs
    LastAction := action
    LastActionTick := A_TickCount
    if (action = "F5")
        LastF5Tick := A_TickCount
    if (action = "F5") {
        F5Armed := false
        F5ArmedTick := 0
    }
    if (OpenerActive && weapon = "GS" && (action = "4" || action = "0")) {
        F5Armed := true
        F5ArmedTick := A_TickCount
    }
    if (action = "SWAP") {
        ; Immediate swap: update internal weapon tracking without waiting for pixel confirmation
        ExpectedWeapon := ""
        CurrentWeapon := (weapon = "GS") ? "DS" : "GS"
        LastWeapon := CurrentWeapon
        LastWeaponSwapTick := A_TickCount
        AwaitingSwap := false
        SwapPendingTick := 0
        SetLoopStep(CurrentWeapon, 1)
        BusyUntil := A_TickCount + ScaleMs(150)
    }
    return true
}

SendDuringCast(action, castMs) {
    global ActionSend, CastRepeatMs, Running, TargetWindow, CurrentWeapon, BusyUntil

    key := ActionSend[action]
    SendEvent(key)
    LogEvent(action, CurrentWeapon)

    if (castMs <= 0)
        return

    startTick := A_TickCount
    nextTick := startTick + CastRepeatMs

    while (A_TickCount - startTick < castMs) {
        if !Running
            return
        if !WinActive(TargetWindow)
            return

        if (A_TickCount >= nextTick) {
            SendEvent(key)
            nextTick += CastRepeatMs
            continue
        }

        Sleep(10)
    }
}

GetActionDelay(action, weapon) {
    global GSDelays, DSDelays, TimingScale

    if (action = "SWAP")
        return ScaleMs(150)

    if (weapon = "GS" && GSDelays.Has(action))
        return ScaleMs(GSDelays[action])

    if (weapon = "DS" && DSDelays.Has(action))
        return ScaleMs(DSDelays[action])

    return 0
}

GetActionBuffer(action) {
    global CastBuffer, UtilityBuffer

    if (action = "SWAP")
        return ScaleMs(180)

    if RegExMatch(action, "^[1-5]$")
        return ScaleMs(CastBuffer)

    return ScaleMs(UtilityBuffer)
}

DetectWeapon() {
    global WeaponIndicator

    color := PixelGetColor(WeaponIndicator[1], WeaponIndicator[2], "RGB")
    return IsBlack(color) ? "GS" : "DS"
}

GetLoopStep(weapon) {
    global GsStep, DsStep
    return (weapon = "GS") ? GsStep : DsStep
}

SetLoopStep(weapon, step) {
    global GsStep, DsStep

    if (weapon = "GS") {
        GsStep := step
    } else {
        DsStep := step
    }
}

GetResumeStep(weapon) {
    if (weapon = "GS") {
        if (IsReady("4") && IsReady("2"))
            return 1
        if (IsReady("3") && !IsReady("2"))
            return 3
        if (IsReady("2") && !IsReady("3") && !IsReady("4"))
            return 5
        if (IsReady("3") && IsReady("4") && !IsReady("2"))
            return 7
        return 4
    }

    if (IsReady("2") && IsReady("5"))
        return 1
    if (IsReady("6") && IsReady("5") && IsReady("2") && !IsReady("3"))
        return 3
    if (IsReady("2") && !IsReady("5"))
        return 7
    if (IsReady("5") && IsReady("3"))
        return 11
    return 6
}

HasFullIllusions() {
    global IllusionIndicator, FullIllusionColor

    color := PixelGetColor(IllusionIndicator[1], IllusionIndicator[2], "RGB")
    return (color != FullIllusionColor)
}

ShouldCastF5(weapon) {
    global F5Armed, F5ArmedTick, CurrentWeapon, OpenerActive

    if !OpenerActive || !F5Armed
        return false

    if (CurrentWeapon != "GS")
        return false

    if !IsReady("F5")
        return false

    if (A_TickCount - F5ArmedTick > 1500) {
        F5Armed := false
        return false
    }

    return true
}

CanCastPowerSpike() {
    global PowerSpikeIndicator, PowerSpikeFullColor

    color := PixelGetColor(PowerSpikeIndicator[1], PowerSpikeIndicator[2], "RGB")
    return (color = PowerSpikeFullColor)
}

IsReady(skill) {
    global SkillPixels

    if !SkillPixels.Has(skill)
        return false

    pos := SkillPixels[skill]
    color := PixelGetColor(pos[1], pos[2], "RGB")
    return !IsBlack(color)
}

IsBlack(color) {
    return (color = 0x000000)
}

ShowTip(text) {
    ToolTip(text)
    SetTimer(ClearTip, -900)
}

ClearTip() {
    ToolTip()
}

ShowDebugState() {
    global Running, BusyUntil, LastWeapon, LastWeaponSwapTick, GsStep, DsStep, AwaitingSwap, ExpectedWeapon, CurrentWeapon, OpenerActive, OpenerStep

    rawWeapon := DetectWeapon()
    text := "Weapon=" CurrentWeapon
        . "`nRawWeapon=" rawWeapon
        . "`nLastWeapon=" LastWeapon
        . "`nAwaitingSwap=" (AwaitingSwap ? "1" : "0")
        . " Expected=" ExpectedWeapon
        . "`nOpener=" (OpenerActive ? "1" : "0")
        . " Step=" OpenerStep
        . "`nGS step=" GetLoopStep("GS") " / resume=" GetResumeStep("GS")
        . "`nDS step=" GetLoopStep("DS") " / resume=" GetResumeStep("DS")
        . "`nBusyUntil=" BusyUntil
        . " Running=" (Running ? "1" : "0")
        . "`nReady: 1=" ReadyFlag("1")
        . " 2=" ReadyFlag("2")
        . " 3=" ReadyFlag("3")
        . " 4=" ReadyFlag("4")
        . " 5=" ReadyFlag("5")
        . "`nF1=" ReadyFlag("F1")
        . " F2=" ReadyFlag("F2")
        . " F3=" ReadyFlag("F3")
        . " F4=" ReadyFlag("F4")
        . " F5=" ReadyFlag("F5")
        . " SWAP=" ReadyFlag("SWAP")

    A_Clipboard := text
    ToolTip(text)
    SetTimer(ClearTip, -3000)
}

ReadyFlag(skill) {
    return IsReady(skill) ? "1" : "0"
}

ScaleMs(value) {
    global TimingScale
    return Max(1, Round(value * TimingScale))
}

LogEvent(action, weapon, extra := "") {
    global ActionSend, BusyUntil, LogFilePath

    outFile := (LogFilePath != "") ? LogFilePath : "D:\\Code\\GW2Scripts\\chrono_log.txt"
    now := A_Now
    ts := SubStr(now,1,4) . "-" . SubStr(now,5,2) . "-" . SubStr(now,7,2) . " " . SubStr(now,9,2) . ":" . SubStr(now,11,2) . ":" . SubStr(now,13,2)
    ms := Mod(A_TickCount, 1000)
    if (ms < 10)
        msStr := "00" . ms
    else if (ms < 100)
        msStr := "0" . ms
    else
        msStr := ms
    ts := ts . "." . msStr

    key := (ActionSend.Has(action)) ? ActionSend[action] : ""
    line := "[" . ts . "] SEND: " . action . " key=" . key . " weapon=" . weapon . " BusyUntil=" . BusyUntil . " " . extra . "`n"
    FileAppend(line, outFile)
}

RunOpener(startWeapon) {
    global OpenerPlan, OpenerStep, BusyUntil, ActionSend, SwapWaitMs, CurrentWeapon, LastWeapon, LastWeaponSwapTick, AwaitingSwap, ExpectedWeapon, SwapPendingTick, Running, TargetWindow, OpenerActive

    weapon := startWeapon
    if (OpenerStep < 1)
        OpenerStep := 1

    i := OpenerStep
    while (i <= OpenerPlan.Length) {
        if !Running
            break
        if !WinActive(TargetWindow)
            break

        group := OpenerPlan[i]

        if (group.Length = 1 && group[1] = "SWAP") {
            ; perform swap using direct send
            SendEvent(ActionSend["SWAP"])
            LogEvent("SWAP", weapon)

            ; Immediately consider the swap done (no pixel confirmation) and switch internal state
            newWeapon := (weapon = "GS") ? "DS" : "GS"
            CurrentWeapon := newWeapon
            LastWeapon := newWeapon
            LastWeaponSwapTick := A_TickCount
            AwaitingSwap := false
            ExpectedWeapon := ""
            SwapPendingTick := 0

            ; reset loop position for the new weapon and give a short buffer
            SetLoopStep(CurrentWeapon, 1)
            BusyUntil := A_TickCount + ScaleMs(120)

            OpenerStep := i + 1
            i += 1
            continue
        }

        ; non-swap group: use existing executor
        if !ExecuteStepGroup(group, weapon)
            break

        OpenerStep := i + 1
        i += 1
    }

    ; on completion (or abort), ensure DS loop starts at 1
    SetLoopStep("DS", 1)
    OpenerActive := false
    OpenerStep := 1
}
