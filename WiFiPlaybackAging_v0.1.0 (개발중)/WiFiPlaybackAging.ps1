Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

# wifi_aging_core.py는 adb/iperf3 자식 프로세스를 만든다. Job Object(kill-on-close)로
# GUI 종료/중지 시 프로세스 트리 전체가 한 번에 정리되도록 한다. (자매 프로젝트와 동일 패턴)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class JobObjectManager {
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr a, string lpName);

    [DllImport("kernel32.dll")]
    public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public static IntPtr CreateJobForProcess(IntPtr processHandle) {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        var extendedInfo = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        extendedInfo.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr ptr = Marshal.AllocHGlobal(length);
        try {
            Marshal.StructureToPtr(extendedInfo, ptr, false);
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, ptr, (uint)length);
        } finally {
            Marshal.FreeHGlobal(ptr);
        }
        AssignProcessToJobObject(job, processHandle);
        return job;
    }
}
"@

# ================================================================
# 전역 상태
# ================================================================
$global:MonProc      = $null
$global:MonJobHandle = $null
$global:MonOutQueue  = $null
$global:MonErrQueue  = $null
$global:MonEventSubs = @()
$global:MonRunning   = $false
$global:DeviceRows   = @{}   # IP -> DataGridViewRow
$global:LogDisplayOn = $true
$global:LastStatusLogTime = [datetime]::MinValue

$ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
$PyScript        = Join-Path $ScriptDir "wifi_aging_core.py"
$DeviceConfigFile = Join-Path $ScriptDir "device_config.json"
$RuntimeConfigFile = Join-Path $ScriptDir "_runtime_config.json"
$IconPath        = Join-Path $ScriptDir "WiFiPlaybackAging.ico"
$SettingsFile    = Join-Path $ScriptDir "WiFiPlaybackAging_settings.json"
$global:DefaultLogDir = Join-Path $ScriptDir "log"

$ErrorLogDir = Join-Path $ScriptDir "error_log"
if (-not (Test-Path $ErrorLogDir)) { New-Item -ItemType Directory -Path $ErrorLogDir -Force | Out-Null }
$ErrorLogFile = Join-Path $ErrorLogDir ("error_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-ErrorLog {
    param([string[]]$Message, [string]$Source = "General")
    try {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $lines = foreach ($m in $Message) { "[{0}] [{1}] {2}" -f $stamp, $Source, $m }
        Add-Content -Path $ErrorLogFile -Value $lines -Encoding UTF8
    } catch {}
}

function Write-FatalErrorLog {
    param([string]$Message, [string]$Source = "Fatal")
    try {
        $fname = "error_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")
        $fpath = Join-Path $ErrorLogDir $fname
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Source, $Message
        Add-Content -Path $fpath -Value $line -Encoding UTF8
    } catch {}
}

function Ensure-AdbInPath {
    $existing = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($existing) {
        Write-ErrorLog -Message "adb.exe 발견: $($existing.Source)" -Source "AdbPath"
        return
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools"),
        (Join-Path $env:USERPROFILE "AppData\Local\Android\Sdk\platform-tools"),
        "C:\platform-tools",
        "C:\Android\platform-tools",
        "C:\Program Files (x86)\Android\android-sdk\platform-tools",
        "C:\Program Files\Android\android-sdk\platform-tools",
        $ScriptDir
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c "adb.exe"))) {
            $env:PATH = "$c;$env:PATH"
            Write-ErrorLog -Message "adb.exe를 자동으로 찾아 PATH에 추가함: $c" -Source "AdbPath"
            return
        }
    }
    Write-ErrorLog -Message "adb.exe를 찾지 못했습니다. platform-tools 폴더를 PATH에 등록하거나 이 폴더에 adb.exe를 넣어주세요." -Source "AdbPath"
}
Ensure-AdbInPath

if (-not (Test-Path $DeviceConfigFile)) {
    @{ devices = @(); loader_ip = "" } | ConvertTo-Json | Set-Content -Path $DeviceConfigFile -Encoding UTF8
}

# ================================================================
# 메인 폼
# ================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "V-Audit WiFiPlaybackAging v0.1.0 (개발중) - 네트워크 계층 전용 (재생판정 없음)"
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = "CenterScreen"

[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-ErrorLog -Message $e.Exception.ToString() -Source "UI-Thread"
    Write-FatalErrorLog -Message $e.Exception.ToString() -Source "UI-Thread"
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    Write-ErrorLog -Message $e.ExceptionObject.ToString() -Source "AppDomain"
    Write-FatalErrorLog -Message $e.ExceptionObject.ToString() -Source "AppDomain"
})

if (Test-Path $IconPath) {
    try {
        $img = [System.Drawing.Image]::FromFile($IconPath)
        $bmp = New-Object System.Drawing.Bitmap $img
        $hIcon = $bmp.GetHicon()
        $form.Icon = [System.Drawing.Icon]::FromHandle($hIcon)
    } catch {}
}

