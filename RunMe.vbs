rem 0 = hidden window (not minimized, not visible)
rem False = don’t wait for script to finish

Set objShell = CreateObject("Wscript.Shell")
objShell.Run "pwsh -ExecutionPolicy Bypass -File FolderWatch.ps1", 0, False