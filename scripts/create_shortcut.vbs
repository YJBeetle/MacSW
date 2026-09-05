Set oWS = CreateObject("WScript.Shell")
programsDir = oWS.SpecialFolders("AllUsersPrograms")
swDir = programsDir & "\SOLIDWORKS 2025"

Set fso = CreateObject("Scripting.FileSystemObject")
If Not fso.FolderExists(swDir) Then
    fso.CreateFolder(swDir)
End If

sLinkFile = swDir & "\SOLIDWORKS 2025.lnk"
Set oLink = oWS.CreateShortcut(sLinkFile)
oLink.TargetPath = "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\SLDWORKS.exe"
oLink.WorkingDirectory = "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS"
oLink.Description = "SOLIDWORKS 2025"
oLink.Save

desktopDir = oWS.SpecialFolders("Desktop")
sDeskLink = desktopDir & "\SOLIDWORKS 2025.lnk"
Set oDeskLink = oWS.CreateShortcut(sDeskLink)
oDeskLink.TargetPath = "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\SLDWORKS.exe"
oDeskLink.WorkingDirectory = "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS"
oDeskLink.Description = "SOLIDWORKS 2025"
oDeskLink.Save

WScript.Echo "Shortcut created successfully!"
