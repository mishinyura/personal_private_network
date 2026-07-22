Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    while ($true) {
        $Value = (Read-Host $Prompt).Trim()

        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            return $Value
        }

        Write-Host "Значение не может быть пустым." -ForegroundColor Yellow
    }
}

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)

    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw "Запусти PowerShell от имени администратора."
}

Import-Module VpnClient

$VpnName = Read-RequiredValue "Название VPN"
$Server = Read-RequiredValue "Сервер VPN, например vpn.example.com"
$Username = Read-RequiredValue "Логин"
$SecurePassword = Read-Host "Пароль" -AsSecureString

if ($Server -match "^https?://") {
    $Server = ([Uri]$Server).Host
}

Write-Host ""
Write-Host "Создание VPN-профиля '$VpnName'..." -ForegroundColor Cyan

$ExistingUserConnection = Get-VpnConnection -Name $VpnName -ErrorAction SilentlyContinue

if ($null -ne $ExistingUserConnection) {
    if ($ExistingUserConnection.ConnectionStatus -eq "Connected") {
        & rasdial.exe $VpnName /disconnect | Out-Null
    }

    Remove-VpnConnection -Name $VpnName -Force
}

$GetGlobalConnectionParameters = @{
    Name              = $VpnName
    AllUserConnection = $true
    ErrorAction       = "SilentlyContinue"
}

$ExistingGlobalConnection = Get-VpnConnection @GetGlobalConnectionParameters

if ($null -ne $ExistingGlobalConnection) {
    $RemoveGlobalConnectionParameters = @{
        Name              = $VpnName
        AllUserConnection = $true
        Force             = $true
    }

    Remove-VpnConnection @RemoveGlobalConnectionParameters
}

$AddConnectionParameters = @{
    Name                 = $VpnName
    ServerAddress        = $Server
    TunnelType           = "Ikev2"
    AuthenticationMethod = "Eap"
    EncryptionLevel      = "Maximum"
    RememberCredential   = $true
    Force                = $true
    PassThru             = $true
}

Add-VpnConnection @AddConnectionParameters | Out-Null

$SetConnectionParameters = @{
    Name                  = $VpnName
    SplitTunneling        = $false
    RememberCredential    = $true
    UseWinlogonCredential = $false
    Force                 = $true
    PassThru              = $true
}

Set-VpnConnection @SetConnectionParameters | Out-Null

$IpsecParameters = @{
    ConnectionName                   = $VpnName
    AuthenticationTransformConstants = "SHA256128"
    CipherTransformConstants         = "AES256"
    EncryptionMethod                 = "AES256"
    IntegrityCheckMethod             = "SHA256"
    PfsGroup                         = "PFS2048"
    DHGroup                          = "Group14"
    Force                            = $true
    PassThru                         = $true
}

Set-VpnConnectionIPsecConfiguration @IpsecParameters | Out-Null

$Routes = @(
    "0.0.0.0/1",
    "128.0.0.0/1"
)

foreach ($Prefix in $Routes) {
    $RemoveRouteParameters = @{
        ConnectionName   = $VpnName
        DestinationPrefix = $Prefix
        ErrorAction      = "SilentlyContinue"
    }

    Remove-VpnConnectionRoute @RemoveRouteParameters

    $AddRouteParameters = @{
        ConnectionName   = $VpnName
        DestinationPrefix = $Prefix
        RouteMetric      = 1
        PassThru         = $true
    }

    Add-VpnConnectionRoute @AddRouteParameters | Out-Null
}

Write-Host "Подключение..." -ForegroundColor Cyan

$PasswordPointer = [IntPtr]::Zero
$PlainPassword = $null
$RasdialOutput = @()
$RasdialExitCode = 1

try {
    $PasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($PasswordPointer)

    $RasdialOutput = & rasdial.exe $VpnName $Username $PlainPassword 2>&1
    $RasdialExitCode = $LASTEXITCODE
}
finally {
    if ($PasswordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordPointer)
    }

    $PlainPassword = $null
    $SecurePassword = $null
}

if ($RasdialExitCode -ne 0) {
    $RasdialOutput | ForEach-Object {
        Write-Host $_ -ForegroundColor Red
    }

    throw "Не удалось подключиться к VPN. Код rasdial: $RasdialExitCode"
}

Write-Host ""
Write-Host "VPN подключен." -ForegroundColor Green

Get-VpnConnection -Name $VpnName |
    Format-List Name, ServerAddress, ConnectionStatus, SplitTunneling, RememberCredential

Write-Host "Маршруты полного туннеля:" -ForegroundColor Cyan

Get-NetRoute -AddressFamily IPv4 |
    Where-Object {
        $_.InterfaceAlias -eq $VpnName -and
        $_.DestinationPrefix -in $Routes
    } |
    Sort-Object DestinationPrefix |
    Format-Table DestinationPrefix, InterfaceAlias, RouteMetric -AutoSize

try {
    $IpCheckParameters = @{
        Uri        = "https://api.ipify.org"
        TimeoutSec = 15
    }

    $ExternalIp = (Invoke-RestMethod @IpCheckParameters).Trim()
    Write-Host "Внешний IPv4: $ExternalIp" -ForegroundColor Green
}
catch {
    Write-Host "Не удалось автоматически проверить внешний IP." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Для отключения:" -ForegroundColor Cyan
Write-Host ('rasdial.exe "{0}" /disconnect' -f $VpnName)