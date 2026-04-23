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

global TargetWindow := "ahk_exe Gw2-64.exe" ; 目标窗口（GW2 可执行），仅在此窗口激活时脚本生效
global Running := false ; 脚本循环是否开启（由 MButton 切换）
global BusyUntil := 0 ; 时间戳：在此时间前不发起新动作（用于施放时间与缓冲）
global TimingScale := 1.1 ; 全局时间缩放因子（用于 ScaleMs 调整所有延迟）
global LastWeapon := "" ; 上一次检测到的武器（"GS" 或 "DS"）
global LastSwapAttempt := 0 ; 最近一次尝试换武的时间戳（防止短时间内重复尝试）
global LastWeaponSwapTick := 0 ; 最近一次确认（或更新）为换武的时间戳
global LastAction := "" ; 最近一次发送的动作标识（例如 "4"、"F5"）
global LastActionTick := 0 ; 上次发送动作的时间戳
global LastF5Tick := 0 ; 最近一次 F5 动作的时间戳（特殊追踪）
global AwaitingSwap := false ; 是否处于等待像素确认换武的中间状态（UI 像素未确认）
global ExpectedWeapon := "" ; 若 AwaitingSwap 为 true，此字段记录期望切换到的武器
global SwapPendingTick := 0 ; 何时开始等待换武确认（用于超时判断）
global SwapWaitMs := ScaleMs(1100) ; 等待像素确认换武的最大超时（毫秒）
global SwapConfirmMs := ScaleMs(550) ; 确认换武成功所需的最小等待时间（毫秒）
global CurrentWeapon := "" ; 当前内部记录的武器状态（"GS" 或 "DS"）
global LogFilePath := "" ; 记录日志的文件路径（每次启动会创建新日志）
global F5Armed := false ; 是否处于可配合 F5 的“蓄力/已装填”状态（opener 特殊逻辑）
global F5ArmedTick := 0 ; 标记 F5Armed 的时间戳
global OpenerActive := false ; 是否启用开手序列（脚本启动时根据武器决定）
global OpenerStep := 1 ; OpenerPlan 的当前执行索引（从 1 开始）
global OpenerSubStep := 1 ; 当前组内的子索引
global BurstActive := false ; 是否处于爆发模式
global BurstStep := 1 ; 爆发模式当前进度
global BurstActionTick := 0 ; 记录当前爆发动作开始的时间戳
global BurstRiftActive := false ; 是否已开启裂隙
global BurstPlan := ["4", "F5", "2", "3", "5", "7", "8", "0", "6", "4", "2", "3", "4", "2", "3", "5", "7", "8", "0", "6", "4", "2", "3"] 
global RepeatingKey := "" ; 当前正在重复点击的按键
global RepeatUntil := 0 ; 重复点击的截止时间戳
global LastRepeatTick := 0 ; 上次重复点击的时间戳
global OpenerPlan := [
    ["3"],       ; 每个子数组为一组按键，按顺序发送
    ["5", "2"],
    ["SWAP"],    ; 特殊标记 SWAP 表示执行换武
    ["2"],
    ["4"],
    ["F5"],
    ["6"],
    ["4"],
    ["7", "8"],
    ["2", "3"],
    ["0"],
    ["4", "7"],
    ["8", "6"],
    ["4", "2"],
    ["3"],
    ["SWAP"]
]

global CastBuffer := 90 ; 主技能（1-5）施放后保留的缓冲时间（毫秒），用于 BusyUntil，防止过早发送下一动作
global UtilityBuffer := 90 ; 功能/非直接施法按键（F键、SWAP 等）的缓冲时间（毫秒）
global SwapRetryMs := ScaleMs(700) ; 换武尝试的最小间隔，避免短时间内重复触发换武
global SwapSend := "{``}" ; 发送换武的按键（虚拟键或映射），可根据按键映射修改
global CastRepeatMs := ScaleMs(60) ; 在施法持续时间内重复发送按键的间隔（毫秒），用于 SendDuringCast

global WeaponIndicator := [842, 1034] ; 屏幕像素坐标：武器指示器（DetectWeapon 读取此像素判断当前武器）
global WeaponIndicatorColor := 0x020102 ; 识别为大剑的精确颜色
global IllusionIndicator := [827, 946] ; 屏幕像素坐标：幻影充能指示器（HasFullIllusions 使用）
global FullIllusionColor := 0x212429 ; 幻影满充时的像素颜色（与 PixelGetColor 返回值比较以判定是否满）
global PowerSpikeIndicator := [1194, 1023] ; 屏幕像素坐标：能量突发（power spike）指示器（用于 CanCastPowerSpike）
global PowerSpikeFullColor := 0xFFFFFF ; 能量突发满时的像素颜色（用于比较）