# ---- 상단 컨트롤 패널 ----
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = "Top"
$topPanel.Height = 55

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "▶ 시작"
$btnStart.Location = New-Object System.Drawing.Point(10, 12)
$btnStart.Size = New-Object System.Drawing.Size(120, 30)

$btnDeviceManage = New-Object System.Windows.Forms.Button
$btnDeviceManage.Text = "기기 관리"
$btnDeviceManage.Location = New-Object System.Drawing.Point(140, 12)
$btnDeviceManage.Size = New-Object System.Drawing.Size(110, 30)

$chkLogDisplay = New-Object System.Windows.Forms.CheckBox
$chkLogDisplay.Text = "실시간 로그 표시"
$chkLogDisplay.Location = New-Object System.Drawing.Point(265, 16)
$chkLogDisplay.Size = New-Object System.Drawing.Size(130, 24)
$chkLogDisplay.Checked = $true

$lblScope = New-Object System.Windows.Forms.Label
$lblScope.Text = "이 도구는 재생화면을 확인하지 않습니다 (재생판정: FrameCheck 별도 실행)"
$lblScope.Location = New-Object System.Drawing.Point(410, 20)
$lblScope.Size = New-Object System.Drawing.Size(480, 20)
$lblScope.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "로그 폴더 열기"
$btnOpenFolder.Location = New-Object System.Drawing.Point(895, 12)
$btnOpenFolder.Size = New-Object System.Drawing.Size(110, 30)

$btnSettings = New-Object System.Windows.Forms.Button
$btnSettings.Text = "⚙ 설정"
$btnSettings.Size = New-Object System.Drawing.Size(90, 30)
$btnSettings.Location = New-Object System.Drawing.Point(1080, 12)

$topPanel.Controls.AddRange(@($btnStart, $btnDeviceManage, $chkLogDisplay, $lblScope, $btnOpenFolder, $btnSettings))

$topPanel.Add_Resize({
    $btnSettings.Left = $topPanel.ClientSize.Width - $btnSettings.Width - 15
    $btnSettings.Top = 12
    $btnOpenFolder.Left = $btnSettings.Left - $btnOpenFolder.Width - 10
})

# ---- 중앙 상태 테이블 ----
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.RowHeadersVisible = $false

try {
    $grid.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"Instance,NonPublic").SetValue($grid, $true, $null)
} catch {}

$cols = @(
    @{n="No"; h="No"; w=40},
    @{n="Ip"; h="IP 주소"; w=120},
    @{n="Role"; h="역할"; w=140},
    @{n="Connected"; h="연결상태"; w=90},
    @{n="Mbps"; h="Mbps (TCP)"; w=90},
    @{n="Retr"; h="Retr"; w=70},
    @{n="LastEvent"; h="최근 이벤트"; w=200},
    @{n="LastSeen"; h="갱신 시각"; w=90}
)
foreach ($c in $cols) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c.n; $col.HeaderText = $c.h; $col.ReadOnly = $true
    $grid.Columns.Add($col) | Out-Null
}

# ---- 실시간 로그 패널 ----
$logPanel = New-Object System.Windows.Forms.GroupBox
$logPanel.Text = "실행 로그"
$logPanel.Dock = "Fill"

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.Dock = "Fill"
$logBox.Font = New-Object System.Drawing.Font("Consolas", 11)
$logBox.BackColor = [System.Drawing.Color]::Black
$logBox.ForeColor = [System.Drawing.Color]::LightGreen
$logPanel.Controls.Add($logBox)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.Orientation = "Horizontal"
$split.Panel1MinSize = 120
$split.Panel2MinSize = 80
$split.SplitterWidth = 6
$split.Panel1.Controls.Add($grid)
$split.Panel2.Controls.Add($logPanel)

$form.Controls.Add($split)
$form.Controls.Add($topPanel)

# ================================================================
# 로그 출력
# ================================================================
function Trim-LogBox {
    if ($logBox.TextLength -lt 120000) { return }
    $lineCount = $logBox.GetLineFromCharIndex($logBox.TextLength) + 1
    if ($lineCount -gt 2000) {
        $cutIndex = $logBox.GetFirstCharIndexFromLine($lineCount - 1500)
        if ($cutIndex -gt 0) {
            $logBox.Select(0, $cutIndex)
            $logBox.SelectedText = ""
        }
    }
}

