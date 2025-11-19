param(
    [switch]$Hidden # start with hidden window
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    $reader = [System.IO.StreamReader]::new("$PSScriptRoot\FolderWatch.xaml")
    # setting XmlReaderSettings triggers full WPF parsing so we can make syntax errors visible to fix
    $xmlReaderSettings = [System.Xml.XmlReaderSettings]::new()
    $xmlReaderSettings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore
    $xmlReader = [System.Xml.XmlReader]::Create($reader, $xmlReaderSettings)

    $window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
}
catch [System.Windows.Markup.XamlParseException] {
    Write-Host "❌ XAML Parse Error: $($_.Exception.Message)"
    Add-Type -AssemblyName System.Windows.Forms
    # show message box for these kind of early errors to give visibility
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "WPF XAML Syntax Error") | Out-Null
    exit 2
}
catch {
    $err = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
    Write-Host "❌ Unexpected error: $err"
    Add-Type -AssemblyName System.Windows.Forms
    # show message box for these kind of early errors to give visibility
    [System.Windows.Forms.MessageBox]::Show($err, "WPF XAML Syntax Error") | Out-Null
    exit 3
}


$iconPath = Join-Path $PSScriptRoot 'FolderWatch.ico'
$window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath))

$watcherList = $window.FindName("WatcherList")
$logBox = $window.FindName("LogOutput")
$addButton = $window.FindName("AddButton")
$removeButton = $window.FindName("RemoveButton")
$exitButton = $window.FindName("ExitButton")

$global:window = $window
$global:logBox = $logBox

$iniPath = Join-Path $PSScriptRoot "FolderWatchConfig.ini"
$global:watchers = @()
$global:watcherEvents = @()

if (-not $global:logLines) { $global:logLines = New-Object System.Collections.Generic.List[string] }
function Add-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[$timestamp] $Message"
    $null = $global:logLines.Add($line)
    if ($global:logLines.Count -gt 500) { $global:logLines.RemoveRange(0, $global:logLines.Count - 500) }
    if ($logBox) {
        $window.Dispatcher.Invoke({
            $logBox.Text = ($global:logLines -join "`r`n")
            $logBox.ScrollToEnd()
        })
    }
}

# Auto-size last column when window size changes
$window.Add_SizeChanged({
    $gridView = $watcherList.View
    if ($gridView -and $gridView.Columns.Count -gt 1) {
        $totalWidth = $watcherList.ActualWidth
        $fixedWidth = 0
        for ($i = 0; $i -lt $gridView.Columns.Count - 1; $i++) {
            $fixedWidth += $gridView.Columns[$i].ActualWidth
        }
        $lastCol = $gridView.Columns[$gridView.Columns.Count - 1]
        $lastCol.Width = [Math]::Max(100, $totalWidth - $fixedWidth - 35)
    }
})

# Strongly-typed item with change notifications and observable collection for the ListView
if (-not ([System.Management.Automation.PSTypeName]'WatcherItem').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;

public class WatcherItem : INotifyPropertyChanged
{
    private string _folder;
    private string _command;

    public string Folder
    {
        get { return _folder; }
        set { if (_folder != value) { _folder = value; OnPropertyChanged("Folder"); } }
    }

    public string Command
    {
        get { return _command; }
        set { if (_command != value) { _command = value; OnPropertyChanged("Command"); } }
    }

    public WatcherItem() {}
    public WatcherItem(string folder, string command) { _folder = folder; _command = command; }

    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string name)
    {
        var handler = PropertyChanged;
        if (handler != null) handler(this, new PropertyChangedEventArgs(name));
    }
}
"@
}

$global:items = New-Object 'System.Collections.ObjectModel.ObservableCollection[WatcherItem]'
$watcherList.ItemsSource = $global:items

# Notify icon (system tray)
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconPath)
$trayIcon.Text = 'Folder Watcher'
$trayIcon.Visible = $true


# Left-click tray icon to toggle window visibility
$trayIcon.add_MouseClick({
    if ($_.Button -eq 'Left') {
        if ($window.IsVisible) {
            $window.Hide()
        } else {
            $window.Show()
            $window.Activate()
            $window.Topmost = $true; $window.Topmost = $false
        }
    }
})

function Import-WatchersFromIni {
    if (Test-Path $iniPath) {
        Get-Content $iniPath | ForEach-Object {
            if ($_ -match '^(.*)\|(.+)$') {
                $folder = $matches[1]
                $command = $matches[2]
                # Populate UI and register watchers when loading from INI
                Add-Watcher $folder $command $true
            }
        }
    }
}

function Save-WatchersToIni {
    $lines = @()
    foreach ($item in $watcherList.Items) {
        $lines += "$($item.Folder)|$($item.Command)"
    }
    $lines | Set-Content $iniPath
}

