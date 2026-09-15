# deploy.ps1
# Deploy script para VPS Londres — ALXQuant
# Executar: powershell -ExecutionPolicy Bypass -File deploy.ps1

$ErrorActionPreference = "Stop"

$ALXQUANT_PATH = "C:\ALXQuant"
$VENV_PYTHON = "C:\ALXQuant\QuantCore\.venv\Scripts\python.exe"
$REQUIREMENTS = "C:\ALXQuant\QuantCore\requirements.txt"
$CC_PATH = "C:\ALXQuant\CommandCenter"
$NODE_JS = "C:\Program Files\nodejs\node.exe"

Write-Host "=== ALXQuant Deploy ===" -ForegroundColor Cyan
Write-Host "Inicio: $(Get-Date)" -ForegroundColor Yellow

# 1. Git pull
Write-Host "`n[1/5] Git pull..." -ForegroundColor Cyan
cd $ALXQUANT_PATH
& git pull origin main
if ($LASTEXITCODE -ne 0) { throw "Git pull falhou" }

# 2. Python deps
Write-Host "`n[2/5] Verificando dependencias Python..." -ForegroundColor Cyan
& $VENV_PYTHON -m pip install -r $REQUIREMENTS --upgrade --quiet
if ($LASTEXITCODE -ne 0) { Write-Host "Pip install teve avisos (nao crtico)" -ForegroundColor Yellow }

# 3. Node.js build
Write-Host "`n[3/5] Build CommandCenter..." -ForegroundColor Cyan
cd $CC_PATH
& $NODE_JS node_modules/.bin/vite build
if ($LASTEXITCODE -ne 0) { throw "Vite build falhou" }

# 4. Restart services
Write-Host "`n[4/5] Reiniciando servicos..." -ForegroundColor Cyan
& nssm restart ALXQuant-Server
& nssm restart ALXCommandCenter

# 5. Status
Write-Host "`n[5/5] Verificando status..." -ForegroundColor Cyan
& nssm status ALXQuant-Server
& nssm status ALXCommandCenter

Write-Host "`n=== Deploy concluido: $(Get-Date) ===" -ForegroundColor Green
