param(
    [string]$Name = "Yura VPN",
    [string]$Server = "vpn.example.com"
)

$ErrorActionPreference = "Stop"

Remove-VpnConnection -Name $Name -Force -ErrorAction SilentlyContinue
Remove-VpnConnection -Name $Name -AllUserConnection -Force -ErrorAction SilentlyContinue

Add-VpnConnection `
    -Name $Name `
    -ServerAddress $Server `
    -TunnelType IKEv2 `
    -AuthenticationMethod Eap `
    -EncryptionLevel Maximum `
    -SplitTunneling $false `
    -RememberCredential `
    -Force

Set-VpnConnectionIPsecConfiguration `
    -ConnectionName $Name `
    -AuthenticationTransformConstants SHA256128 `
    -CipherTransformConstants AES256 `
    -EncryptionMethod AES256 `
    -IntegrityCheckMethod SHA256 `
    -PfsGroup PFS2048 `
    -DHGroup Group14 `
    -Force

Write-Host "VPN profile created: $Name"
Write-Host "Server: $Server"
Write-Host "Connect: rasphone.exe -d `"$Name`""
