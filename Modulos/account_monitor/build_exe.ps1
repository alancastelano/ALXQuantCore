# Build do ALX Account Monitor (.exe sem Python na VPS)
# Usage: powershell -ExecutionPolicy Bypass -File build_exe.ps1
#
# Gera dist/ALXAccountMonitor/ com o ALXAccountMonitor.exe + _internal.
# Copie essa pasta para a VPS e crie um .env ao lado do .exe.

$ErrorActionPreference = "Stop"
$Root = "C:\ALXQuant"
$Py = "$Root\.venv\Scripts\python.exe"
$Spec = "$Root\Modulos\account_monitor\ALXAccountMonitor.spec"

Write-Host "==> Build PyInstaller..."
& "$Root\.venv\Scripts\pyinstaller.exe" --noconfirm --clean $Spec
if ($LASTEXITCODE -ne 0) { throw "PyInstaller falhou" }

$dist = "$Root\dist\ALXAccountMonitor"
$size = (Get-ChildItem $dist -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB

Write-Host ""
Write-Host ("==> Pronto: {0}" -f $dist)
Write-Host ("==> Tamanho: {0:N1} MB" -f $size)
Write-Host ""
Write-Host "Proximos passos na VPS:"
Write-Host "  1. Copiar a pasta dist\ALXAccountMonitor para a VPS"
Write-Host "  2. Criar .env ao lado do .exe (ACCOUNT_MONITOR_MASTER_KEY, PORT)"
Write-Host "  3. Abrir a porta no firewall"
Write-Host "  4. Rodar ALXAccountMonitor.exe"