;==============================================================================
; MiTray
; AutoHotkey v2.0+
; Description: Manage mihomo core with system tray interface
;==============================================================================

;@Ahk2Exe-SetMainIcon %A_ScriptName~\.[^.]+$~.ico%
;@Ahk2Exe-SetName %A_ScriptName~\.[^.]+$~~%
;@Ahk2Exe-SetVersion 1.0.0
;@Ahk2Exe-ExeName %A_ScriptName~\.[^.]+$~.exe%

#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent

;==============================================================================
; Global Variables
;==============================================================================
; 获取脚本基础名称(不含扩展名),用于注册表和程序标识
global ScriptBaseName := RegExReplace(A_ScriptName, "\.[^.]+$", "")

global MihomoProcess := 0
global ConfigFile := A_ScriptDir "\config.ini"
global MihomoConfigFile := ""
global TempConfigFile := ""  ; 将在读取配置后设置到核心目录

; Configuration
global CorePath := ""
global CoreProcessName := ""
global ConfigPath := ""
global ConfigURL := ""
global APIController := ""
global APISecret := ""
global ProxyPort := ""
global WebUIPath := ""
global WebUIName := ""
global AutoStartCore := true

; State
global IsProxyEnabled := false
global IsTUNEnabled := false
global IsAutoStartup := false
global AutoStartupLevel := ""  ; "normal" 或 "admin"
global AutoStartupMenu := 0  ; 开机自启子菜单对象
global StatusCheckTimer := 0

;==============================================================================
; Initialization
;==============================================================================
LoadConfig()
SetupTrayMenu()
CheckAutoStartup()
CheckSystemProxyState()  ; Check current system proxy state

; Auto-start mihomo if configured
if (AutoStartCore) {
    if (StartMihomo()) {
        ; Wait for core to be fully ready
        Sleep(3000)

        ; Start status monitoring
        StartStatusMonitoring()
    }
} else {
    ; Even if not auto-starting, check if mihomo is already running
    if (CoreProcessName && ProcessExist(CoreProcessName)) {
        MihomoProcess := ProcessExist(CoreProcessName)
        ShowNotification("检测到运行", "检测到 mihomo 已在运行", 2)
        StartStatusMonitoring()
    }
}

return

;==============================================================================
; Configuration Management
;==============================================================================
LoadConfig() {
    global

    ; Create default config if not exists
    if (!FileExist(ConfigFile)) {
        CreateDefaultConfig()
        ShowNotification("首次运行", "已创建默认配置文件 config.ini`n请编辑配置文件后重新运行程序", 3)
        Sleep(3000)  ; 等待通知显示
        ExitApp()
    }

    ; Read Mihomo section
    CorePath := IniRead(ConfigFile, "Mihomo", "CorePath", "")
    ConfigPath := IniRead(ConfigFile, "Mihomo", "ConfigPath", "")
    ConfigURL := IniRead(ConfigFile, "Mihomo", "ConfigURL", "")

    ; Extract process name from CorePath
    if (CorePath) {
        SplitPath(CorePath, &CoreProcessName)
    }

    ; Read Settings section
    AutoStartCore := IniRead(ConfigFile, "Settings", "AutoStartCore", "1") = "1"

    ; Parse mihomo config file if exists to get API settings
    if (ConfigPath && FileExist(ConfigPath)) {
        ParseMihomoConfig(ConfigPath)
    }
}

CreateDefaultConfig() {
    global ConfigFile

    configContent := "
(
[Mihomo]
; Path to mihomo executable (required)
CorePath=

; Local config file path (optional if ConfigURL is set)
ConfigPath=

; Remote config URL (optional, takes precedence over ConfigPath)
ConfigURL=

[Settings]
; Auto-start mihomo on script launch (1=yes, 0=no)
AutoStartCore=1
)"

    FileAppend(configContent, ConfigFile)
}

