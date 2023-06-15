#Requires AutoHotkey v2.0+
#MaxThreadsPerHotkey 3
`::  ; Win+Z hotkey (change this hotkey to suit your preferences).
{
    static KeepLoopRunning := false
    if KeepLoopRunning  ; This means an underlying thread is already running the loop below.
    {
        KeepLoopRunning := false  ; Signal that thread's loop to stop.
        return  ; End this thread so that the one underneath will resume and see the change made by the line above.
    }
    ; Otherwise:
    KeepLoopRunning := true
    Loop
    {
        ; The next four lines are the action you want to repeat (update them to suit your preferences):
            SendInput "{RButton}{LButton}{Space}{1}{2}{3}{4}"
            Sleep 100
        ; But leave the rest below unchanged.
        if not KeepLoopRunning  ; The user signaled the loop to stop by pressing Win-Z again.
            break  ; Break out of this loop.
    }
    KeepLoopRunning := false  ; Reset in preparation for the next press of this hotkey.
}
#MaxThreadsPerHotkey 1