function Append-Log {
    param([string]$Text)
    if (-not $global:LogDisplayOn) { return }
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $logBox.AppendText("[$stamp] $Text`r`n")
    Trim-LogBox
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

# ================================================================
# 설정 저장/불러오기
# ================================================================
$global:Settings = [PSCustomObject]@{
    Port                      = 5201
    PcExe                     = ""
    SaveDir                   = $global:DefaultLogDir
    BandwidthMbps             = ""
    SplitMode                 = "time"
    SplitValue                = 60
    ReconnectFastThresholdSec = 30
    RetrWarnCount             = 50
    StallMbps                 = 1.0
    StatusLogIntervalMin      = 10
    LogDisplayOn              = $true
    WindowWidth               = 1180
    WindowHeight              = 760
    WindowLeft                = -1
    WindowTop                 = -1
    WindowState               = "Normal"
    SplitDistance             = 400
}

function Save-Settings {
    try {
        $global:Settings.LogDisplayOn = [bool]$chkLogDisplay.Checked
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
            $global:Settings.WindowWidth  = $form.Width
            $global:Settings.WindowHeight = $form.Height
            $global:Settings.WindowLeft   = $form.Left
            $global:Settings.WindowTop    = $form.Top
        }
        $global:Settings.WindowState = $form.WindowState.ToString()
        try { $global:Settings.SplitDistance = $split.SplitterDistance } catch {}
        $global:Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
    } catch {}
}

function Load-Settings {
    if (-not (Test-Path $SettingsFile)) { return }
    try {
        $s = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in @("Port","PcExe","SaveDir","BandwidthMbps","SplitMode","SplitValue",
                         "ReconnectFastThresholdSec","RetrWarnCount","StallMbps","StatusLogIntervalMin")) {
            if ($null -ne $s.$p) { $global:Settings.$p = $s.$p }
        }
        if ($null -ne $s.LogDisplayOn) { $chkLogDisplay.Checked = [bool]$s.LogDisplayOn }
        foreach ($p in @("WindowWidth","WindowHeight","SplitDistance")) {
            if ($null -ne $s.$p -and $s.$p -gt 0) { $global:Settings.$p = [int]$s.$p }
        }
        foreach ($p in @("WindowLeft","WindowTop")) {
            if ($null -ne $s.$p -and $s.$p -ge 0) { $global:Settings.$p = [int]$s.$p }
        }
        if ($null -ne $s.WindowState) { $global:Settings.WindowState = $s.WindowState }
    } catch {}
}

$chkLogDisplay.Add_CheckedChanged({
    $global:LogDisplayOn = $chkLogDisplay.Checked
    $split.Panel2Collapsed = -not $chkLogDisplay.Checked
    Save-Settings
})

# ================================================================
# 테마 (다크)
# ================================================================
function C($hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }
$Fonts = @{
    Font     = New-Object System.Drawing.Font("Segoe UI", 9)
    FontBold = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
}
$Theme = @{
    Bg = C("#1E1E1E"); PanelBg = C("#252526"); ControlBg = C("#333337"); Border = C("#3F3F46")
    GridRowA = C("#1E1E1E"); GridRowB = C("#2A2A2B"); GridLine = C("#5A5A5F")
    Selection = C("#0E5A8A"); Text = C("#E8E8E8"); TextMuted = C("#9D9D9D")
    Accent = C("#4FC3F7"); Green = C("#4CAF50"); Red = C("#E5534B"); Yellow = C("#FFC107")
}