ParseMihomoConfig(configPath) {
    global APIController, APISecret, ProxyPort, WebUIPath, WebUIName

    try {
        content := FileRead(configPath)

        ; Parse external-controller (keep as full address)
        if (RegExMatch(content, "im)^external-controller:\s*([^\r\n]+)", &match)) {
            APIController := Trim(match[1])
        }

        ; Parse secret
        if (RegExMatch(content, "secret:\s*([^\r\n]+)", &match)) {
            APISecret := Trim(match[1])
        }

        ; Parse external-ui (local path)
        if (RegExMatch(content, "im)^external-ui:\s*([^\r\n]+)", &match)) {
            WebUIPath := Trim(match[1])
        }

        ; Parse external-ui-name (folder name)
        if (RegExMatch(content, "im)^external-ui-name:\s*([^\r\n]+)", &match)) {
            WebUIName := Trim(match[1])
        }

        ; Parse proxy port (try mixed-port first, then port)
        if (RegExMatch(content, "im)^mixed-port:\s*(\d+)", &match)) {
            ProxyPort := match[1]
        } else if (RegExMatch(content, "im)^port:\s*(\d+)", &match)) {
            ProxyPort := match[1]
        }
    }
}

;==============================================================================
; Tray Menu Setup
;==============================================================================
SetupTrayMenu() {
    global AutoStartupMenu

    ; Remove default menu items
    A_TrayMenu.Delete()

    ; Add menu items
    A_TrayMenu.Add("打开 WebUI", MenuOpenWebUI)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("启用系统代理", MenuToggleProxy)
    A_TrayMenu.Add("启用 TUN 模式", MenuToggleTUN)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("刷新状态", MenuRefreshStatus)

    ; 创建开机自启子菜单
    AutoStartupMenu := Menu()
    AutoStartupMenu.Add("普通权限", MenuAutoStartupNormal)
    AutoStartupMenu.Add("管理员权限", MenuAutoStartupAdmin)
    A_TrayMenu.Add("开机自启", AutoStartupMenu)

    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("打开程序目录", MenuOpenScriptDir)
    A_TrayMenu.Add("打开核心目录", MenuOpenCoreDir)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("重启内核", MenuRestartCore)
    A_TrayMenu.Add("停止内核", MenuStopCore)
    A_TrayMenu.Add("退出程序", MenuExitProgram)

    ; Update menu states
    UpdateMenuStates()
}

UpdateMenuStates() {
    ; Update proxy checkbox
    if (IsProxyEnabled) {
        A_TrayMenu.Check("启用系统代理")
    } else {
        A_TrayMenu.Uncheck("启用系统代理")
    }

    ; Update TUN checkbox
    if (IsTUNEnabled) {
        A_TrayMenu.Check("启用 TUN 模式")
    } else {
        A_TrayMenu.Uncheck("启用 TUN 模式")
    }

    ; Update auto-startup checkboxes
    if (AutoStartupMenu) {
        if (AutoStartupLevel = "normal") {
            AutoStartupMenu.Check("普通权限")
            AutoStartupMenu.Uncheck("管理员权限")
        } else if (AutoStartupLevel = "admin") {
            AutoStartupMenu.Uncheck("普通权限")
            AutoStartupMenu.Check("管理员权限")
        } else {
            AutoStartupMenu.Uncheck("普通权限")
            AutoStartupMenu.Uncheck("管理员权限")
        }
    }
}

;==============================================================================
; Menu Handlers
;==============================================================================
MenuOpenWebUI(*) {
    global APIController, APISecret, WebUIPath, WebUIName

    if (!APIController) {
        ShowNotification("错误", "API 配置未设置", 3)
        return
    }

    ; Check if mihomo is running
    if (!IsMihomoRunning()) {
        ShowNotification("错误", "mihomo 未运行", 3)
        return
    }

    ; Construct WebUI URL
    url := "http://" . APIController . "/" . WebUIPath

    ; Add external-ui-name if configured
    if (WebUIName) {
        url .= "/" . WebUIName
    }

    ; Add secret parameter
    if (APISecret) {
        url .= "?secret=" . APISecret
    }

    Run(url)
    ShowNotification("WebUI", "已在浏览器中打开 WebUI", 2)
}

MenuToggleProxy(*) {
    if (IsProxyEnabled) {
        DisableSystemProxy()
    } else {
        EnableSystemProxy()
    }
}

MenuToggleTUN(*) {
    if (IsTUNEnabled) {
        DisableTUNMode()
    } else {
        EnableTUNMode()
    }
}

