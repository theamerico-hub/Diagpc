# DiagPC - diagnostico de hardware (feito por Danilo Americo)
# Uso (PowerShell):
#   irm https://raw.githubusercontent.com/theamerico-hub/Diagpc/main/iniciar.ps1 | iex
& {
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $raw = 'https://raw.githubusercontent.com/theamerico-hub/Diagpc/main'
    $dir = Join-Path $env:SystemDrive 'DiagPC'
    $tools = Join-Path $dir 'ferramentas'

    Write-Host ''
    Write-Host '  DiagPC - diagnostico de hardware' -ForegroundColor Cyan
    Write-Host '  feito por Danilo Americo' -ForegroundColor DarkGray
    Write-Host ''
    try {
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Write-Host "  Baixando para $dir ..." -ForegroundColor Gray
        $nc = "?nocache=$([DateTime]::Now.Ticks)"
        Invoke-WebRequest "$raw/DiagPC.ps1$nc" -OutFile (Join-Path $dir 'DiagPC.ps1') -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest "$raw/Iniciar-DiagPC.bat$nc" -OutFile (Join-Path $dir 'Iniciar-DiagPC.bat') -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest "$raw/LEIA-ME.txt$nc" -OutFile (Join-Path $dir 'LEIA-ME.txt') -UseBasicParsing -ErrorAction SilentlyContinue
    } catch {
        Write-Host "  Falha no download: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $sc = Join-Path $tools 'smartctl.exe'
    if (-not (Test-Path $sc)) {
        try { Invoke-WebRequest "$raw/ferramentas/smartctl.exe" -OutFile $sc -UseBasicParsing -ErrorAction Stop }
        catch { Write-Host '  Aviso: smartctl nao baixado (saude % dos discos SATA ficara indisponivel).' -ForegroundColor Yellow }
    }
    Get-ChildItem $dir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    $versao = '?'
    $mv = Select-String -Path (Join-Path $dir 'DiagPC.ps1') -Pattern "VersaoDiag = '([^']+)'" | Select-Object -First 1
    if ($mv) { $versao = $mv.Matches[0].Groups[1].Value }
    Write-Host ''
    Write-Host "  Versao carregada: $versao" -ForegroundColor Green
    Write-Host ''
    Write-Host '  Abrindo o DiagPC como administrador...' -ForegroundColor Green
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$dir\DiagPC.ps1`""
    } catch {
        Write-Host '  E preciso aceitar o pedido de administrador. Rode o comando de novo.' -ForegroundColor Red
    }
}