function Set-DarkTheme {
    param($ctrl)
    if ($ctrl -eq $logBox) { return }
    switch -Regex ($ctrl.GetType().Name) {
        '^Form$' { $ctrl.BackColor = $Theme.Bg; $ctrl.ForeColor = $Theme.Text }
        '^Panel$' { $ctrl.BackColor = $Theme.PanelBg }
        '^GroupBox$' { $ctrl.BackColor = $Theme.Bg; $ctrl.ForeColor = $Theme.Accent; $ctrl.Font = $Fonts.FontBold }
        '^Button$' {
            $ctrl.FlatStyle = "Flat"
            $ctrl.FlatAppearance.BorderSize = 1
            $ctrl.FlatAppearance.BorderColor = $Theme.Border
            $ctrl.FlatAppearance.MouseOverBackColor = $Theme.Border
            $ctrl.BackColor = $Theme.ControlBg
            $ctrl.ForeColor = $Theme.Text
            $ctrl.Font = $Fonts.Font
            $ctrl.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
        '^Label$' { $ctrl.BackColor = [System.Drawing.Color]::Transparent; $ctrl.ForeColor = $Theme.TextMuted }
        '^(CheckBox|RadioButton)$' { $ctrl.BackColor = [System.Drawing.Color]::Transparent; $ctrl.ForeColor = $Theme.Text }
        '^TextBox$' { $ctrl.BackColor = $Theme.ControlBg; $ctrl.ForeColor = $Theme.Text; $ctrl.BorderStyle = "FixedSingle" }
        '^ComboBox$' { $ctrl.BackColor = $Theme.ControlBg; $ctrl.ForeColor = $Theme.Text; $ctrl.FlatStyle = "Flat" }
        '^NumericUpDown$' { $ctrl.BackColor = $Theme.ControlBg; $ctrl.ForeColor = $Theme.Text }
    }
    foreach ($child in @($ctrl.Controls)) { Set-DarkTheme -ctrl $child }
}

function Set-DarkGrid {
    param($g)
    $g.BackgroundColor = $Theme.Bg
    $g.GridColor = $Theme.GridLine
    $g.BorderStyle = "None"
    $g.CellBorderStyle = "Single"
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersDefaultCellStyle.BackColor = $Theme.PanelBg
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $Theme.Text
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $Theme.PanelBg
    $g.ColumnHeadersDefaultCellStyle.SelectionForeColor = $Theme.Text
    $g.ColumnHeadersDefaultCellStyle.Font = $Fonts.FontBold
    $g.ColumnHeadersHeight = 30
    $g.ColumnHeadersBorderStyle = "Single"
    $g.DefaultCellStyle.BackColor = $Theme.GridRowA
    $g.DefaultCellStyle.ForeColor = $Theme.Text
    $g.DefaultCellStyle.SelectionBackColor = $Theme.Selection
    $g.DefaultCellStyle.SelectionForeColor = $Theme.Text
    $g.DefaultCellStyle.Font = $Fonts.Font
    $g.RowTemplate.Height = 26
    $g.AlternatingRowsDefaultCellStyle.BackColor = $Theme.GridRowB
    $g.AlternatingRowsDefaultCellStyle.ForeColor = $Theme.Text
    $g.AlternatingRowsDefaultCellStyle.SelectionBackColor = $Theme.Selection
    $g.AlternatingRowsDefaultCellStyle.SelectionForeColor = $Theme.Text
    $g.ColumnHeadersDefaultCellStyle.Alignment = "MiddleCenter"
    foreach ($col in $g.Columns) { $col.DefaultCellStyle.Alignment = "MiddleCenter" }
}

function Register-StatusColorFormatting {
    param($g)
    $g.Add_CellFormatting({
        param($sender, $e)
        if ($sender.Columns[$e.ColumnIndex].Name -eq "Connected") {
            switch ($e.Value) {
                "연결됨" { $e.CellStyle.ForeColor = $Theme.Green }
                "끊김"   { $e.CellStyle.ForeColor = $Theme.Red }
                default  { $e.CellStyle.ForeColor = $Theme.TextMuted }
            }
        }
        if ($sender.Columns[$e.ColumnIndex].Name -eq "Role" -and $e.Value -like "loader*") {
            $e.CellStyle.ForeColor = $Theme.Accent
        }
    })
}

function Apply-ButtonAccents {
    $btnStart.Font = $Fonts.FontBold
    if ($global:MonRunning) {
        $btnStart.BackColor = $Theme.Red; $btnStart.ForeColor = [System.Drawing.Color]::White
        $btnStart.FlatAppearance.BorderColor = $Theme.Red
    } else {
        $btnStart.BackColor = $Theme.Green; $btnStart.ForeColor = [System.Drawing.Color]::White
        $btnStart.FlatAppearance.BorderColor = $Theme.Green
    }
    foreach ($b in @($btnDeviceManage, $btnOpenFolder)) {
        $b.BackColor = C("#546E7A"); $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::White
        $b.Font = $Fonts.FontBold
    }
    if ($btnSettings) {
        $btnSettings.BackColor = $Theme.ControlBg; $btnSettings.ForeColor = $Theme.Text
        $btnSettings.FlatAppearance.BorderColor = $Theme.Border
        $btnSettings.Font = $Fonts.Font
    }
}

function Apply-CurrentTheme {
    Set-DarkTheme -ctrl $form
    Set-DarkGrid -g $grid
    $split.BackColor = $Theme.GridLine
    Apply-ButtonAccents
    $form.Refresh()
    $grid.Refresh()
}

# ================================================================
# 기기 관리 다이얼로그 (최대 4대 권장, 그 중 1대만 TCP 부하 발생 loader로 지정)
# ================================================================
function Read-DeviceConfig {
    $cfg = [PSCustomObject]@{ devices = @(); loader_ip = "" }
    if (Test-Path $DeviceConfigFile) {
        try {
            $raw = Get-Content $DeviceConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw.devices) { $cfg.devices = @($raw.devices) }
            if ($raw.loader_ip) { $cfg.loader_ip = $raw.loader_ip }
        } catch {}
    }
    return $cfg
}