MenuRefreshStatus(*) {
    RefreshAllStatus()
    ShowNotification("状态刷新", "已刷新系统代理和 TUN 状态", 2)
}

MenuAutoStartupNormal(*) {
    if (AutoStartupLevel = "normal") {
        DisableAutoStartup()
    } else {
        EnableAutoStartup("normal")
    }
}

MenuAutoStartupAdmin(*) {
    if (AutoStartupLevel = "admin") {
        DisableAutoStartup()
    } else {
        EnableAutoStartup("admin")
    }
}

MenuOpenScriptDir(*) {
    Run('explorer.exe "' . A_ScriptDir . '"')
}

MenuOpenCoreDir(*) {
    global CorePath

    if (!CorePath || !FileExist(CorePath)) {
        ShowNotification("错误", "核心路径未配置或文件不存在", 3)
        return
    }

    ; 获取核心所在目录
    SplitPath(CorePath, , &coreDir)
    Run('explorer.exe "' . coreDir . '"')
}

MenuRestartCore(*) {
    ShowNotification("重启内核", "正在重启 mihomo 内核...", 2)

    ; Try API restart first
    if (RestartCoreViaAPI()) {
        Sleep(3000)
        RefreshAllStatus()
        ShowNotification("重启成功", "mihomo 内核已通过 API 重启", 2)
        return
    }

    ; Fallback to process restart
    StopMihomo()
    Sleep(1000)
    if (StartMihomo()) {
        Sleep(3000)
        StartStatusMonitoring()
        RefreshAllStatus()
    }
}

MenuStopCore(*) {
    StopMihomo()
    StopStatusMonitoring()
}

MenuExitProgram(*) {
    ; Just exit the program, don't stop mihomo or change proxy settings
    ; This allows mihomo to continue running in background
    StopStatusMonitoring()
    ExitApp()
}

;==============================================================================
; Status Monitoring
;==============================================================================
StartStatusMonitoring() {
    global StatusCheckTimer

    ; Stop existing timer if any
    StopStatusMonitoring()

    ; Refresh status immediately
    RefreshAllStatus()

    ; Set up periodic status check (every 5 seconds)
    StatusCheckTimer := SetTimer(RefreshAllStatus, 5000)
}

StopStatusMonitoring() {
    global StatusCheckTimer

    if (StatusCheckTimer) {
        SetTimer(StatusCheckTimer, 0)
        StatusCheckTimer := 0
    }
}

RefreshAllStatus() {
    ; Check if mihomo is still running
    if (!IsMihomoRunning()) {
        StopStatusMonitoring()
        return
    }

    ; Refresh system proxy state
    CheckSystemProxyState()

    ; Refresh TUN state from API
    GetTUNStatusFromAPI()

    ; Update menu
    UpdateMenuStates()
}

;==============================================================================
; Mihomo Process Management
;==============================================================================
IsMihomoRunning() {
    global MihomoProcess, CoreProcessName

    if (!CoreProcessName) {
        return false
    }

    if (ProcessExist(CoreProcessName)) {
        ; Update PID if needed
        if (!MihomoProcess || !ProcessExist(MihomoProcess)) {
            MihomoProcess := ProcessExist(CoreProcessName)
        }
        return true
    }

    MihomoProcess := 0
    return false
}

