Set sh = CreateObject("WScript.Shell")
p = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & p & "OkxPnl.ps1""", 0, False