; Persistent pixel debug tooltip (chat-like, scrolling)
global PixelDebugVisible := true ; 是否显示持久像素调试窗口（可通过 F8 切换）
global PixelDebugLines := []      ; 持久 tooltip 的行缓冲
global PixelDebugMaxLines := 14   ; 最大保留行数（超过则向上滚动）


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
    "4", 1220,
    "5", 500
)

global DSDelays := Map(
    "1", 500,
    "2", 0,
    "3", 0,
    "4", 2250,
    "5", 1050
)

global UtilityDelays := Map(
    "6", 1000,
    "7", 750,
    "8", 700,
    "0", 1000,
)

global GSPlan := ["4", "2", "3", "FILL", "2", "FILL", "3", "4","6","4", "2", "SWAP"] ; GS（Greatsword）循环计划序列：按键或特殊标记（FILL/SWAP）
global DSPlan := ["5","2","3","FILL","2","FILL","2","5","3","SWAP"] ; DS（Dagger+Sword）循环计划

global GsStep := 0 ; 当前在 GSPlan 中的索引（1 起算）；0 表示尚未初始化或待恢复
global DsStep := 0 ; 当前在 DSPlan 中的索引（逻辑同上）

; Filler windows use q/e/z, then r on full charges, then auto attack.
global FillerPriority := ["7", "8", "0"] ; 当主序列不可用时尝试的填充技能优先级（例如 q/e/z）

if (A_Args.Length && A_Args[1] == "--syntax-check")
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

RunBurst(weapon) {
    global BurstPlan, BurstStep, BurstActive, BurstActionTick, BusyUntil, BurstRiftActive

    if (BurstStep > BurstPlan.Length) {
        BurstActive := false
        BurstStep := 1
        BurstRiftActive := false
        return
    }

    action := BurstPlan[BurstStep]
    isInstant := RegExMatch(action, "^(F[1-5]|9)$")

    ; 1. 基础忙碌检查 (非瞬发技能需要等待 GCD)
    if (!isInstant && A_TickCount < BusyUntil) {
        return
    }

    ; 2. 特殊处理: F5 延迟开启 (4 读条 500ms 后触发)
    if (action == "F5") {
        if (A_TickCount - BurstActionTick < 50) {
            return
        }
        if (!IsReady("F5")) {
            ; 如果 F5 还没好（可能因为之前的操作干扰），我们不能跳过它，
            ; 因为它是爆发的核心。如果超时太久则取消整个爆发。
            if (A_TickCount - BurstActionTick > 2000) {
                BurstActive := false
            }
            return
        }
    }

    ; 3. 贪婪逻辑: 如果不是 F5 或 4 (这两个是触发器)，且技能没就绪，直接跳过试下一个
    if (action != "F5" && action != "4") {
        if (!IsReady(action)) {
            BurstStep += 1
            return ; 下一帧尝试序列中的下一个技能
        }
    }

    ; 4. 执行动作
    if CastAction(action, weapon) {
        if (action == "F5") {
            BurstRiftActive := true
        }
        BurstStep += 1
        BurstActionTick := A_TickCount
    }
}