StartMihomo() {
    global MihomoProcess, CorePath, CoreProcessName, ConfigPath, ConfigURL, MihomoConfigFile, TempConfigFile

    ; Check if mihomo process is already running
    if (IsMihomoRunning()) {
        ShowNotification("提示", "mihomo 已在运行中", 2)
        return true
    }

    ; Validate core path
    if (!CorePath || !FileExist(CorePath)) {
        ShowNotification("错误", "mihomo 核心路径未配置或文件不存在`n请编辑 config.ini", 3)
        return false
    }

    ; 设置临时配置文件路径到核心目录
    if (CorePath) {
        SplitPath(CorePath, , &coreDir)
        TempConfigFile := coreDir . "\config-downloaded.yaml"
    }

    ; Determine which config to use
    if (ConfigURL) {
        ; Download config from URL
        ShowNotification("下载配置", "正在从 URL 下载配置文件...", 2)
        if (!DownloadConfig(ConfigURL, TempConfigFile)) {
            ShowNotification("错误", "下载配置文件失败", 2)
            return false
        }
        MihomoConfigFile := TempConfigFile
    } else if (ConfigPath) {
        MihomoConfigFile := ConfigPath
    } else {
        ShowNotification("错误", "未配置本地配置文件或远程 URL`n请编辑 config.ini", 2)
        return false
    }

    ; Validate config file exists
    if (!FileExist(MihomoConfigFile)) {
        ShowNotification("错误", "配置文件不存在: " . MihomoConfigFile, 3)
        return false
    }

    ; Parse config to get settings
    ParseMihomoConfig(MihomoConfigFile)

    ; Get core directory for working directory
    SplitPath(CorePath, , &coreDir)

    ; Start mihomo with working directory set to core directory
    try {
        MihomoProcess := Run('"' . CorePath . '" -f "' . MihomoConfigFile . '"', coreDir, "Hide")
        Sleep(2000)  ; Wait for startup

        ; Check if process started successfully
        if (IsMihomoRunning()) {
            ShowNotification("启动成功", "mihomo 内核已启动", 2)
            return true
        } else {
            ShowNotification("错误", "mihomo 启动失败", 2)
            return false
        }
    } catch as err {
        ShowNotification("错误", "启动 mihomo 失败: " . err.Message, 2)
        return false
    }
}

StopMihomo() {
    global MihomoProcess, CoreProcessName, IsProxyEnabled, IsTUNEnabled

    if (!IsMihomoRunning()) {
        ShowNotification("提示", "mihomo 未在运行", 2)
        return
    }

    ; 尝试关闭进程(先用进程名,更可靠)
    if (CoreProcessName && ProcessExist(CoreProcessName)) {
        ProcessClose(CoreProcessName)

        ; 等待进程退出(最多等待3秒)
        waitCount := 0
        while (ProcessExist(CoreProcessName) && waitCount < 30) {
            Sleep(100)
            waitCount++
        }
    }

    ; 如果进程名关闭失败,尝试用 PID 关闭
    if (MihomoProcess && ProcessExist(MihomoProcess)) {
        ProcessClose(MihomoProcess)

        ; 再次等待
        waitCount := 0
        while (ProcessExist(MihomoProcess) && waitCount < 30) {
            Sleep(100)
            waitCount++
        }
    }

    ; 验证是否成功关闭
    if (IsMihomoRunning()) {
        ShowNotification("错误", "无法停止 mihomo 内核,请手动结束进程", 3)
        return
    }

    ; 成功关闭,重置状态
    MihomoProcess := 0
    IsProxyEnabled := false
    IsTUNEnabled := false

    ; 更新菜单
    UpdateMenuStates()

    ShowNotification("停止", "mihomo 内核已停止", 2)
}

RestartCoreViaAPI() {
    global APIController, APISecret

    if (!IsMihomoRunning()) {
        return false
    }

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", "http://" . APIController . "/restart", false)
        whr.SetRequestHeader("Content-Type", "application/json")

        if (APISecret) {
            whr.SetRequestHeader("Authorization", "Bearer " . APISecret)
        }

        whr.Send('{}')

        ; Check response status
        if (whr.Status = 204 || whr.Status = 200) {
            return true
        }

        return false
    } catch as err {
        return false
    }
}

DownloadConfig(url, destPath) {
    try {
        ; Delete old temp file if exists
        if (FileExist(destPath)) {
            FileDelete(destPath)
        }

        Download(url, destPath)
        return FileExist(destPath)
    } catch {
        return false
    }
}

;==============================================================================
; System Proxy Control
;==============================================================================
CheckSystemProxyState() {
    global IsProxyEnabled

    try {
        proxyEnable := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable")
        IsProxyEnabled := (proxyEnable = 1)
    } catch {
        IsProxyEnabled := false
    }

    UpdateMenuStates()
}

EnableSystemProxy() {
    global IsProxyEnabled, ProxyPort

    try {
        ; Set registry values
        RegWrite(1, "REG_DWORD", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable")
        RegWrite("127.0.0.1:" . ProxyPort, "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            "ProxyServer")
        RegWrite(
            "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>",
            "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyOverride")

        ; Apply settings immediately
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 39, "UInt", 0, "UInt", 0)
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 37, "UInt", 0, "UInt", 0)

        IsProxyEnabled := true
        UpdateMenuStates()
        ShowNotification("系统代理", "系统代理已启用 (端口: " . ProxyPort . ")", 2)
    } catch as err {
        ShowNotification("错误", "启用系统代理失败: " . err.Message, 2)
    }
}

