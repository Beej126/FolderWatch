rem 0 = hidden window (not minimized, not visible)
rem False = don’t wait for script to finish

rem This wrapper forwards any arguments supplied to the VBScript
rem (e.g., shortcut target: wscript.exe "RunMe.vbs" -Hidden)

Set objShell = CreateObject("Wscript.Shell")

Dim i, arg, forwarded
forwarded = ""
If WScript.Arguments.Count > 0 Then
	For i = 0 To WScript.Arguments.Count - 1
		arg = WScript.Arguments(i)
		' Quote arguments containing spaces
		If InStr(arg, " ") > 0 Then
			' Surround with double quotes
			arg = """" & arg & """"
		End If
		forwarded = forwarded & " " & arg
	Next
End If

objShell.Run "pwsh -ExecutionPolicy Bypass -File FolderWatch.ps1" & forwarded, 0, False