ToggleRotation() {
    global Running, BusyUntil, GsStep, DsStep, AwaitingSwap, ExpectedWeapon, CurrentWeapon, LastWeapon, OpenerActive, OpenerStep, OpenerSubStep, RepeatingKey, RepeatUntil, F5Armed, F5ArmedTick, LogFilePath
    global BurstActive, BurstStep, BurstRiftActive

    Running := !Running
    BusyUntil := 0

    if Running {
        GsStep := 0
        DsStep := 0
        AwaitingSwap := false
        ExpectedWeapon := ""
        CurrentWeapon := DetectWeapon()
        LastWeapon := CurrentWeapon
        OpenerActive := (CurrentWeapon == "DS")
        OpenerStep := 1
        OpenerSubStep := 1
        BurstActive := false
        BurstStep := 1
        BurstRiftActive := false
        RepeatingKey := ""
        RepeatUntil := 0
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
    global GsStep, DsStep, LastWeapon, LastSwapAttempt, LastWeaponSwapTick, BusyUntil, LastAction, LastActionTick, LastF5Tick, AwaitingSwap, ExpectedWeapon, SwapPendingTick, CurrentWeapon, F5Armed, F5ArmedTick, OpenerActive, OpenerStep, OpenerSubStep
    global BurstActive, BurstStep

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
    OpenerSubStep := 1
    BurstActive := false
    BurstStep := 1
}

RotationTick() {
    global TargetWindow, Running, BusyUntil, CurrentWeapon, AwaitingSwap, ExpectedWeapon, SwapPendingTick, SwapConfirmMs, SwapWaitMs, LastWeapon, LastWeaponSwapTick, F5Armed, F5ArmedTick, OpenerActive, OpenerStep, BurstActive, BurstStep, RepeatingKey, RepeatUntil, LastRepeatTick, CastRepeatMs

    if !Running
        return

    if !WinActive(TargetWindow)
        return

    weapon := CurrentWeapon

    ; Handle non-blocking key repetition (spamming the key during cast)
    ; Moved to top so it runs even during BurstActive delay
    if (A_TickCount < RepeatUntil && RepeatingKey != "") {
        if (A_TickCount - LastRepeatTick >= CastRepeatMs) {
            SendEvent(RepeatingKey)
            LastRepeatTick := A_TickCount
        }
    }

    ; --- 优先级 1: 爆发模式执行 ---
    if BurstActive {
        RunBurst(weapon)
        return
    }

    ; --- 优先级 2: 爆发模式触发检测 (GS + F5 + 4 + 6 + 满幻影) ---
    if (!OpenerActive && weapon == "GS" && IsReady("F5") && IsReady("4") && IsReady("6") && HasFullIllusions()) {
        BurstActive := true
        BurstStep := 1
        RunBurst(weapon)
        return
    }

    if AwaitingSwap {
        detected := DetectWeapon()
        ; use detected to confirm swap
        if (detected == ExpectedWeapon && (A_TickCount - SwapPendingTick >= SwapConfirmMs)) {
            CurrentWeapon := detected
            weapon := CurrentWeapon
            LastWeapon := weapon
            LastWeaponSwapTick := A_TickCount
            AwaitingSwap := false
            SwapPendingTick := 0
            ExpectedWeapon := ""
            SetLoopStep(weapon, 1)
            BusyUntil := Max(BusyUntil, A_TickCount + ScaleMs(300))
            LogEvent("SWAP_CONFIRMED", weapon, PixelSnapshot())
            if (OpenerActive && OpenerStep > OpenerPlan.Length) {
                OpenerActive := false
                OpenerStep := 1
                return
            }
        } else if (A_TickCount - SwapPendingTick >= SwapWaitMs) {
            ; timeout: adopt whatever the UI currently shows
            AwaitingSwap := false
            SwapPendingTick := 0
            CurrentWeapon := detected
            LastWeapon := detected
            LastWeaponSwapTick := A_TickCount
            ExpectedWeapon := ""
            SetLoopStep(CurrentWeapon, 1)
            BusyUntil := Max(BusyUntil, A_TickCount + ScaleMs(300))
            LogEvent("SWAP_TIMEOUT", CurrentWeapon, "detected=" . detected . " " . PixelSnapshot())
            if (OpenerActive && OpenerStep > OpenerPlan.Length) {
                OpenerActive := false
                OpenerStep := 1
                return
            }
        } else {
            return
        }
    }

    if OpenerActive {
        AdvanceOpener(weapon)
        return
    }

    if TrySequence(weapon)
        return

    if (A_TickCount < BusyUntil) {
        return
    }
}

AdvanceOpener(weapon) {
    global OpenerPlan, OpenerStep, OpenerSubStep, BusyUntil, OpenerActive, LastSwapAttempt, SwapRetryMs, AwaitingSwap, Running, TargetWindow

    if (OpenerStep > OpenerPlan.Length) {
        OpenerActive := false
        OpenerStep := 1
        OpenerSubStep := 1
        return
    }

    group := OpenerPlan[OpenerStep]
    
    if (OpenerSubStep > group.Length) {
        OpenerStep += 1
        OpenerSubStep := 1
        return
    }

    action := group[OpenerSubStep]
    isInstant := RegExMatch(action, "^(F[1-5]|9)$")

    ; If not instant, we must wait for previous cast to finish
    if (!isInstant && A_TickCount < BusyUntil) {
        return
    }

    if (action == "SWAP") {
        if (A_TickCount - LastSwapAttempt >= SwapRetryMs && IsReady("SWAP")) {
            LastSwapAttempt := A_TickCount
            if CastAction("SWAP", weapon) {
                OpenerSubStep += 1
            }
        }
        return
    }

    if CastAction(action, weapon) {
        OpenerSubStep += 1
    }
}

; Removed redundant blocking functions: RunOpener, ExecuteStepGroup, TryOpenerSequence, TryPrioritySkills, ShouldCastF5


TrySequence(weapon) {
    global GSPlan, DSPlan, LastSwapAttempt, SwapRetryMs

    plan := (weapon == "GS") ? GSPlan : DSPlan
    step := GetLoopStep(weapon)
    if (step < 1 || step > plan.Length) {
        step := 1
        SetLoopStep(weapon, step)
    }

    action := plan[step]

    if (action == "FILL") {
        nextAction := plan[step + 1]
        if IsReady(nextAction) {
            SetLoopStep(weapon, step + 1)
            return false
        }
        return TryFiller(weapon)
    }

    if (action == "SWAP") {
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
    global ActionSend, BusyUntil, LastAction, LastActionTick, LastF5Tick, AwaitingSwap, ExpectedWeapon, SwapPendingTick, CurrentWeapon, LastWeapon, F5Armed, F5ArmedTick, OpenerActive, LastSwapAttempt
    global RepeatingKey, RepeatUntil, LastRepeatTick

    if !ActionSend.Has(action)
        return false

    castMs := GetActionDelay(action, weapon)
    bufferMs := GetActionBuffer(action)

    ; Removed DetectWeapon from here. We trust CurrentWeapon.
    ; Weapon updates only happen during the SWAP confirmation phase in RotationTick.

    ; Send the key once immediately
    key := ActionSend[action]
    SendEvent(key)
    LogEvent(action, weapon)

    ; Initialize non-blocking repetition if there is a cast time
    isInstant := RegExMatch(action, "^(F[1-5]|9)$")

    if (castMs > 0 && !isInstant) {
        RepeatingKey := key
        RepeatUntil := A_TickCount + castMs
        LastRepeatTick := A_TickCount
    } else {
        ; If instant, we do NOT clear the existing repetition (could be casting another skill)
        if (!isInstant) {
            RepeatingKey := ""
            RepeatUntil := 0
        }
    }

    ; Calculate how long we are busy for the NEXT action
    ; Instant skills do NOT update BusyUntil
    if (!isInstant) {
        BusyUntil := A_TickCount + castMs + bufferMs
    }
    
    LastAction := action
    LastActionTick := A_TickCount
    if (action == "F5") {
        LastF5Tick := A_TickCount
        F5Armed := false
        F5ArmedTick := 0
    }
    if (OpenerActive && weapon == "GS" && (action == "4" || action == "0")) {
        F5Armed := true
        F5ArmedTick := A_TickCount
    }

    if (action == "SWAP") {
        newWeapon := (weapon == "GS") ? "DS" : "GS"
        AwaitingSwap := true
        ExpectedWeapon := newWeapon
        SwapPendingTick := A_TickCount
        LogEvent("SWAP_INIT", weapon, "Expected=" . ExpectedWeapon)
    }
    
    return true
}

; Simplified non-blocking SendEvent
SendOnce(action, weapon) {
    global ActionSend
    key := ActionSend[action]
    SendEvent(key)
    LogEvent(action, weapon)
}


GetActionDelay(action, weapon) {
    global GSDelays, DSDelays, UtilityDelays, TimingScale

    if (action == "SWAP")
        return ScaleMs(650)

    ; Utility-level delays take precedence if defined
    if (IsObject(UtilityDelays) && UtilityDelays.Has(action))
        return ScaleMs(UtilityDelays[action])

    if (weapon == "GS" && GSDelays.Has(action))
        return ScaleMs(GSDelays[action])

    if (weapon == "DS" && DSDelays.Has(action))
        return ScaleMs(DSDelays[action])

    return 0
}

GetActionBuffer(action) {
    global CastBuffer, UtilityBuffer

    if (action == "SWAP")
        return ScaleMs(900)

    if RegExMatch(action, "^[1-5]$")
        return ScaleMs(CastBuffer)

    return ScaleMs(UtilityBuffer)
}

DetectWeapon(stable := false, samples := 5, delayMs := 18) {
    global WeaponIndicator, WeaponIndicatorColor, PixelDebugVisible, CurrentWeapon

    color := PixelGetColor(WeaponIndicator[1], WeaponIndicator[2], "RGB")
    
    ; If the pixel is pure black, it's probably a cooldown or UI transition.
    ; Stay with the current weapon rather than making a wild guess.
    if (color == 0x000000) {
        return CurrentWeapon
    }

    detected := (color == WeaponIndicatorColor) ? "GS" : "DS"
    if (PixelDebugVisible) {
        PixelDebugPush("Weapon pixel @" . WeaponIndicator[1] . "," . WeaponIndicator[2] . " color=0x" . Format("{:06X}", color) . " -> " . detected)
    }
    return detected
}

GetLoopStep(weapon) {
    global GsStep, DsStep
    return (weapon == "GS") ? GsStep : DsStep
}

SetLoopStep(weapon, step) {
    global GsStep, DsStep

    if (weapon == "GS") {
        GsStep := step
    } else {
        DsStep := step
    }
}

; Resume-step detection removed.
; The script no longer attempts to infer a resume step from skill readiness.
; On (re)start it will use DetectWeapon() and start the corresponding loop
; (Opener for DS; GS loop for GS).

HasFullIllusions() {
    global IllusionIndicator, FullIllusionColor

    color := PixelGetColor(IllusionIndicator[1], IllusionIndicator[2], "RGB")
    return (color != FullIllusionColor)
}

CanCastPowerSpike() {
    global PowerSpikeIndicator, PowerSpikeFullColor

    color := PixelGetColor(PowerSpikeIndicator[1], PowerSpikeIndicator[2], "RGB")
    return (color == PowerSpikeFullColor)
}

IsReady(skill) {
    global SkillPixels

    if !SkillPixels.Has(skill) {
        if (PixelDebugVisible)
            PixelDebugPush("IsReady: unknown skill " . skill)
        return false
    }

    pos := SkillPixels[skill]
    color := PixelGetColor(pos[1], pos[2], "RGB")
    ready := !IsBlack(color)
    if (PixelDebugVisible) {
        PixelDebugPush("Skill " . skill . " @" . pos[1] . "," . pos[2] . " color=0x" . Format("{:06X}", color) . " ready=" . (ready ? "1" : "0"))
    }
    return ready
}

IsBlack(color) {
    return (color == 0x000000)
}

ShowTip(text) {
    ToolTip(text)
    SetTimer(ClearTip, -900)
}

ClearTip() {
    ToolTip()
}

; Persistent pixel debug log (file-based)
PixelDebugPush(msg) {
    global PixelDebugLines, PixelDebugMaxLines, PixelDebugVisible, LogFilePath
    if (!PixelDebugVisible)
        return

    now := A_Now
    ms := Mod(A_TickCount, 1000)
    if (ms < 10)
        msStr := "00" . ms
    else if (ms < 100)
        msStr := "0" . ms
    else
        msStr := ms

    ts := SubStr(now,9,2) . ":" . SubStr(now,11,2) . ":" . SubStr(now,13,2) . "." . msStr
    line := "[" . ts . "] " . msg

    PixelDebugLines.Push(line)
    while (PixelDebugLines.Length > PixelDebugMaxLines)
        PixelDebugLines.RemoveAt(1)

    ; append to per-run log file so messages persist for analysis
    outFile := (LogFilePath != "") ? LogFilePath : "D:\\Code\\GW2Scripts\\chrono_log.txt"
    FileAppend(line . "`n", outFile)
}

PixelDebugClear() {
    global PixelDebugLines
    PixelDebugLines := []
    ToolTip()
}

PixelDebugToggle() {
    global PixelDebugVisible, LogFilePath
    PixelDebugVisible := !PixelDebugVisible
    if (!PixelDebugVisible) {
        outFile := (LogFilePath != "") ? LogFilePath : "D:\\Code\\GW2Scripts\\chrono_log.txt"
        FileAppend("[" . A_Now . "] PIXEL: PixelDebug: OFF`n", outFile)
    } else
        PixelDebugPush("PixelDebug: ON")

    ShowTip("PixelDebug " . (PixelDebugVisible ? "ON" : "OFF"))
}

F8:: {
    PixelDebugToggle()
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
        . "`nGS step=" GetLoopStep("GS")
        . "`nDS step=" GetLoopStep("DS")
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

PixelSnapshot() {
    global WeaponIndicator, SkillPixels
    ; sample weapon indicator and skills 1-5
    wcol := PixelGetColor(WeaponIndicator[1], WeaponIndicator[2], "RGB")
    s := "W=0x" . Format("{:06X}", wcol)
    for _, sk in ["1","2","3","4","5"] {
        pos := SkillPixels[sk]
        if (IsObject(pos)) {
            col := PixelGetColor(pos[1], pos[2], "RGB")
            s .= " " . sk . "=0x" . Format("{:06X}", col)
        }
    }
    return s
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

