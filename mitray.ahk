;==============================================================================
; Clash Tray - Windows System Tray Tool
; AutoHotkey v2.0+
; Description: Manage mihomo proxy core with system tray interface
;==============================================================================

#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent

;==============================================================================
; Global Variables
;==============================================================================
global MihomoProcess := 0
global ConfigFile := A_ScriptDir "\config.ini"
global MihomoConfigFile := ""
global TempConfigFile := ""  ; 将在读取配置后设置到核心目录

; Configuration
global CorePath := ""
global CoreProcessName := ""
global ConfigPath := ""
global ConfigURL := ""
global APIController := "127.0.0.1:9090"
global APISecret := ""
global ProxyPort := "7892"
global WebUIPath := "ui"
global WebUIName := ""
global AutoStartCore := true

; State
global IsProxyEnabled := false
global IsTUNEnabled := false
global IsAutoStartup := false
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
    }

    ; Read Mihomo section
    CorePath := IniRead(ConfigFile, "Mihomo", "CorePath", "")
    ConfigPath := IniRead(ConfigFile, "Mihomo", "ConfigPath", "")
    ConfigURL := IniRead(ConfigFile, "Mihomo", "ConfigURL", "")

    ; Extract process name from CorePath
    if (CorePath) {
        SplitPath(CorePath, &CoreProcessName)
    }

    ; Read API section (for backward compatibility, will be overridden by config file)
    APISecret := IniRead(ConfigFile, "API", "Secret", "")

    ; Read Settings section (removed auto-enable options)
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

[API]
; API secret (auto-detected from mihomo config, can override here)
Secret=

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
    ; Set default icon (off state)
    UpdateTrayIcon()

    ; Remove default menu items
    A_TrayMenu.Delete()

    ; Add menu items
    A_TrayMenu.Add("打开 WebUI", MenuOpenWebUI)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("启用系统代理", MenuToggleProxy)
    A_TrayMenu.Add("启用 TUN 模式", MenuToggleTUN)
    A_TrayMenu.Add()  ; Separator
    A_TrayMenu.Add("刷新状态", MenuRefreshStatus)
    A_TrayMenu.Add("开机自启", MenuToggleAutoStartup)
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

    ; Update auto-startup checkbox
    if (IsAutoStartup) {
        A_TrayMenu.Check("开机自启")
    } else {
        A_TrayMenu.Uncheck("开机自启")
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

MenuToggleAutoStartup(*) {
    if (IsAutoStartup) {
        DisableAutoStartup()
    } else {
        EnableAutoStartup()
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

    ; Update tray icon based on status
    UpdateTrayIcon()
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
            ShowNotification("错误", "下载配置文件失败", 3)
            return false
        }
        MihomoConfigFile := TempConfigFile
    } else if (ConfigPath) {
        MihomoConfigFile := ConfigPath
    } else {
        ShowNotification("错误", "未配置本地配置文件或远程 URL`n请编辑 config.ini", 3)
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
            ShowNotification("错误", "mihomo 启动失败", 3)
            return false
        }
    } catch as err {
        ShowNotification("错误", "启动 mihomo 失败: " . err.Message, 3)
        return false
    }
}

StopMihomo() {
    global MihomoProcess, CoreProcessName, IsProxyEnabled, IsTUNEnabled

    if (!IsMihomoRunning()) {
        ShowNotification("提示", "mihomo 未在运行", 2)
        return
    }

    ; Try to close by PID first
    if (MihomoProcess && ProcessExist(MihomoProcess)) {
        ProcessClose(MihomoProcess)
    }

    ; Also close any mihomo processes by name
    if (CoreProcessName && ProcessExist(CoreProcessName)) {
        ProcessClose(CoreProcessName)
    }

    MihomoProcess := 0

    ; Reset proxy and TUN status when core stops
    IsProxyEnabled := false
    IsTUNEnabled := false

    ; Update menu and icon
    UpdateMenuStates()
    UpdateTrayIcon()

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
        UpdateTrayIcon()
        ShowNotification("系统代理", "系统代理已启用 (端口: " . ProxyPort . ")", 2)
    } catch as err {
        ShowNotification("错误", "启用系统代理失败: " . err.Message, 3)
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
        UpdateTrayIcon()
        ShowNotification("系统代理", "系统代理已禁用", 2)
    } catch as err {
        ShowNotification("错误", "禁用系统代理失败: " . err.Message, 3)
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
        ShowNotification("错误", "mihomo 未运行", 3)
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
                    UpdateTrayIcon()
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
        ShowNotification("权限不足", "TUN 模式需要管理员权限`n请退出程序后选择「以管理员身份运行」", 5)
    } else {
        ShowNotification("错误", "启用 TUN 模式失败，请检查 mihomo API 是否正常", 3)
    }
    return false
}

DisableTUNMode() {
    global IsTUNEnabled, APIController, APISecret

    if (!IsMihomoRunning()) {
        ShowNotification("错误", "mihomo 未运行", 3)
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
                    UpdateTrayIcon()
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
; Auto-startup Management
;==============================================================================
CheckAutoStartup() {
    global IsAutoStartup

    try {
        regValue := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClashTray")
        IsAutoStartup := true
    } catch {
        IsAutoStartup := false
    }

    UpdateMenuStates()
}

EnableAutoStartup() {
    global IsAutoStartup

    try {
        ; Get executable path (if compiled) or script path
        exePath := A_IsCompiled ? A_ScriptFullPath : A_ScriptFullPath

        RegWrite('"' . exePath . '"', "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClashTray")

        IsAutoStartup := true
        UpdateMenuStates()
        ShowNotification("开机自启", "已启用开机自启动", 2)
    } catch as err {
        ShowNotification("错误", "启用开机自启失败: " . err.Message, 3)
    }
}

DisableAutoStartup() {
    global IsAutoStartup

    try {
        RegDelete("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "ClashTray")

        IsAutoStartup := false
        UpdateMenuStates()
        ShowNotification("开机自启", "已禁用开机自启动", 2)
    } catch as err {
        ShowNotification("错误", "禁用开机自启失败: " . err.Message, 3)
    }
}

;==============================================================================
; Utility Functions
;==============================================================================
ShowNotification(title, message, duration := 3) {
    TrayTip(message, title, 0x1)
    SetTimer(() => TrayTip(), -duration * 1000)
}

UpdateTrayIcon() {
    global IsProxyEnabled, IsTUNEnabled

    ; 如果系统代理或TUN模式任意一个开启，使用 mitray-on.ico，否则使用 mitray.ico
    if (IsProxyEnabled || IsTUNEnabled) {
        iconPath := A_ScriptDir "\mitray-on.ico"
    } else {
        iconPath := A_ScriptDir "\mitray.ico"
    }

    ; 如果图标文件存在则设置，否则使用默认图标
    if (FileExist(iconPath)) {
        TraySetIcon(iconPath)
    }
}