function Show-DeviceManageDialog {
    $current = Read-DeviceConfig

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "기기 관리 (권장 4대 — TC: WiFi Playback Aging)"
    $dlg.Size = New-Object System.Drawing.Size(520, 480)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblHelp = New-Object System.Windows.Forms.Label
    $lblHelp.Text = "IP를 입력하고, TCP 부하를 보낼 1대만 'Loader' 체크(단일 선택)."
    $lblHelp.Location = New-Object System.Drawing.Point(10, 8)
    $lblHelp.Size = New-Object System.Drawing.Size(480, 20)
    $dlg.Controls.Add($lblHelp)

    $devGrid = New-Object System.Windows.Forms.DataGridView
    $devGrid.Location = New-Object System.Drawing.Point(10, 32)
    $devGrid.Size = New-Object System.Drawing.Size(480, 300)
    $devGrid.AllowUserToAddRows = $true
    $devGrid.AllowUserToDeleteRows = $true
    $devGrid.RowHeadersVisible = $false
    $devGrid.AutoSizeColumnsMode = "Fill"

    $colIp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colIp.Name = "Ip"; $colIp.HeaderText = "IP 주소"
    $devGrid.Columns.Add($colIp) | Out-Null

    $colLoader = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colLoader.Name = "Loader"; $colLoader.HeaderText = "Loader(TCP 부하)"
    $devGrid.Columns.Add($colLoader) | Out-Null

    foreach ($ip in $current.devices) {
        $idx = $devGrid.Rows.Add()
        $devGrid.Rows[$idx].Cells["Ip"].Value = $ip
        $devGrid.Rows[$idx].Cells["Loader"].Value = ($ip -eq $current.loader_ip)
    }

    # 단일 선택 강제: 하나를 체크하면 나머지는 자동 해제
    $devGrid.Add_CellValueChanged({
        param($sender, $e)
        if ($e.RowIndex -lt 0) { return }
        if ($devGrid.Columns[$e.ColumnIndex].Name -ne "Loader") { return }
        $checkedVal = $devGrid.Rows[$e.RowIndex].Cells["Loader"].Value
        if ($checkedVal -eq $true) {
            foreach ($row in $devGrid.Rows) {
                if ($row.Index -ne $e.RowIndex) { $row.Cells["Loader"].Value = $false }
            }
        }
    })
    $devGrid.Add_CurrentCellDirtyStateChanged({
        if ($devGrid.IsCurrentCellDirty) { $devGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })

    $dlg.Controls.Add($devGrid)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "저장"
    $btnSave.Location = New-Object System.Drawing.Point(300, 345)
    $btnSave.Size = New-Object System.Drawing.Size(90, 32)
    $btnSave.Add_Click({
        $devices = @()
        $loaderIp = ""
        foreach ($row in $devGrid.Rows) {
            $ip = $row.Cells["Ip"].Value
            if ([string]::IsNullOrWhiteSpace([string]$ip)) { continue }
            $ip = $ip.ToString().Trim()
            if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { continue }
            $devices += $ip
            if ($row.Cells["Loader"].Value -eq $true) { $loaderIp = $ip }
        }
        if ($devices.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("최소 1대 이상 등록하세요.") | Out-Null
            return
        }
        if ([string]::IsNullOrWhiteSpace($loaderIp)) {
            [System.Windows.Forms.MessageBox]::Show("TCP 부하를 보낼 Loader를 1대 체크하세요.") | Out-Null
            return
        }
        @{ devices = $devices; loader_ip = $loaderIp } | ConvertTo-Json | Set-Content -Path $DeviceConfigFile -Encoding UTF8
        Append-Log "기기 목록을 저장했습니다. ($($devices.Count)대, loader=$loaderIp)"
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "취소"
    $btnCancel.Location = New-Object System.Drawing.Point(400, 345)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCancel)

    if ($form.Icon) { $dlg.Icon = $form.Icon }
    Set-DarkTheme -ctrl $dlg
    Set-DarkGrid -g $devGrid
    $dlg.ShowDialog($form) | Out-Null
}

# ================================================================
# 설정 다이얼로그
# ================================================================
function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "설정"
    $dlg.Size = New-Object System.Drawing.Size(400, 480)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $y = 15
    $lblPc = New-Object System.Windows.Forms.Label
    $lblPc.Text = "PC용 iperf3.exe 경로:"
    $lblPc.Location = New-Object System.Drawing.Point(15, $y)
    $lblPc.Size = New-Object System.Drawing.Size(350, 20)
    $dlg.Controls.Add($lblPc)
    $y += 22

    $txtPcExe = New-Object System.Windows.Forms.TextBox
    $txtPcExe.Text = $global:Settings.PcExe
    $txtPcExe.Location = New-Object System.Drawing.Point(15, $y)
    $txtPcExe.Size = New-Object System.Drawing.Size(270, 26)
    $dlg.Controls.Add($txtPcExe)

    $btnBrowsePc = New-Object System.Windows.Forms.Button
    $btnBrowsePc.Text = "찾기"
    $btnBrowsePc.Location = New-Object System.Drawing.Point(295, ($y - 2))
    $btnBrowsePc.Size = New-Object System.Drawing.Size(65, 28)
    $btnBrowsePc.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "iperf3.exe|iperf3.exe|모든 파일|*.*"
        if ($ofd.ShowDialog() -eq "OK") { $txtPcExe.Text = $ofd.FileName }
    })
    $dlg.Controls.Add($btnBrowsePc)
    $y += 40

    $items = @(
        @{ label = "포트"; prop = "Port"; min = 1; max = 65535 },
        @{ label = "재연결 '빠른 재연결' 임계치(초)"; prop = "ReconnectFastThresholdSec"; min = 1; max = 600 },
        @{ label = "재전송(Retr) 경고 기준"; prop = "RetrWarnCount"; min = 1; max = 10000 },
        @{ label = "처리량 정체 기준(Mbps)"; prop = "StallMbps"; min = 0; max = 1000 },
        @{ label = "파일 분할값(분 또는 MB)"; prop = "SplitValue"; min = 1; max = 100000 },
        @{ label = "상태요약 로그 주기(분)"; prop = "StatusLogIntervalMin"; min = 1; max = 1440 }
    )
    $numControls = @{}
    foreach ($it in $items) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $it.label
        $lbl.Location = New-Object System.Drawing.Point(15, $y)
        $lbl.Size = New-Object System.Drawing.Size(240, 24)
        $dlg.Controls.Add($lbl)

        $num = New-Object System.Windows.Forms.NumericUpDown
        $num.DecimalPlaces = 1
        $num.Minimum = $it.min
        $num.Maximum = $it.max
        $num.Value = [Math]::Max($it.min, [Math]::Min($it.max, [decimal]$global:Settings.($it.prop)))
        $num.Location = New-Object System.Drawing.Point(260, $y)
        $num.Size = New-Object System.Drawing.Size(100, 26)
        $dlg.Controls.Add($num)
        $numControls[$it.prop] = $num
        $y += 30
    }

    $lblBw = New-Object System.Windows.Forms.Label
    $lblBw.Text = "대역폭 제한(Mbps, 비우면 무제한/최대처리량):"
    $lblBw.Location = New-Object System.Drawing.Point(15, $y)
    $lblBw.Size = New-Object System.Drawing.Size(350, 20)
    $dlg.Controls.Add($lblBw)
    $y += 22

    $txtBw = New-Object System.Windows.Forms.TextBox
    $txtBw.Text = [string]$global:Settings.BandwidthMbps
    $txtBw.Location = New-Object System.Drawing.Point(15, $y)
    $txtBw.Size = New-Object System.Drawing.Size(120, 26)
    $dlg.Controls.Add($txtBw)
    $y += 36

    $lblDir = New-Object System.Windows.Forms.Label
    $lblDir.Text = "로그 저장 폴더:"
    $lblDir.Location = New-Object System.Drawing.Point(15, $y)
    $lblDir.Size = New-Object System.Drawing.Size(310, 20)
    $dlg.Controls.Add($lblDir)
    $y += 22

    $txtDir = New-Object System.Windows.Forms.TextBox
    $txtDir.Text = $global:Settings.SaveDir
    $txtDir.Location = New-Object System.Drawing.Point(15, $y)
    $txtDir.Size = New-Object System.Drawing.Size(220, 26)
    $dlg.Controls.Add($txtDir)

    $btnBrowseDir = New-Object System.Windows.Forms.Button
    $btnBrowseDir.Text = "찾기"
    $btnBrowseDir.Location = New-Object System.Drawing.Point(245, ($y - 2))
    $btnBrowseDir.Size = New-Object System.Drawing.Size(65, 28)
    $btnBrowseDir.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($fbd.ShowDialog() -eq "OK") { $txtDir.Text = $fbd.SelectedPath }
    })
    $dlg.Controls.Add($btnBrowseDir)
    $y += 42

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "저장"
    $btnOk.Location = New-Object System.Drawing.Point(110, $y)
    $btnOk.Size = New-Object System.Drawing.Size(90, 32)
    $btnOk.Add_Click({
        foreach ($p in $numControls.Keys) { $global:Settings.$p = [double]$numControls[$p].Value }
        $global:Settings.PcExe = $txtPcExe.Text
        $global:Settings.BandwidthMbps = $txtBw.Text.Trim()
        $global:Settings.SaveDir = $txtDir.Text
        Save-Settings
        Append-Log "설정을 저장했습니다."
        $dlg.Close()
    })
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "취소"
    $btnCancel.Location = New-Object System.Drawing.Point(210, $y)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCancel)

    if ($form.Icon) { $dlg.Icon = $form.Icon }
    Set-DarkTheme -ctrl $dlg
    $dlg.ShowDialog($form) | Out-Null
}

