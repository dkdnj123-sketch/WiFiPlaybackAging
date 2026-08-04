Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
strFolder = objFSO.GetParentFolderName(WScript.ScriptFullName)
objShell.CurrentDirectory = strFolder
objShell.Run """" & strFolder & "\WiFiPlaybackAging_run.bat""", 0, False