DisableSystemProxy() {
    global IsProxyEnabled

    try {
        ; Clear registry values
        RegWrite(0, "REG_DWORD", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable")
        RegWrite("", "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyServer")

        ; Apply settings immediately
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 39, "UInt", 0, "UInt", 0)
        DllCall("wininet\InternetSetOptionA", "UInt", 0, "UInt", 37, "UInt", 0, "UInt", 0)

        IsProxyEnabled := false
        UpdateMenuStates()
        ShowNotification("系统代理", "系统代理已禁用", 2)
    } catch as err {
        ShowNotification("错误", "禁用系统代理失败: " . err.Message, 2)
    }
}

;==============================================================================
; TUN Mode Control
;==============================================================================
GetTUNStatusFromAPI() {
    global IsTUNEnabled, APIController, APISecret

    if (!IsMihomoRunning()) {
        return false
    }

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://" . APIController . "/configs", false)

        if (APISecret) {
            whr.SetRequestHeader("Authorization", "Bearer " . APISecret)
        }

        ; Set timeout (in milliseconds)
        whr.SetTimeouts(1000, 1000, 2000, 2000)

        whr.Send()

        ; Check response status
        if (whr.Status != 200) {
            return false
        }

        response := whr.ResponseText

        ; Parse JSON response to get TUN status
        ; Simple regex parsing (for production, consider using a JSON library)
        if (RegExMatch(response, '"tun":\s*\{[^}]*"enable":\s*(true|false)', &match)) {
            IsTUNEnabled := (match[1] = "true")
            return true
        }

        return false
    } catch {
        return false
    }
}

EnableTUNMode() {
    global IsTUNEnabled, APIController, APISecret

    ; Ensure mihomo is running
    if (!IsMihomoRunning()) {
        ShowNotification("错误", "mihomo 未运行", 2)
        return false
    }

    ; Try multiple times in case API is not ready
    retryCount := 3
    loop retryCount {
        try {
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.Open("PATCH", "http://" . APIController . "/configs", false)
            whr.SetRequestHeader("Content-Type", "application/json")

            if (APISecret) {
                whr.SetRequestHeader("Authorization", "Bearer " . APISecret)
            }

            ; Set timeout
            whr.SetTimeouts(1000, 1000, 3000, 3000)

            whr.Send('{"tun": {"enable": true}}')

            ; Check response status
            if (whr.Status = 204 || whr.Status = 200) {
                ; Wait a moment for change to take effect
                Sleep(500)

                ; Verify the change
                if (GetTUNStatusFromAPI() && IsTUNEnabled) {
                    UpdateMenuStates()
                    ShowNotification("TUN 模式", "TUN 模式已启用", 2)
                    return true
                }
            }
        } catch {
            ; Retry on error
        }

        ; Wait before retry
        if (A_Index < retryCount) {
            Sleep(1000)
        }
    }

    if (!A_IsAdmin) {
        ShowNotification("权限不足", "TUN 模式需要管理员权限`n请退出程序后选择「以管理员身份运行」", 3)
    } else {
        ShowNotification("错误", "启用 TUN 模式失败，请检查 mihomo API 是否正常", 2)
    }
    return false
}

DisableTUNMode() {
    global IsTUNEnabled, APIController, APISecret

    if (!IsMihomoRunning()) {
        ShowNotification("错误", "mihomo 未运行", 2)
        return false
    }

    ; Try multiple times in case API is not ready
    retryCount := 3
    loop retryCount {
        try {
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.Open("PATCH", "http://" . APIController . "/configs", false)
            whr.SetRequestHeader("Content-Type", "application/json")

            if (APISecret) {
                whr.SetRequestHeader("Authorization", "Bearer " . APISecret)
            }

            ; Set timeout
            whr.SetTimeouts(1000, 1000, 3000, 3000)

            whr.Send('{"tun": {"enable": false}}')

            ; Check response status
            if (whr.Status = 204 || whr.Status = 200) {
                ; Wait a moment for change to take effect
                Sleep(500)

                ; Verify the change
                if (GetTUNStatusFromAPI() && !IsTUNEnabled) {
                    UpdateMenuStates()
                    ShowNotification("TUN 模式", "TUN 模式已禁用", 2)
                    return true
                }
            }
        } catch {
            ; Retry on error
        }

        ; Wait before retry
        if (A_Index < retryCount) {
            Sleep(1000)
        }
    }

    ShowNotification("错误", "禁用 TUN 模式失败，请检查 mihomo API 是否正常", 3)
    return false
}