# ================================================================
# 시작 / 중지
# ================================================================
function Ensure-DeviceRow {
    param([string]$ip)
    if ($global:DeviceRows.ContainsKey($ip)) { return $global:DeviceRows[$ip] }
    $idx = $grid.Rows.Add()
    $row = $grid.Rows[$idx]
    $row.Cells["No"].Value = $grid.Rows.Count
    $row.Cells["Ip"].Value = $ip
    $row.Cells["Connected"].Value = "대기 중"
    $global:DeviceRows[$ip] = $row
    return $row
}

function Update-RowFromStatus {
    param($obj)
    $row = Ensure-DeviceRow -ip $obj.ip
    $row.Cells["Role"].Value = $obj.role
    $row.Cells["Connected"].Value = if ($obj.connected -eq $true) { "연결됨" } else { "끊김" }
    if ($null -ne $obj.mbps) { $row.Cells["Mbps"].Value = "{0:N1}" -f [double]$obj.mbps }
    if ($null -ne $obj.retr) { $row.Cells["Retr"].Value = [string]$obj.retr }
    $row.Cells["LastSeen"].Value = $obj.ts
}

function Write-StatusSummaryLog {
    if ($grid.Rows.Count -eq 0) { return }
    $parts = foreach ($row in $grid.Rows) {
        $ip = $row.Cells["Ip"].Value
        $conn = $row.Cells["Connected"].Value
        "$ip[$conn]"
    }
    Append-Log "현재 상태 - $($parts -join '  |  ')"
}

