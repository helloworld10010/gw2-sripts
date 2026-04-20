#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn

CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")

global PickerOn := true

SetTimer(UpdateOverlay, 50)

F8:: {
    global PickerOn
    PickerOn := !PickerOn

    if PickerOn {
        ShowTip("Pixel picker ON")
    } else {
        ToolTip()
        ShowTip("Pixel picker OFF")
    }
}

F9:: {
    CopyMousePos()
}

F6:: {
    CopyPixelColor()
}

F7:: {
    CopyPixelInfo()
}

F10:: {
    ExitApp()
}

UpdateOverlay() {
    global PickerOn

    if !PickerOn
        return

    x := 0
    y := 0
    MouseGetPos(&x, &y)
    color := PixelGetColor(x, y, "RGB")
    rgb := Format("0x{:06X}", color)
    text := "X: " x "  Y: " y "`nColor: " rgb
    ToolTip(text, x + 16, y + 16)
}

CopyMousePos() {
    x := 0
    y := 0
    MouseGetPos(&x, &y)
    A_Clipboard := x "," y
    ShowTip("Copied pos: " x "," y)
}

CopyPixelColor() {
    x := 0
    y := 0
    MouseGetPos(&x, &y)
    color := PixelGetColor(x, y, "RGB")
    rgb := Format("0x{:06X}", color)
    A_Clipboard := rgb
    ShowTip("Copied color: " rgb)
}

CopyPixelInfo() {
    x := 0
    y := 0
    MouseGetPos(&x, &y)
    color := PixelGetColor(x, y, "RGB")
    rgb := Format("0x{:06X}", color)
    A_Clipboard := x "," y " = " rgb
    ShowTip("Copied: " x "," y " = " rgb)
}

ShowTip(text) {
    ToolTip(text, 20, 20)
    SetTimer(ClearTip, -900)
}

ClearTip() {
    ToolTip()
}