;==============================================================================
; Auto-startup Management (使用任务计划程序)
;==============================================================================
CheckAutoStartup() {
    global IsAutoStartup, AutoStartupLevel, ScriptBaseName

    try {
        ; 检查任务计划程序中是否存在任务
        cmd := 'schtasks /Query /TN "' . ScriptBaseName . '" /FO LIST /V'
        result := RunWaitOne(cmd)

        if (InStr(result, ScriptBaseName)) {
            IsAutoStartup := true

            ; 检查是否以最高权限运行
            if (InStr(result, "Highest") || InStr(result, "最高权限")) {
                AutoStartupLevel := "admin"
            } else {
                AutoStartupLevel := "normal"
            }
        } else {
            IsAutoStartup := false
            AutoStartupLevel := ""
        }
    } catch {
        IsAutoStartup := false
        AutoStartupLevel := ""
    }

    UpdateMenuStates()
}

EnableAutoStartup(level := "normal") {
    global IsAutoStartup, AutoStartupLevel, ScriptBaseName

    try {
        ; 先删除已存在的任务（如果有）
        DisableAutoStartup()

        ; 获取可执行文件路径
        exePath := A_IsCompiled ? A_ScriptFullPath : A_ScriptFullPath

        ; 设置权限级别
        runLevel := (level = "admin") ? "Highest" : "Limited"
        levelText := (level = "admin") ? "管理员权限" : "普通权限"

        ; 构建 PowerShell 脚本
        ; 使用 Register-ScheduledTask cmdlet 创建任务
        psScript := '
(
$action = New-ScheduledTaskAction -Execute "' . exePath . '"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -AllowStartOnDemand
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel ' . runLevel . '
Register-ScheduledTask -TaskName "' . ScriptBaseName . '" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
if ($?) { Write-Output "SUCCESS" } else { Write-Output "FAILED" }
)'

        ; 执行 PowerShell 命令
        cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "' . psScript . '"'
        result := RunWaitOne(cmd)

        ; 检查是否成功
        if (InStr(result, "SUCCESS")) {
            IsAutoStartup := true
            AutoStartupLevel := level
            UpdateMenuStates()
            ShowNotification("开机自启", "已启用开机自启动 (" . levelText . ")", 2)
        } else {
            ShowNotification("错误", "启用开机自启失败`n" . result, 5)
        }
    } catch as err {
        ShowNotification("错误", "启用开机自启失败: " . err.Message, 2)
    }
}

DisableAutoStartup() {
    global IsAutoStartup, AutoStartupLevel, ScriptBaseName

    try {
        ; 删除任务计划程序中的任务
        cmd := 'schtasks /Delete /TN "' . ScriptBaseName . '" /F'
        result := RunWaitOne(cmd)

        IsAutoStartup := false
        AutoStartupLevel := ""
        UpdateMenuStates()

        ; 只有在任务存在时才显示成功通知
        if (InStr(result, "SUCCESS") || InStr(result, "成功")) {
            ShowNotification("开机自启", "已禁用开机自启动", 2)
        }
    } catch as err {
        ; 忽略删除不存在任务的错误
        IsAutoStartup := false
        AutoStartupLevel := ""
        UpdateMenuStates()
    }
}

;==============================================================================
; Utility Functions
;==============================================================================
ShowNotification(title, message, duration := 2) {
    TrayTip(message, title, 0x1)
    SetTimer(() => TrayTip(), -duration * 1000)
}

RunWaitOne(command) {
    shell := ComObject("WScript.Shell")
    exec := shell.Exec(A_ComSpec " /C " . command)

    ; 等待命令完成并读取输出
    output := exec.StdOut.ReadAll()

    return output
}