function Start-Monitoring {
    if ($global:MonRunning) { return }
    $devCfg = Read-DeviceConfig
    if (-not $devCfg.devices -or $devCfg.devices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("등록된 기기가 없습니다. '기기 관리'에서 먼저 추가하세요.") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($devCfg.loader_ip)) {
        [System.Windows.Forms.MessageBox]::Show("'기기 관리'에서 TCP 부하를 보낼 Loader를 1대 지정하세요.") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($global:Settings.SaveDir)) {
        [System.Windows.Forms.MessageBox]::Show("로그 저장 경로가 비어 있습니다. '설정'에서 지정하세요.") | Out-Null
        return
    }
    if (-not (Test-Path $global:Settings.SaveDir)) {
        try {
            New-Item -ItemType Directory -Path $global:Settings.SaveDir -Force -ErrorAction Stop | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show("로그 저장 경로를 만들 수 없습니다: $($global:Settings.SaveDir)`n$($_.Exception.Message)") | Out-Null
            return
        }
    }
    if ([string]::IsNullOrWhiteSpace($global:Settings.PcExe) -or -not (Test-Path $global:Settings.PcExe)) {
        [System.Windows.Forms.MessageBox]::Show("'설정'에서 PC용 iperf3.exe 경로를 올바르게 지정하세요.") | Out-Null
        return
    }

    $grid.Rows.Clear()
    $global:DeviceRows = @{}

    $bwVal = $global:Settings.BandwidthMbps
    $runtimeCfg = @{
        devices                   = $devCfg.devices
        loader_ip                 = $devCfg.loader_ip
        port                      = [int]$global:Settings.Port
        pc_exe                    = $global:Settings.PcExe
        save_dir                  = $global:Settings.SaveDir
        bandwidth_mbps            = $bwVal
        split_mode                = $global:Settings.SplitMode
        split_value               = [int]$global:Settings.SplitValue
        reconnect_fast_threshold_sec = [int]$global:Settings.ReconnectFastThresholdSec
        retr_warn_count           = [int]$global:Settings.RetrWarnCount
        stall_mbps                = [double]$global:Settings.StallMbps
    }
    $runtimeCfg | ConvertTo-Json | Set-Content -Path $RuntimeConfigFile -Encoding UTF8

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "python"
    $psi.Arguments = "-X utf8 `"$PyScript`" `"$RuntimeConfigFile`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-ErrorLog -Message $_.Exception.Message -Source "Start-Monitoring"
        [System.Windows.Forms.MessageBox]::Show("파이썬 프로세스를 시작하지 못했습니다. Python 설치 여부를 확인하세요.") | Out-Null
        return
    }
    $global:MonProc = $proc
    try {
        $global:MonJobHandle = [JobObjectManager]::CreateJobForProcess($proc.Handle)
    } catch {
        Write-ErrorLog -Message $_.Exception.Message -Source "JobObject-Create"
    }

    $outQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $errQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $global:MonOutQueue = $outQueue
    $global:MonErrQueue = $errQueue

    $outSubName = "WPAOut_$([guid]::NewGuid().ToString('N'))"
    $errSubName = "WPAErr_$([guid]::NewGuid().ToString('N'))"
    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -SourceIdentifier $outSubName -MessageData $outQueue -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    } | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -SourceIdentifier $errSubName -MessageData $errQueue -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    } | Out-Null
    $global:MonEventSubs = @($outSubName, $errSubName)

    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $global:MonRunning = $true
    $global:LastStatusLogTime = Get-Date
    $btnStart.Text = "■ 중지"
    Apply-ButtonAccents
    Append-Log "▶ 시작했습니다. ($($devCfg.devices.Count)대, loader=$($devCfg.loader_ip))"
    Save-Settings
}