function Add-Watcher($folder, $command, $updateUI = $true) {
    if ($updateUI) {
        $entry = [WatcherItem]::new($folder, $command)
        $global:items.Add($entry) | Out-Null
    }

    Add-Log "Creating watcher for: $folder"
    Add-Log "Command: $command"

    try {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $folder
        $watcher.IncludeSubdirectories = $false
        $watcher.EnableRaisingEvents = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite'
        Add-Log "Watcher created successfully, EnableRaisingEvents=$($watcher.EnableRaisingEvents)"
    } catch {
        Add-Log "ERROR creating watcher: $_"
        throw
    }

    # Use a global synchronized hashtable for tracking pending executions
    if (-not $global:pendingExecutions) {
        $global:pendingExecutions = [hashtable]::Synchronized(@{})
    }
        $debounceMs = 500
        # Common temporary download suffixes to ignore (e.g., Edge/Chrome)
        $ignoreSuffixes = @('.crdownload', '.part', '.partial', '.tmp')

    # Use Register-ObjectEvent with debouncing that takes the LAST event that happens to any given folder within the debounce period
    $action = {
        param($eventSender, $waitEventArgs)

        function _EventLog {
            param([string]$Message)
            $timestamp = (Get-Date).ToString('HH:mm:ss')
            $line = "[$timestamp] $Message"
            $global:window.Dispatcher.Invoke({
                $global:logLines.Add($line)
                if ($global:logLines.Count -gt 500) { $global:logLines.RemoveRange(0, $global:logLines.Count - 500) }
                $global:logBox.Text = ($global:logLines -join "`r`n")
                $global:logBox.ScrollToEnd()
            })
        }

        _EventLog "Event fired: $($waitEventArgs.ChangeType) - $($waitEventArgs.FullPath)"

        $key = $waitEventArgs.FullPath
        $folder = $waitEvent.MessageData.Folder
        $command = $waitEvent.MessageData.Command
        $debounceMs = $waitEvent.MessageData.DebounceMs
        $scriptRoot = $waitEvent.MessageData.ScriptRoot
        $ignoreSuffixes = $waitEvent.MessageData.IgnoreSuffixes

        $lowerPath = $waitEventArgs.FullPath.ToLowerInvariant()
        foreach ($suffix in $ignoreSuffixes) {
            if ($lowerPath.EndsWith($suffix)) {
                _EventLog "Ignoring temp file event: $lowerPath (suffix $suffix)"
                return
            }
        }

        if ($global:pendingExecutions.ContainsKey($key)) {
            $global:pendingExecutions[$key].Stop()
            $global:pendingExecutions[$key].Dispose()
            _EventLog "Resetting debounce timer"
        }

        $timer = New-Object System.Timers.Timer
        $timer.Interval = $debounceMs
        $timer.AutoReset = $false

        $executeAction = {
            param($eventSender, $e)
            function _EventLogInner {
                param([string]$Message)
                $timestamp = (Get-Date).ToString('HH:mm:ss')
                $line = "[$timestamp] $Message"
                $global:window.Dispatcher.Invoke({
                    $global:logLines.Add($line)
                    if ($global:logLines.Count -gt 500) { $global:logLines.RemoveRange(0, $global:logLines.Count - 500) }
                    $global:logBox.Text = ($global:logLines -join "`r`n")
                    $global:logBox.ScrollToEnd()
                })
            }
            $command = $waitEvent.MessageData.Command
            $folder = $waitEvent.MessageData.Folder
            $scriptRoot = $waitEvent.MessageData.ScriptRoot
            $key = $waitEvent.MessageData.Key
            $expandedCommand = $command -replace '\{\{FOLDER\}\}', "`"$folder`""
            _EventLogInner "Executing after debounce: $expandedCommand"
            try {
                if ($expandedCommand -match '^([^\s]+)\s*(.*)$') {
                    Start-Process $matches[1] -ArgumentList $matches[2] -WorkingDirectory $scriptRoot
                } else {
                    Start-Process $expandedCommand -WorkingDirectory $scriptRoot
                }
                _EventLogInner "Success"
            } catch {
                _EventLogInner "Error: $_"
            }
            if ($global:pendingExecutions.ContainsKey($key)) {
                $global:pendingExecutions.Remove($key)
                _EventLogInner "Completed debounce for $key"
            }
        }

        $timerMessageData = @{
            Command = $command
            Folder = $folder
            ScriptRoot = $scriptRoot
            Key = $key
        }

        Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action $executeAction -MessageData $timerMessageData | Out-Null
        $timer.Start()
        $global:pendingExecutions[$key] = $timer
    }

    $messageData = @{
        Folder = $folder
        Command = $command
        DebounceMs = $debounceMs
        ScriptRoot = $PSScriptRoot
            IgnoreSuffixes = $ignoreSuffixes
    }

    $created = Register-ObjectEvent $watcher "Created" -Action $action -MessageData $messageData
    $changed = Register-ObjectEvent $watcher "Changed" -Action $action -MessageData $messageData
    
    Add-Log "Registered events: Created=$($created.Id), Changed=$($changed.Id)"
    $global:watchers += $watcher
    $global:watcherEvents += @($created, $changed)
}

# Retrieve routed commands from XAML resources
$editFolderCommand = $window.Resources['EditFolderCommand']
$editCommandCommand = $window.Resources['EditCommandCommand']

# Find CommandBindings and attach Execute handlers
$editFolderBinding = $window.CommandBindings | Where-Object { $_.Command -eq $editFolderCommand } | Select-Object -First 1
$editCommandBinding = $window.CommandBindings | Where-Object { $_.Command -eq $editCommandCommand } | Select-Object -First 1

function Update-WatcherAtIndex($item, $newFolder, $newCmd) {
    $index = $global:items.IndexOf($item)
    if ($index -lt 0) { return }
    $item.Folder = $newFolder
    $item.Command = $newCmd

    # Dispose old watcher and unregister events
    if ($global:watchers[$index]) { $global:watchers[$index].Dispose() }
    if ($global:watcherEvents[2*$index]) { Unregister-Event -SubscriptionId $global:watcherEvents[2*$index].Id -ErrorAction SilentlyContinue }
    if ($global:watcherEvents[2*$index + 1]) { Unregister-Event -SubscriptionId $global:watcherEvents[2*$index + 1].Id -ErrorAction SilentlyContinue }

    # Create new watcher (appends to arrays)
    Add-Watcher $newFolder $newCmd $false

    # Move new watcher/events to correct index
    $global:watchers[$index] = $global:watchers[$global:watchers.Count - 1]
    $global:watcherEvents[2*$index] = $global:watcherEvents[$global:watcherEvents.Count - 2]
    $global:watcherEvents[2*$index + 1] = $global:watcherEvents[$global:watcherEvents.Count - 1]
    
    # Trim arrays
    if ($global:watchers.Count -gt 1) {
        $global:watchers = $global:watchers[0..($global:watchers.Count - 2)]
        $global:watcherEvents = $global:watcherEvents[0..($global:watcherEvents.Count - 3)]
    }
    
    Save-WatchersToIni
}

$editFolderBinding.Add_Executed({
    param($eventSender, $e)
    $item = $e.Parameter
    if (-not $item) { return }
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $item.Folder
    if ($dialog.ShowDialog() -eq 'OK') {
        Update-WatcherAtIndex $item $dialog.SelectedPath $item.Command
    }
})

$editCommandBinding.Add_Executed({
    param($eventSender, $e)
    $item = $e.Parameter
    if (-not $item) { return }
    $cmd = [Microsoft.VisualBasic.Interaction]::InputBox('Edit command:', 'Command Edit', $item.Command)
    if ($cmd) {
        Update-WatcherAtIndex $item $item.Folder $cmd
    }
})

# Button handlers
$addButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") {
        $cmd = [Microsoft.VisualBasic.Interaction]::InputBox("Enter command to run on change:", "Command Input")
        if ($cmd) {
            Add-Watcher $dialog.SelectedPath $cmd
            Save-WatchersToIni
        }
    }
})

$removeButton.Add_Click({
    $selected = $watcherList.SelectedItem
    if ($selected) {
        $index = $global:items.IndexOf($selected)
        $global:items.RemoveAt($index)

        # Dispose watcher and unregister events
        $global:watchers[$index].Dispose()
        if ($global:watcherEvents[2*$index]) { Unregister-Event -SubscriptionId $global:watcherEvents[2*$index].Id -ErrorAction SilentlyContinue }
        if ($global:watcherEvents[2*$index + 1]) { Unregister-Event -SubscriptionId $global:watcherEvents[2*$index + 1].Id -ErrorAction SilentlyContinue }
        
        # Remove from arrays
        $global:watchers = $global:watchers[0..($index - 1)] + $global:watchers[($index + 1)..($global:watchers.Count - 1)]
        $global:watcherEvents = $global:watcherEvents[0..(2*$index - 1)] + $global:watcherEvents[(2*$index + 2)..($global:watcherEvents.Count - 1)]

        Save-WatchersToIni
    }
})

$exitButton.Add_Click({
    $window.Close()
    $app = [System.Windows.Application]::Current
    if ($app) {
        $app.Shutdown()
    } else {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    }
})

# Intercept window closing to keep tray running; hide instead of closing
$window.add_Closing({
    $_.Cancel = $true
    $window.Hide()
})

# Process PowerShell event queue periodically
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    $waitEvent = Wait-Event -Timeout 0 -ErrorAction SilentlyContinue
    if ($waitEvent) { Remove-Event -EventIdentifier $waitEvent.EventIdentifier -ErrorAction SilentlyContinue }
})
$timer.Start()

Import-WatchersFromIni
$Hidden ? $window.Hide() : $window.Show() | Out-Null

[System.Windows.Threading.Dispatcher]::Run()