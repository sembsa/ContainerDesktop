# Installs the Container Desktop display helper: compiles display-helper.cs
# (expected beside this script) into C:\ProgramData\ContainerDesktop and
# registers a logon task that runs it in whichever user's session signs in.
# Runs elevated: from cd-setup.cmd at first logon, or as SYSTEM through the
# guest agent.
$ErrorActionPreference = 'Stop'
$dst = 'C:\ProgramData\ContainerDesktop'
$name = 'ContainerDesktop Display'
$exe = Join-Path $dst 'display-helper.exe'
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# A running helper keeps its .exe locked.
Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
Get-Process -Name 'display-helper' -ErrorAction SilentlyContinue | Stop-Process -Force -PassThru | Wait-Process -Timeout 10

$src = Join-Path $PSScriptRoot 'display-helper.cs'
if ((Resolve-Path $src).Path -ne (Join-Path $dst 'display-helper.cs')) { Copy-Item $src $dst -Force }
Remove-Item $exe -Force -ErrorAction SilentlyContinue
# A Windows-subsystem program never opens a console window.
Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $dst 'display-helper.cs')) `
    -OutputAssembly $exe -OutputType WindowsApplication

$action = New-ScheduledTaskAction -Execute $exe
$trigger = New-ScheduledTaskTrigger -AtLogOn
# The Users group: the task runs as whoever signs in, without a stored password
# and without elevation.
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
# Someone is usually signed in already (autologon); start it for them now.
Start-ScheduledTask -TaskName $name
"installed"