function Stop-Monitoring {
    if (-not $global:MonRunning) { return }

    if ($global:MonJobHandle) {
        try { [JobObjectManager]::TerminateJobObject($global:MonJobHandle, 1) | Out-Null } catch {
            Write-ErrorLog -Message $_.Exception.Message -Source "JobObject-Terminate"
        }
        try { [JobObjectManager]::CloseHandle($global:MonJobHandle) | Out-Null } catch {}
        $global:MonJobHandle = $null
    }
    if ($global:MonProc) {
        try { Stop-Process -Id $global:MonProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        $global:MonProc = $null
    }
    foreach ($subName in $global:MonEventSubs) {
        try { Unregister-Event -SourceIdentifier $subName -ErrorAction SilentlyContinue } catch {}
        try { Get-Job -Name $subName -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue } catch {}
    }
    $global:MonEventSubs = @()
    $global:MonOutQueue = $null
    $global:MonErrQueue = $null

    $global:MonRunning = $false
    $btnStart.Text = "▶ 시작"
    Apply-ButtonAccents
    foreach ($ip in @($global:DeviceRows.Keys)) {
        $global:DeviceRows[$ip].Cells["Connected"].Value = "대기 중"
    }
    Append-Log "⏹ 중지했습니다."
}

$btnStart.Add_Click({
    if ($global:MonRunning) { Stop-Monitoring } else { Start-Monitoring }
})
$btnDeviceManage.Add_Click({ Show-DeviceManageDialog })
$btnSettings.Add_Click({ Show-SettingsDialog })
$btnOpenFolder.Add_Click({
    if (-not (Test-Path $global:Settings.SaveDir)) { New-Item -ItemType Directory -Path $global:Settings.SaveDir -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList "`"$($global:Settings.SaveDir)`""
})

# ================================================================
# 타이머: 상태 큐 폴링 + 프로세스 종료 감지
# ================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
  try {
    if ($global:MonOutQueue) {
        $line = $null
        $shown = 0
        while ($global:MonOutQueue.TryDequeue([ref]$line)) {
            if (-not $line) { continue }
            if ($line.StartsWith("STATUS|")) {
                try {
                    $obj = $line.Substring(7) | ConvertFrom-Json
                    Update-RowFromStatus -obj $obj
                } catch {
                    Write-ErrorLog -Message "STATUS 파싱 실패: $line" -Source "StatusParse"
                }
            } else {
                if ($shown -lt 100) { Append-Log $line; $shown++ }
            }
        }
    }
    if ($global:MonErrQueue) {
        $eline = $null
        $errLines = New-Object System.Collections.Generic.List[string]
        while ($global:MonErrQueue.TryDequeue([ref]$eline)) {
            if ($eline) { $errLines.Add($eline) }
        }
        if ($errLines.Count -gt 0) {
            Write-ErrorLog -Message $errLines.ToArray() -Source "Core"
        }
    }
    if ($global:MonRunning -and $global:MonProc -and $global:MonProc.HasExited) {
        Append-Log "[경고] 실행 프로세스가 예기치 않게 종료되었습니다. (exit code: $($global:MonProc.ExitCode))"
        Stop-Monitoring
    }
    if ($global:MonRunning) {
        $statusIntervalMin = [double]$global:Settings.StatusLogIntervalMin
        if ($statusIntervalMin -le 0) { $statusIntervalMin = 10 }
        if (((Get-Date) - $global:LastStatusLogTime).TotalMinutes -ge $statusIntervalMin) {
            Write-StatusSummaryLog
            $global:LastStatusLogTime = Get-Date
        }
    }
  } catch {
    Write-ErrorLog -Message $_.Exception.ToString() -Source "Timer-Tick"
  }
})
$timer.Start()

Register-StatusColorFormatting -g $grid

$form.Add_FormClosing({
    param($sender, $e)
    # 48h 무인 테스트 중 실수로 창을 닫아 테스트가 통째로 중단되는 사고 방지
    if ($global:MonRunning) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "현재 실행이 진행 중입니다.`n그래도 프로그램을 종료하시겠습니까?`n(진행 중인 부하/감시가 강제로 중단됩니다)",
            "실행 중 - 종료 확인",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $e.Cancel = $true
            return
        }
    }
    $timer.Stop()
    if ($global:MonRunning) { Stop-Monitoring }
    Save-Settings
})

Load-Settings
if ($global:Settings.WindowWidth -gt 400) {
    $form.Size = New-Object System.Drawing.Size([int]$global:Settings.WindowWidth, [int]$global:Settings.WindowHeight)
}
if ($global:Settings.WindowLeft -ge 0 -and $global:Settings.WindowTop -ge 0) {
    $form.StartPosition = "Manual"
    $form.Left = [int]$global:Settings.WindowLeft
    $form.Top  = [int]$global:Settings.WindowTop
}
Apply-CurrentTheme

$form.Add_Load({
    try {
        $dist = [int]$global:Settings.SplitDistance
        if ($dist -gt 80) { $split.SplitterDistance = $dist }
    } catch {}
    if ($global:Settings.WindowState -eq "Maximized") {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
    }
})

$form.Add_Shown({ $form.Activate() })
[System.Windows.Forms.Application]::Run($form)
