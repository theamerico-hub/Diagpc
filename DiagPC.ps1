#Requires -Version 5.1
<#
.SYNOPSIS
    DiagPC - Diagnóstico e teste de estresse de hardware para Windows 10/11.

.DESCRIPTION
    Roda por 10-30 minutos (ou o tempo que você escolher) e entrega um relatório com
    os problemas encontrados:
      - Temperaturas de CPU / GPU / SSD em repouso e sob carga (LibreHardwareMonitor)
      - Estresse de CPU com verificação de cálculo (detecta instabilidade, estilo Prime95)
      - Teste de memória RAM (padrões de bits, detecta pente com defeito)
      - Teste de SSD/HD (gravação + leitura sem cache, verifica integridade e velocidade)
      - Estresse de placa de vídeo (WebGL em tela cheia, detecta travamento do driver)
      - Teste combinado CPU+GPU (fonte, energia)
      - Saúde dos discos em % (estilo HD Sentinel), desgaste, setores ruins
      - Análise dos logs do Windows: desligamentos inesperados, tela azul (com o código),
        erros de hardware WHEA, erros de disco, driver de vídeo reiniciando, travamentos
      - Bateria (notebook), drivers com erro, pouca RAM, disco cheio, Windows em HD
    Se o PC desligar no meio do teste, rode o DiagPC de novo: ele detecta e informa
    em que etapa e com qual temperatura o PC desligou.

.EXAMPLE
    Clique duas vezes em Iniciar-DiagPC.bat
.EXAMPLE
    .\DiagPC.ps1 -Modo Completo
    .\DiagPC.ps1 -Modo Personalizado -Minutos 60 -SemGPU
#>
[CmdletBinding()]
param(
    [ValidateSet('Rapido', 'Completo', 'Diagnostico', 'Personalizado')]
    [string]$Modo,
    [ValidateRange(5, 480)]
    [int]$Minutos,
    [switch]$SemCPU,
    [switch]$SemRAM,
    [switch]$SemDisco,
    [switch]$SemGPU,
    [ValidateRange(1, 365)]
    [int]$DiasLogs = 30,
    [switch]$NaoAbrir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$VersaoDiag = '1.2'

# ---------------------------------------------------------------------------
#  Administrador
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'O DiagPC precisa de permissão de administrador. Solicitando...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "$v" }
    }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList }
    catch { Write-Host 'Não foi possível obter permissão de administrador.' -ForegroundColor Red; Read-Host 'ENTER para sair' | Out-Null }
    exit
}

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = "DiagPC $VersaoDiag - Diagnóstico de hardware" } catch {}

# ---------------------------------------------------------------------------
#  Pastas
# ---------------------------------------------------------------------------
$Base = $PSScriptRoot
if (-not $Base) { $Base = (Get-Location).Path }
$ToolsDir = Join-Path $Base 'ferramentas'
$RelRoot = Join-Path $Base 'Relatorios'
try {
    New-Item -ItemType Directory -Path $ToolsDir, $RelRoot -Force -ErrorAction Stop | Out-Null
    $teste = Join-Path $RelRoot '.teste'
    Set-Content -Path $teste -Value 'x' -ErrorAction Stop; Remove-Item $teste -Force
} catch {
    $RelRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DiagPC-Relatorios'
    $ToolsDir = Join-Path $env:LOCALAPPDATA 'DiagPC\ferramentas'
    New-Item -ItemType Directory -Path $ToolsDir, $RelRoot -Force | Out-Null
}
$ArqEstado = Join-Path $RelRoot '.estado.json'
$PastaRel = Join-Path $RelRoot ('{0}_{1:yyyy-MM-dd_HH-mm}' -f $env:COMPUTERNAME, (Get-Date))
New-Item -ItemType Directory -Path $PastaRel -Force | Out-Null
$ArqCsv = Join-Path $PastaRel 'amostras_sensores.csv'
$ArqHtml = Join-Path $PastaRel 'relatorio.html'
$ArqTxt = Join-Path $PastaRel 'resumo.txt'

$RepoRaw = 'https://raw.githubusercontent.com/theamerico-hub/Diagpc/main'
$LhmUrl = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.4/LibreHardwareMonitor-net472.zip'

# Limites de temperatura (°C)
$LIM = @{
    CpuAtencao = 85; CpuCritico = 95
    CpuRepousoAtencao = 65; CpuRepousoCritico = 80
    GpuAtencao = 83; GpuCritico = 90
    HotspotAtencao = 95; HotspotCritico = 105
    DiscoAtencao = 65; DiscoCritico = 75
    EmergCpu = 102; EmergGpu = 97
}

# ---------------------------------------------------------------------------
#  Código nativo (C#): estresse de CPU, teste de RAM, teste de disco
# ---------------------------------------------------------------------------
$CodigoCSharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class DiagSys {
    [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint esFlags);
    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")] private static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll")] private static extern bool SetConsoleMode(IntPtr h, uint mode);

    public static void ManterAcordado(bool ligado) {
        SetThreadExecutionState(ligado ? 0x80000003u : 0x80000000u);
    }
    public static void DesativarQuickEdit() {
        try {
            IntPtr h = GetStdHandle(-10);
            uint modo;
            if (GetConsoleMode(h, out modo)) { modo &= ~0x40u; modo |= 0x80u; SetConsoleMode(h, modo); }
        } catch { }
    }
}

public static class DiagCpu {
    private static volatile bool _run;
    private static List<Thread> _threads = new List<Thread>();
    public static long Errors;
    public static long Iterations;

    public static void Start(int threads) {
        Stop();
        Interlocked.Exchange(ref Errors, 0);
        Interlocked.Exchange(ref Iterations, 0);
        _run = true;
        for (int i = 0; i < threads; i++) {
            Thread t = new Thread(Worker);
            t.IsBackground = true;
            t.Priority = ThreadPriority.BelowNormal;
            t.Start();
            _threads.Add(t);
        }
    }
    public static void Stop() {
        _run = false;
        foreach (Thread t in _threads) { t.Join(5000); }
        _threads.Clear();
    }
    private static double Work(double[] buf) {
        Array.Clear(buf, 0, buf.Length);
        int mask = buf.Length - 1;
        double acc = 0.0;
        for (int i = 1; i < 120000; i++) {
            double x = i * 0.0007;
            acc += Math.Sqrt(x) * Math.Sin(x) + Math.Log(x + 1.0) * Math.Cos(x * 0.5);
            int k = (i * 7919) & mask;
            buf[k] = buf[k] * 0.5 + acc * 1e-6;
        }
        ulong h = 14695981039346656037UL;
        for (uint i = 0; i < 300000; i++) {
            h ^= i;
            h *= 1099511628211UL;
            h = (h << 13) | (h >> 51);
        }
        double s = 0.0;
        for (int i = 0; i < buf.Length; i++) s += buf[i];
        return acc + s + (double)(h & 0xFFFFFUL);
    }
    private static void Worker() {
        double[] buf = new double[32768];
        double reference = Work(buf);
        while (_run) {
            double v = Work(buf);
            if (v != reference) Interlocked.Increment(ref Errors);
            Interlocked.Increment(ref Iterations);
        }
    }
}

public static class DiagMem {
    private static volatile bool _run;
    private static List<Thread> _threads = new List<Thread>();
    private static List<ulong[]> _blocks = new List<ulong[]>();
    private const int BlockLongs = 8 * 1024 * 1024; // 64 MB por bloco
    public static long Errors;
    public static long Passes;
    public static long VerifiedMB;
    public static long AllocatedMB;
    public static string FirstError = "";

    public static long Allocate(long targetMB) {
        Free();
        long got = 0;
        try {
            while (got + 64 <= targetMB) {
                ulong[] b = new ulong[BlockLongs];
                _blocks.Add(b);
                got += 64;
            }
        } catch (OutOfMemoryException) { }
        AllocatedMB = got;
        return got;
    }
    public static void Start(int threads) {
        _run = true;
        Errors = 0; Passes = 0; VerifiedMB = 0; FirstError = "";
        int n = Math.Max(1, Math.Min(threads, _blocks.Count));
        for (int t = 0; t < n; t++) {
            int id = t; int total = n;
            Thread th = new Thread(() => Worker(id, total));
            th.IsBackground = true;
            th.Start();
            _threads.Add(th);
        }
    }
    public static void Stop() {
        _run = false;
        foreach (Thread t in _threads) t.Join(15000);
        _threads.Clear();
    }
    public static void Free() {
        Stop();
        _blocks.Clear();
        AllocatedMB = 0;
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
    }
    private static ulong Next(ref ulong s) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
    private static ulong Value(int pat, ulong idx, ulong seed, ref ulong rng) {
        switch (pat) {
            case 0: return 0x5555555555555555UL;
            case 1: return 0xAAAAAAAAAAAAAAAAUL;
            case 2: return idx ^ seed;
            case 3: return ~(idx ^ seed);
            case 4: return Next(ref rng);
            default:
                ulong bit = 1UL << (int)(idx & 63UL);
                return ((idx & 64UL) == 0UL) ? bit : ~bit;
        }
    }
    private static void Worker(int id, int n) {
        long pass = 0;
        while (_run) {
            for (int pat = 0; pat < 6 && _run; pat++) {
                ulong seed = ((ulong)(pass + 1) * 0x9E3779B97F4A7C15UL) ^ ((ulong)pat << 56);
                for (int b = id; b < _blocks.Count && _run; b += n) {
                    ulong[] a = _blocks[b];
                    ulong baseIdx = (ulong)b * (ulong)BlockLongs;
                    ulong rng = seed ^ baseIdx ^ 0xDEADBEEFUL; if (rng == 0) rng = 1;
                    for (int i = 0; i < a.Length; i++) a[i] = Value(pat, baseIdx + (ulong)i, seed, ref rng);
                }
                for (int b = id; b < _blocks.Count && _run; b += n) {
                    ulong[] a = _blocks[b];
                    ulong baseIdx = (ulong)b * (ulong)BlockLongs;
                    ulong rng = seed ^ baseIdx ^ 0xDEADBEEFUL; if (rng == 0) rng = 1;
                    for (int i = 0; i < a.Length; i++) {
                        ulong e = Value(pat, baseIdx + (ulong)i, seed, ref rng);
                        ulong g = a[i];
                        if (g != e) {
                            long c = Interlocked.Increment(ref Errors);
                            if (c == 1) FirstError = string.Format("bloco {0}, posicao {1}, padrao {2}: esperado 0x{3:X16}, lido 0x{4:X16} (bits trocados 0x{5:X16})", b, i, pat, e, g, e ^ g);
                        }
                    }
                    Interlocked.Add(ref VerifiedMB, 64);
                }
            }
            pass++;
            if (id == 0) Interlocked.Increment(ref Passes);
        }
    }
}

public static class DiagDisk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(SafeFileHandle h, IntPtr buf, uint n, out uint written, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(SafeFileHandle h, IntPtr buf, uint n, out uint read, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);

    private const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    private const uint CREATE_ALWAYS = 2, OPEN_EXISTING = 3;
    private const uint NO_BUFFERING = 0x20000000, WRITE_THROUGH = 0x80000000, SEQUENTIAL = 0x08000000;
    private const int CH = 4 * 1024 * 1024;

    public static volatile bool Cancel;
    public static volatile bool Done;
    public static volatile bool SetupFailed;
    public static string Etapa = "";
    public static double WriteMBps, ReadMBps;
    public static long Mismatches, IoErrors, DoneMB, TotalMB, WrittenMB;
    public static string Error = "";
    private static Thread _t;

    public static void Start(string path, long totalMB) {
        Cancel = false; Done = false; SetupFailed = false; Etapa = "Preparando";
        WriteMBps = 0; ReadMBps = 0; Mismatches = 0; IoErrors = 0; DoneMB = 0; WrittenMB = 0;
        TotalMB = (totalMB / 4) * 4; Error = "";
        _t = new Thread(() => Run(path, TotalMB));
        _t.IsBackground = true;
        _t.Start();
    }
    public static void Stop() { Cancel = true; if (_t != null) _t.Join(60000); }

    private static void MakeChunk(long[] baseData, long[] dst, long chunk) {
        Array.Copy(baseData, dst, baseData.Length);
        for (int i = 0; i < dst.Length; i += 512) dst[i] = chunk * 1000003L + i;
    }

    private static void Run(string path, long totalMB) {
        IntPtr buf = IntPtr.Zero;
        int L = CH / 8;
        long chunks = totalMB / 4;
        long[] baseData = new long[L], exp = new long[L], got = new long[L];
        Random r = new Random(12345);
        byte[] tmp = new byte[8];
        for (int i = 0; i < L; i++) { r.NextBytes(tmp); baseData[i] = BitConverter.ToInt64(tmp, 0); }
        try {
            buf = VirtualAlloc(IntPtr.Zero, (UIntPtr)(uint)CH, 0x3000, 0x04);
            if (buf == IntPtr.Zero) { SetupFailed = true; Error = "VirtualAlloc falhou"; return; }
            Stopwatch sw = new Stopwatch();
            Etapa = "Gravando";
            using (SafeFileHandle hw = CreateFile(path, GENERIC_WRITE, 0, IntPtr.Zero, CREATE_ALWAYS, NO_BUFFERING | WRITE_THROUGH, IntPtr.Zero)) {
                if (hw.IsInvalid) { SetupFailed = true; Error = "Nao foi possivel criar o arquivo de teste (Win32 " + Marshal.GetLastWin32Error() + ")"; return; }
                for (long c = 0; c < chunks && !Cancel; c++) {
                    MakeChunk(baseData, exp, c);
                    Marshal.Copy(exp, 0, buf, L);
                    uint w;
                    sw.Start();
                    bool ok = WriteFile(hw, buf, (uint)CH, out w, IntPtr.Zero);
                    sw.Stop();
                    if (!ok || w != CH) { IoErrors++; Error = "Erro de ESCRITA no bloco " + c + " (Win32 " + Marshal.GetLastWin32Error() + ")"; break; }
                    DoneMB = (c + 1) * 4;
                }
            }
            WrittenMB = DoneMB;
            if (sw.Elapsed.TotalSeconds > 0) WriteMBps = WrittenMB / sw.Elapsed.TotalSeconds;
            if (Cancel || WrittenMB == 0) return;

            Etapa = "Lendo e verificando";
            DoneMB = 0;
            sw.Reset();
            using (SafeFileHandle hr = CreateFile(path, GENERIC_READ, 1, IntPtr.Zero, OPEN_EXISTING, NO_BUFFERING | SEQUENTIAL, IntPtr.Zero)) {
                if (hr.IsInvalid) { SetupFailed = true; Error = "Nao foi possivel abrir o arquivo de teste (Win32 " + Marshal.GetLastWin32Error() + ")"; return; }
                long wchunks = WrittenMB / 4;
                for (long c = 0; c < wchunks && !Cancel; c++) {
                    uint rd;
                    sw.Start();
                    bool ok = ReadFile(hr, buf, (uint)CH, out rd, IntPtr.Zero);
                    sw.Stop();
                    if (!ok || rd != CH) { IoErrors++; Error = "Erro de LEITURA no bloco " + c + " (Win32 " + Marshal.GetLastWin32Error() + ")"; break; }
                    Marshal.Copy(buf, got, 0, L);
                    MakeChunk(baseData, exp, c);
                    for (int i = 0; i < L; i++) {
                        if (got[i] != exp[i]) {
                            Mismatches++;
                            if (Error == "") Error = "Dados CORROMPIDOS no bloco " + c + ", offset " + ((long)i * 8);
                        }
                    }
                    DoneMB = (c + 1) * 4;
                }
            }
            if (sw.Elapsed.TotalSeconds > 0) ReadMBps = DoneMB / sw.Elapsed.TotalSeconds;
        } catch (Exception ex) {
            SetupFailed = true; Error = ex.Message;
        } finally {
            if (buf != IntPtr.Zero) VirtualFree(buf, UIntPtr.Zero, 0x8000);
            try { File.Delete(path); } catch { }
            Etapa = "Concluido";
            Done = true;
        }
    }
}
'@

if (-not ('DiagCpu' -as [type])) {
    try { Add-Type -TypeDefinition $CodigoCSharp -Language CSharp -ErrorAction Stop }
    catch {
        Write-Host "Erro ao compilar o módulo de testes: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'ENTER para sair' | Out-Null
        exit 1
    }
}

# ---------------------------------------------------------------------------
#  Página de estresse da GPU (WebGL)
# ---------------------------------------------------------------------------
$GpuHtml = @'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>DiagPC GPU iniciando</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden;cursor:none}
canvas{width:100vw;height:100vh;display:block}
#o{position:fixed;top:14px;left:14px;color:#fff;font:16px "Segoe UI",Arial,sans-serif;background:rgba(0,0,0,.65);padding:10px 14px;border-radius:8px}</style></head>
<body><canvas id="c"></canvas><div id="o">DiagPC - teste de placa de vídeo</div>
<script>
var q=new URLSearchParams(location.search),dur=+(q.get('s')||300),t0=performance.now();
var c=document.getElementById('c'),o=document.getElementById('o'),lost=false;
function fmt(s){s=Math.max(0,Math.round(s));return Math.floor(s/60)+':'+('0'+(s%60)).slice(-2);}
function fail(m){lost=true;document.title='DiagPC GPU FALHA '+m;o.style.background='#b00000';o.textContent='FALHA NA PLACA DE VIDEO: '+m;}
var gl=c.getContext('webgl',{antialias:false,powerPreference:'high-performance',preserveDrawingBuffer:false})||c.getContext('experimental-webgl');
if(!gl){fail('WebGL indisponivel (driver de video?)');}else{
 var vs='attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}';
 var fs='precision highp float;uniform vec2 R;uniform float T;uniform float N;'+
 'void main(){vec2 uv=(gl_FragCoord.xy*2.0-R)/R.y;vec3 col=vec3(0.0);'+
 'for(int i=0;i<2000;i++){float f=float(i);if(f>=N)break;'+
 'vec2 p=uv*(1.0+0.15*sin(T*0.3+f*0.01));p+=vec2(sin(T*0.5+f*0.37),cos(T*0.4+f*0.23))*0.6;'+
 'float d=abs(length(p)-0.25-0.2*sin(f*0.11+T));'+
 'col+=(0.5+0.5*cos(vec3(0.0,2.0,4.0)+f*0.05+T))*0.0015/(d+0.002);}'+
 'col*=48.0/max(N,48.0);col=col/(1.0+col);gl_FragColor=vec4(col,1.0);}';
 function sh(t,s){var x=gl.createShader(t);gl.shaderSource(x,s);gl.compileShader(x);if(!gl.getShaderParameter(x,gl.COMPILE_STATUS))fail('shader: '+gl.getShaderInfoLog(x));return x;}
 var pr=gl.createProgram();gl.attachShader(pr,sh(gl.VERTEX_SHADER,vs));gl.attachShader(pr,sh(gl.FRAGMENT_SHADER,fs));gl.linkProgram(pr);gl.useProgram(pr);
 var b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);
 gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]),gl.STATIC_DRAW);
 var lp=gl.getAttribLocation(pr,'p');gl.enableVertexAttribArray(lp);gl.vertexAttribPointer(lp,2,gl.FLOAT,false,0,0);
 var uR=gl.getUniformLocation(pr,'R'),uT=gl.getUniformLocation(pr,'T'),uN=gl.getUniformLocation(pr,'N');
 c.addEventListener('webglcontextlost',function(e){e.preventDefault();fail('contexto WebGL perdido - driver/GPU travou ou reiniciou');},false);
 var n=32,frames=0,last=performance.now(),fps=0,W=0,H=0;
 function resize(){var d=window.devicePixelRatio||1,w=Math.floor(innerWidth*d),h=Math.floor(innerHeight*d);if(w!==W||h!==H){W=w;H=h;c.width=w;c.height=h;gl.viewport(0,0,w,h);}}
 function frame(now){if(lost)return;resize();
  gl.uniform2f(uR,W,H);gl.uniform1f(uT,(now-t0)/1000);gl.uniform1f(uN,n);gl.drawArrays(gl.TRIANGLES,0,6);
  frames++;
  if(now-last>=1000){fps=frames*1000/(now-last);frames=0;last=now;
   if(fps>40&&n<2000)n=Math.min(2000,Math.ceil(n*1.3));else if(fps<22&&n>8)n=Math.max(8,Math.floor(n*0.8));
   var rest=dur-(now-t0)/1000;
   document.title='DiagPC GPU fps='+fps.toFixed(0)+' carga='+n;
   o.textContent='DiagPC - teste de placa de video | '+fps.toFixed(0)+' FPS | carga '+n+' | restante '+fmt(rest)+' | Alt+Tab mostra o console';}
  requestAnimationFrame(frame);}
 requestAnimationFrame(frame);}
</script></body></html>
'@

# ---------------------------------------------------------------------------
#  Estado global
# ---------------------------------------------------------------------------
$script:Achados = New-Object System.Collections.Generic.List[object]
$script:Amostras = New-Object System.Collections.Generic.List[object]
$script:Fases = New-Object System.Collections.Generic.List[object]
$script:Eventos = New-Object System.Collections.Generic.List[object]
$script:Discos = New-Object System.Collections.Generic.List[object]
$script:Inv = [ordered]@{}
$script:Flags = @{}
$script:Conclusoes = New-Object System.Collections.Generic.List[string]
$script:FaseAtual = 'Início'
$script:InicioGeral = Get-Date
$script:InicioTestes = $null
$script:PidInicio = (Get-Process -Id $PID).StartTime.ToString('yyyy-MM-ddTHH:mm:ss')
$script:MaxCpu = $null
$script:MaxGpu = $null
$script:LHM = $null
$script:LHMErro = ''
$script:NvSmi = $null
$script:GpuAtivo = $false
$script:CsvIniciado = $false
$script:Concluido = $false
$script:EhNotebook = $false
$script:FonteTempCpu = ''
$Cult = [Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
#  Utilidades
# ---------------------------------------------------------------------------
function Add-Achado {
    param(
        [ValidateSet('CRITICO', 'ATENCAO', 'INFO', 'OK')][string]$Nivel,
        [string]$Categoria, [string]$Titulo, [string]$Detalhe = ''
    )
    $script:Achados.Add([pscustomobject]@{ Nivel = $Nivel; Categoria = $Categoria; Titulo = $Titulo; Detalhe = $Detalhe })
    $cor = @{ CRITICO = 'Red'; ATENCAO = 'Yellow'; INFO = 'DarkCyan'; OK = 'Green' }[$Nivel]
    $rot = @{ CRITICO = '[CRÍTICO]'; ATENCAO = '[ATENÇÃO]'; INFO = '[INFO]   '; OK = '[OK]     ' }[$Nivel]
    Write-Host ("   {0} {1}" -f $rot, $Titulo) -ForegroundColor $cor
}

function Add-Evento($ev, [string]$tipo) {
    $msg = ''
    try { $msg = ($ev.Message -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' ' } catch {}
    if (-not $msg) { try { $msg = ($ev.Properties | ForEach-Object { $_.Value }) -join ' ' } catch {} }
    if ($msg.Length -gt 260) { $msg = $msg.Substring(0, 260) + '...' }
    $script:Eventos.Add([pscustomobject]@{ Hora = $ev.TimeCreated; Tipo = $tipo; Fonte = $ev.ProviderName; Id = $ev.Id; Descricao = $msg })
}

function Get-Eventos {
    param([string]$Log, [string]$Provider, [int[]]$Id, [datetime]$Desde)
    $f = @{ LogName = $Log; StartTime = $Desde }
    if ($Provider) { $f.ProviderName = $Provider }
    if ($Id) { $f.Id = $Id }
    @(Get-WinEvent -FilterHashtable $f -ErrorAction SilentlyContinue)
}

function Get-Num($v) {
    if ($null -eq $v) { return $null }
    $d = 0.0
    if ([double]::TryParse(([string]$v).Trim(), [Globalization.NumberStyles]::Float, $Cult, [ref]$d)) { return $d }
    return $null
}

function Get-Max($a, $b) {
    if ($null -eq $a) { return $b }
    if ($null -eq $b) { return $a }
    return [Math]::Max([double]$a, [double]$b)
}

function Fmt($v, [string]$u = '', [int]$d = 0) {
    if ($null -eq $v) { return '--' }
    return ("{0:N$d}{1}" -f [double]$v, $u)
}

function Format-Duracao([double]$seg) {
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, $seg))
    if ($ts.TotalHours -ge 1) { return '{0}h{1:00}m' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes }
    return '{0:00}:{1:00}' -f [int][Math]::Floor($ts.TotalMinutes), $ts.Seconds
}

function Write-Etapa([string]$titulo, [string]$sub = '') {
    Write-Host ''
    Write-Host (("== {0} " -f $titulo).PadRight(78, '=')) -ForegroundColor Cyan
    if ($sub) { Write-Host "   $sub" -ForegroundColor DarkGray }
}

function Write-Linha([string]$t) {
    $w = 119
    try { $w = [Console]::WindowWidth - 1 } catch {}
    if ($w -lt 40) { $w = 79 }
    if ($t.Length -gt $w) { $t = $t.Substring(0, $w) }
    Write-Host ("`r" + $t.PadRight($w)) -NoNewline -ForegroundColor Gray
}

function Test-TeclaPular {
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'P') { return $true }
        }
    } catch {}
    return $false
}

function HtmlEnc([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }

# ---------------------------------------------------------------------------
#  Estado em disco (detecta se o PC desligou durante o teste)
# ---------------------------------------------------------------------------
function Save-Estado([string]$status) {
    $u = $null
    if ($script:Amostras.Count) { $u = $script:Amostras[$script:Amostras.Count - 1] }
    $o = [ordered]@{
        Status = $status; PID = $PID; PIDInicio = $script:PidInicio
        Inicio = $script:InicioGeral.ToString('yyyy-MM-ddTHH:mm:ss')
        UltimaAtualizacao = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        Fase = $script:FaseAtual; Pasta = $PastaRel
        CpuTemp = $(if ($u) { $u.CpuTemp }); GpuTemp = $(if ($u) { $u.GpuTemp })
        CpuLoad = $(if ($u) { $u.CpuLoad }); GpuLoad = $(if ($u) { $u.GpuLoad })
        CpuTempMax = $script:MaxCpu; GpuTempMax = $script:MaxGpu
    }
    try { ($o | ConvertTo-Json) | Set-Content -Path $ArqEstado -Encoding UTF8 -ErrorAction Stop } catch {}
}

function Test-ExecucaoAnterior {
    if (-not (Test-Path $ArqEstado)) { return }
    $e = $null
    try { $e = Get-Content $ArqEstado -Raw | ConvertFrom-Json } catch { return }
    if (-not $e -or $e.Status -ne 'Rodando') { return }

    $p = Get-Process -Id $e.PID -ErrorAction SilentlyContinue
    if ($p -and $p.Id -ne $PID -and $p.StartTime.ToString('yyyy-MM-ddTHH:mm:ss') -eq $e.PIDInicio) {
        Write-Host 'Já existe outro DiagPC rodando neste computador. Feche-o antes.' -ForegroundColor Red
        Read-Host 'ENTER para sair' | Out-Null
        exit
    }

    Write-Etapa 'Execução anterior não terminou'
    $ultima = [datetime]::ParseExact($e.UltimaAtualizacao, 'yyyy-MM-ddTHH:mm:ss', $Cult)
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $leit = 'Últimas leituras antes de parar: CPU {0} ({1}), GPU {2} ({3}). Máximas da sessão: CPU {4}, GPU {5}. Dados da sessão: {6}' -f `
        (Fmt $e.CpuTemp '°C'), (Fmt $e.CpuLoad '% carga'), (Fmt $e.GpuTemp '°C'), (Fmt $e.GpuLoad '% carga'),
        (Fmt $e.CpuTempMax '°C'), (Fmt $e.GpuTempMax '°C'), $e.Pasta

    if ($boot -gt $ultima) {
        $kp = Get-Eventos 'System' 'Microsoft-Windows-Kernel-Power' @(41) $ultima.AddMinutes(-2)
        $script:Flags.DesligouNoTeste = $true
        $script:Flags.TempAoDesligar = (Get-Max $e.CpuTemp $e.GpuTemp)
        $script:Flags.QuenteAoDesligar = (($null -ne $e.CpuTemp -and $e.CpuTemp -ge $LIM.CpuAtencao) -or ($null -ne $e.GpuTemp -and $e.GpuTemp -ge $LIM.GpuAtencao))
        if ($kp.Count) {
            Add-Achado CRITICO 'Desligamento durante o teste' ("O computador DESLIGOU/REINICIOU SOZINHO durante o teste anterior (etapa: {0}, às {1:dd/MM HH:mm:ss})" -f $e.Fase, $ultima) $leit
        } else {
            Add-Achado ATENCAO 'Desligamento durante o teste' ("O computador reiniciou durante o teste anterior (etapa: {0}, às {1:dd/MM HH:mm:ss}) - pode ter sido manual" -f $e.Fase, $ultima) $leit
        }
    } else {
        Add-Achado INFO 'Execução anterior' ("O teste anterior foi interrompido (janela fechada) na etapa: {0}" -f $e.Fase) $leit
    }
    try { Move-Item $ArqEstado (Join-Path $RelRoot '.estado-anterior.json') -Force } catch {}
}

# ---------------------------------------------------------------------------
#  Sensores
# ---------------------------------------------------------------------------
function Initialize-Sensores {
    Write-Etapa 'Inicializando sensores de temperatura'
    $dll = Join-Path $ToolsDir 'LibreHardwareMonitorLib.dll'
    if (-not (Test-Path $dll)) {
        try {
            Write-Host '   Baixando LibreHardwareMonitor (leitura de sensores)...' -ForegroundColor Gray
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $zip = Join-Path $env:TEMP 'diagpc_lhm.zip'
            $tmp = Join-Path $env:TEMP 'diagpc_lhm'
            Invoke-WebRequest -Uri $LhmUrl -OutFile $zip -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            Get-ChildItem $tmp -Recurse -Filter *.dll | Copy-Item -Destination $ToolsDir -Force
        } catch {
            $script:LHMErro = "Download falhou: $($_.Exception.Message)"
        }
    }
    if (Test-Path $dll) {
        try {
            Get-ChildItem $ToolsDir -Filter *.dll | Unblock-File -ErrorAction SilentlyContinue
            if (-not ('LibreHardwareMonitor.Hardware.Computer' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
            $c = New-Object LibreHardwareMonitor.Hardware.Computer
            $c.IsCpuEnabled = $true
            $c.IsGpuEnabled = $true
            $c.IsMemoryEnabled = $true
            $c.IsMotherboardEnabled = $true
            $c.IsStorageEnabled = $true
            $c.Open()
            $script:LHM = $c
            Write-Host '   LibreHardwareMonitor carregado.' -ForegroundColor Green
        } catch {
            $script:LHMErro = "Falha ao carregar: $($_.Exception.Message)"
        }
    }
    if (-not $script:LHM) {
        Write-Host "   Sensores avançados indisponíveis ($($script:LHMErro))" -ForegroundColor Yellow
        Write-Host '   Usando sensores básicos do Windows (temperatura da CPU pode não aparecer).' -ForegroundColor Yellow
    }
    foreach ($cand in @((Join-Path $env:WINDIR 'System32\nvidia-smi.exe'), "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) {
        if (Test-Path $cand) { $script:NvSmi = $cand; break }
    }
    if (-not $script:NvSmi) { $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue; if ($cmd) { $script:NvSmi = $cmd.Source } }
}

function Read-Sensores {
    $s = [pscustomobject]@{
        Hora = Get-Date; Fase = $script:FaseAtual
        CpuTemp = $null; CpuLoad = $null; CpuClock = $null; CpuPerf = $null; CpuPower = $null
        GpuTemp = $null; GpuHotspot = $null; GpuLoad = $null; GpuClock = $null; GpuPower = $null
        DiscoTemp = $null; RamUso = $null; GpuFps = $null
    }
    if ($script:LHM) {
        try {
            $melhorGpuLoad = -1
            foreach ($hw in $script:LHM.Hardware) {
                $hw.Update()
                $sens = @($hw.Sensors)
                foreach ($sub in $hw.SubHardware) { $sub.Update(); $sens += @($sub.Sensors) }
                $tipo = $hw.HardwareType.ToString()
                $temps = @($sens | Where-Object { $_.SensorType.ToString() -eq 'Temperature' -and $null -ne $_.Value -and $_.Value -gt 0 -and $_.Value -lt 150 })
                if ($tipo -eq 'Cpu') {
                    $t = @($temps | Where-Object { $_.Name -notmatch 'Distance|TjMax|Average' })
                    if ($t.Count) { $s.CpuTemp = Get-Max $s.CpuTemp ($t | Measure-Object Value -Maximum).Maximum; $script:FonteTempCpu = 'LibreHardwareMonitor' }
                    $l = $sens | Where-Object { $_.SensorType.ToString() -eq 'Load' -and $_.Name -eq 'CPU Total' } | Select-Object -First 1
                    if ($l -and $null -ne $l.Value) { $s.CpuLoad = [double]$l.Value }
                    $ck = @($sens | Where-Object { $_.SensorType.ToString() -eq 'Clock' -and $_.Name -like 'Core #*' -and $_.Value -gt 0 })
                    if ($ck.Count) { $s.CpuClock = ($ck | Measure-Object Value -Average).Average }
                    $pw = $sens | Where-Object { $_.SensorType.ToString() -eq 'Power' -and $_.Name -match 'Package' -and $null -ne $_.Value } | Select-Object -First 1
                    if ($pw) { $s.CpuPower = [double]$pw.Value }
                } elseif ($tipo -like 'Gpu*') {
                    $core = $temps | Where-Object { $_.Name -eq 'GPU Core' } | Select-Object -First 1
                    if (-not $core) { $core = $temps | Where-Object { $_.Name -notmatch 'Hot ?Spot|Memory|Junction' } | Select-Object -First 1 }
                    $hot = $temps | Where-Object { $_.Name -match 'Hot ?Spot|Junction' } | Select-Object -First 1
                    if ($core) { $s.GpuTemp = Get-Max $s.GpuTemp $core.Value }
                    if ($hot) { $s.GpuHotspot = Get-Max $s.GpuHotspot $hot.Value }
                    $ld = @($sens | Where-Object { $_.SensorType.ToString() -eq 'Load' -and $_.Name -match '^GPU Core$|^D3D 3D$' -and $null -ne $_.Value })
                    if ($ld.Count) {
                        $v = ($ld | Measure-Object Value -Maximum).Maximum
                        if ($v -gt $melhorGpuLoad) {
                            $melhorGpuLoad = $v; $s.GpuLoad = [double]$v
                            $gc = $sens | Where-Object { $_.SensorType.ToString() -eq 'Clock' -and $_.Name -eq 'GPU Core' } | Select-Object -First 1
                            if ($gc) { $s.GpuClock = $gc.Value }
                            $gp = $sens | Where-Object { $_.SensorType.ToString() -eq 'Power' -and $_.Name -match 'Package|Board|Total|GPU Power|GPU Core' -and $null -ne $_.Value } | Select-Object -First 1
                            if ($gp) { $s.GpuPower = $gp.Value }
                        }
                    }
                } elseif ($tipo -eq 'Storage') {
                    if ($temps.Count) { $s.DiscoTemp = Get-Max $s.DiscoTemp ($temps | Measure-Object Value -Maximum).Maximum }
                }
            }
        } catch {}
    }
    # Contadores do Windows (nomes não traduzidos)
    try {
        $pi = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        if ($null -eq $s.CpuLoad) { $s.CpuLoad = [double]$pi.PercentProcessorTime }
        $s.CpuPerf = [double]$pi.PercentProcessorPerformance
        if ($null -eq $s.CpuClock -and $pi.ProcessorFrequency) { $s.CpuClock = [double]$pi.ProcessorFrequency * $pi.PercentProcessorPerformance / 100 }
    } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $s.RamUso = 100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
    } catch {}
    # Fallback NVIDIA
    if ($null -eq $s.GpuTemp -and $script:NvSmi) {
        try {
            $o = & $script:NvSmi --query-gpu=temperature.gpu,utilization.gpu,clocks.sm,power.draw --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            $p = $o -split ',\s*'
            $s.GpuTemp = Get-Num $p[0]; $s.GpuLoad = Get-Num $p[1]; $s.GpuClock = Get-Num $p[2]; $s.GpuPower = Get-Num $p[3]
        } catch {}
    }
    # Fallback ACPI (impreciso)
    if ($null -eq $s.CpuTemp -and -not $script:LHM) {
        try {
            $tz = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
            $m = ($tz | ForEach-Object { $_.CurrentTemperature / 10 - 273.15 } | Where-Object { $_ -gt 5 -and $_ -lt 130 } | Measure-Object -Maximum).Maximum
            if ($m) { $s.CpuTemp = $m; $script:FonteTempCpu = 'zona térmica ACPI (aproximado)' }
        } catch {}
    }
    # Fallback carga GPU
    if ($null -eq $s.GpuLoad -and $script:GpuAtivo) {
        try {
            $ge = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $_.Name -like '*engtype_3D' })
            $v = ($ge | Measure-Object UtilizationPercentage -Sum).Sum
            if ($null -ne $v) { $s.GpuLoad = [Math]::Min(100, [double]$v) }
        } catch {}
    }
    # FPS do teste de GPU (lido do título da janela)
    if ($script:GpuAtivo) {
        $w = Get-Process -Name msedge, chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'DiagPC GPU*' } | Select-Object -First 1
        if ($w) {
            $script:GpuTitulo = $w.MainWindowTitle
            if ($w.MainWindowTitle -match 'fps=(\d+)') { $s.GpuFps = [double]$Matches[1] }
            if ($w.MainWindowTitle -like '*FALHA*') { $script:GpuFalhaMsg = $w.MainWindowTitle }
        }
    }
    return $s
}

function Add-Amostra($s) {
    $script:Amostras.Add($s)
    $script:MaxCpu = Get-Max $script:MaxCpu $s.CpuTemp
    $script:MaxGpu = Get-Max $script:MaxGpu $s.GpuTemp
    $props = 'CpuTemp', 'CpuLoad', 'CpuClock', 'CpuPerf', 'CpuPower', 'GpuTemp', 'GpuHotspot', 'GpuLoad', 'GpuClock', 'GpuPower', 'GpuFps', 'DiscoTemp', 'RamUso'
    try {
        if (-not $script:CsvIniciado) {
            Set-Content -Path $ArqCsv -Value ('Hora;Etapa;' + ($props -join ';')) -Encoding UTF8
            $script:CsvIniciado = $true
        }
        $vals = foreach ($p in $props) { if ($null -eq $s.$p) { '' } else { '{0:0.#}' -f [double]$s.$p } }
        Add-Content -Path $ArqCsv -Value ((@($s.Hora.ToString('HH:mm:ss'), $s.Fase) + @($vals)) -join ';') -Encoding UTF8
    } catch {}
    Save-Estado 'Rodando'
}

function Format-Leitura($s) {
    $cpu = 'CPU {0} {1}' -f (Fmt $s.CpuLoad '%'), (Fmt $s.CpuTemp '°C')
    if ($s.CpuClock) { $cpu += ' {0:N2}GHz' -f ($s.CpuClock / 1000) }
    $gpu = 'GPU {0} {1}' -f (Fmt $s.GpuLoad '%'), (Fmt $s.GpuTemp '°C')
    if ($null -ne $s.GpuFps) { $gpu += " {0:N0}fps" -f $s.GpuFps }
    return '{0} | {1} | RAM {2}' -f $cpu, $gpu, (Fmt $s.RamUso '%')
}

# ---------------------------------------------------------------------------
#  Motor das etapas
# ---------------------------------------------------------------------------
function Invoke-Fase {
    param(
        [string]$Nome, [int]$Segundos,
        [scriptblock]$Iniciar = {}, [scriptblock]$Parar = {},
        [scriptblock]$Status = { '' }, [scriptblock]$Terminou = { $false }
    )
    $script:FaseAtual = $Nome
    Write-Etapa $Nome ("duração prevista: {0}   (aperte P para pular esta etapa)" -f (Format-Duracao $Segundos))
    $reg = [pscustomobject]@{ Nome = $Nome; Inicio = Get-Date; Fim = $null; Situacao = 'Concluída'; Obs = '' }
    $script:Fases.Add($reg)
    $quentes = 0
    try {
        & $Iniciar
        $inicio = Get-Date
        while ($true) {
            $dec = ((Get-Date) - $inicio).TotalSeconds
            if ($dec -ge $Segundos) { break }
            if (& $Terminou) { break }
            $s = Read-Sensores
            Add-Amostra $s
            $extra = & $Status
            Write-Linha (' {0} | {1} | resta {2}' -f (Format-Leitura $s), $extra, (Format-Duracao ($Segundos - $dec)))
            if (($null -ne $s.CpuTemp -and $s.CpuTemp -ge $LIM.EmergCpu) -or ($null -ne $s.GpuTemp -and $s.GpuTemp -ge $LIM.EmergGpu)) { $quentes++ } else { $quentes = 0 }
            if ($quentes -ge 3) {
                $reg.Situacao = 'Abortada'
                $reg.Obs = 'Temperatura em nível de emergência - etapa interrompida para proteger o hardware'
                $script:Flags.Emergencia = $true
                break
            }
            if (Test-TeclaPular) { $reg.Situacao = 'Pulada pelo usuário'; break }
            $espera = [int](2000 - ((Get-Date) - $s.Hora).TotalMilliseconds)
            if ($espera -gt 50) { Start-Sleep -Milliseconds $espera }
        }
    } finally {
        & $Parar
        $reg.Fim = Get-Date
        Write-Host ''
        if ($reg.Situacao -ne 'Concluída') { Write-Host "   Etapa: $($reg.Situacao). $($reg.Obs)" -ForegroundColor Yellow }
    }
}

function Get-StatsFase([string]$nome) {
    $a = @($script:Amostras | Where-Object { $_.Fase -eq $nome })
    $r = [ordered]@{ N = $a.Count }
    foreach ($p in 'CpuTemp', 'GpuTemp', 'GpuHotspot', 'DiscoTemp', 'CpuPower', 'GpuPower') {
        $m = @($a | Where-Object { $null -ne $_.$p } | ForEach-Object { $_.$p })
        $r["${p}Max"] = $(if ($m.Count) { ($m | Measure-Object -Maximum).Maximum } else { $null })
        $r["${p}Med"] = $(if ($m.Count) { ($m | Measure-Object -Average).Average } else { $null })
    }
    foreach ($p in 'CpuLoad', 'GpuLoad', 'CpuClock', 'CpuPerf', 'GpuFps', 'RamUso') {
        $m = @($a | Where-Object { $null -ne $_.$p } | ForEach-Object { $_.$p })
        $r["${p}Med"] = $(if ($m.Count) { ($m | Measure-Object -Average).Average } else { $null })
    }
    return [pscustomobject]$r
}

function Find-Navegador {
    $c = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($x in $c) { if ($x -and (Test-Path $x)) { return $x } }
    return $null
}

function Start-GpuStress([int]$segundos) {
    $nav = Find-Navegador
    if (-not $nav) { return $false }
    $html = Join-Path $env:TEMP 'diagpc_gpu.html'
    Set-Content -Path $html -Value $GpuHtml -Encoding UTF8
    $perfil = Join-Path $env:TEMP 'diagpc_navegador'
    $url = 'file:///' + ($html -replace '\\', '/') + "?s=$segundos"
    $a = @("--kiosk", "`"$url`"", '--edge-kiosk-type=fullscreen', '--no-first-run', '--no-default-browser-check',
        "--user-data-dir=`"$perfil`"", '--ignore-gpu-blocklist', '--force_high_performance_gpu',
        '--disable-backgrounding-occluded-windows', '--disable-renderer-backgrounding',
        '--disable-background-timer-throttling', '--disable-features=CalculateNativeWinOcclusion')
    $script:GpuFalhaMsg = $null
    $script:GpuTitulo = $null
    Start-Process -FilePath $nav -ArgumentList $a | Out-Null
    $script:GpuAtivo = $true
    $script:GpuNavegador = Split-Path $nav -Leaf
    return $true
}

function Stop-GpuStress {
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*diagpc_navegador*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
    $script:GpuAtivo = $false
}

# ---------------------------------------------------------------------------
#  Coletas
# ---------------------------------------------------------------------------
function Get-Inventario {
    Write-Etapa 'Coletando informações do computador'
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $bb = Get-CimInstance Win32_BaseBoard
    $bios = Get-CimInstance Win32_BIOS
    $gpus = @(Get-CimInstance Win32_VideoController)
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $enc = Get-CimInstance Win32_SystemEnclosure

    $notebookTipos = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
    if (@($enc.ChassisTypes | Where-Object { $notebookTipos -contains $_ }).Count) { $script:EhNotebook = $true }
    if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { $script:EhNotebook = $true }

    $script:Inv['Computador'] = '{0} - {1} {2}' -f $env:COMPUTERNAME, $cs.Manufacturer, $cs.Model
    $script:Inv['Tipo'] = $(if ($script:EhNotebook) { 'Notebook' } else { 'Desktop' })
    $script:Inv['Windows'] = '{0} (build {1})' -f $os.Caption, $os.BuildNumber
    $script:Inv['Ligado desde'] = '{0:dd/MM/yyyy HH:mm} ({1})' -f $os.LastBootUpTime, (Format-Duracao ((Get-Date) - $os.LastBootUpTime).TotalSeconds)
    $script:Inv['Processador'] = '{0} - {1} núcleos / {2} threads' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors
    $script:Inv['Placa-mãe'] = '{0} {1}' -f $bb.Manufacturer, $bb.Product
    $biosData = $bios.ReleaseDate
    $script:Inv['BIOS'] = '{0} ({1:dd/MM/yyyy})' -f $bios.SMBIOSBIOSVersion, $biosData
    $totalGB = $cs.TotalPhysicalMemory / 1GB
    $script:Inv['Memória RAM'] = '{0:N1} GB ({1} pente(s))' -f $totalGB, $mods.Count
    $script:Modulos = foreach ($m in $mods) {
        [pscustomobject]@{
            Slot = $m.DeviceLocator; Tamanho = '{0:N0} GB' -f ($m.Capacity / 1GB)
            Velocidade = '{0} MHz (configurada {1})' -f $m.Speed, $m.ConfiguredClockSpeed
            Fabricante = "$($m.Manufacturer)".Trim(); Modelo = "$($m.PartNumber)".Trim()
        }
    }
    $script:Gpus = foreach ($g in $gpus) {
        $drvData = $null; try { $drvData = $g.DriverDate } catch {}
        [pscustomobject]@{ Nome = $g.Name; Driver = $g.DriverVersion; DataDriver = $drvData; Resolucao = '{0}x{1}' -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution }
    }
    $script:Inv['Placa(s) de vídeo'] = ($gpus | ForEach-Object { $_.Name }) -join ' + '

    # RAM
    if ($totalGB -lt 7.5) {
        $script:Flags.PoucaRam = $true
        Add-Achado ATENCAO 'Memória RAM' ('Pouca memória RAM: {0:N1} GB' -f $totalGB) 'Windows 10/11 com menos de 8 GB fica lento e "travando" com navegador e programas abertos. Recomendado 8-16 GB.'
    }
    if ($mods.Count -eq 1 -and -not $script:EhNotebook) {
        Add-Achado INFO 'Memória RAM' 'Apenas 1 pente de memória (single channel)' 'Com 2 pentes iguais (dual channel) o desempenho melhora, principalmente em vídeo integrado.'
    }
    $tamanhos = @($mods | ForEach-Object { $_.Capacity } | Select-Object -Unique)
    $velocs = @($mods | ForEach-Object { $_.Speed } | Select-Object -Unique)
    if ($mods.Count -gt 1 -and ($tamanhos.Count -gt 1 -or $velocs.Count -gt 1)) {
        Add-Achado INFO 'Memória RAM' 'Pentes de memória diferentes entre si' 'Pentes de tamanhos/velocidades diferentes podem causar instabilidade em algumas placas. Se houver tela azul, teste um pente de cada vez.'
    }
    $usoRam = 100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
    if ($usoRam -ge 85) {
        Add-Achado ATENCAO 'Memória RAM' ('Uso de RAM muito alto em repouso: {0:N0}%' -f $usoRam) 'Muitos programas abertos ou em segundo plano. Causa lentidão e travamentos.'
    }

    # Vídeo
    foreach ($g in $gpus) {
        if ($g.Name -match 'Basic Display|Básico|Basico|Microsoft Basic') {
            Add-Achado ATENCAO 'Placa de vídeo' "Driver de vídeo não instalado ($($g.Name))" 'Instale o driver do fabricante (NVIDIA, AMD ou Intel).'
        } elseif ($g.DriverDate -and $g.DriverDate -lt (Get-Date).AddYears(-2)) {
            Add-Achado INFO 'Placa de vídeo' ('Driver de vídeo antigo: {0} ({1:dd/MM/yyyy})' -f $g.Name, $g.DriverDate) 'Atualizar o driver pode resolver travamentos e telas pretas.'
        }
    }

    # BIOS
    if ($biosData -and $biosData -lt (Get-Date).AddYears(-5)) {
        Add-Achado INFO 'Placa-mãe' ('BIOS de {0:yyyy}' -f $biosData) 'BIOS muito antiga. Se houver instabilidade, verifique atualização no site do fabricante.'
    }

    # Disco do sistema - espaço
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    if ($vol) {
        $livrePct = $vol.FreeSpace / $vol.Size * 100
        $script:Inv['Disco do sistema'] = '{0} {1:N0} GB livres de {2:N0} GB ({3:N0}%)' -f $env:SystemDrive, ($vol.FreeSpace / 1GB), ($vol.Size / 1GB), $livrePct
        if ($livrePct -lt 5 -or $vol.FreeSpace -lt 5GB) {
            $script:Flags.DiscoCheio = $true
            Add-Achado CRITICO 'Armazenamento' ('Disco {0} quase cheio: {1:N1} GB livres ({2:N0}%)' -f $env:SystemDrive, ($vol.FreeSpace / 1GB), $livrePct) 'Disco cheio causa travamentos, falhas de atualização e lentidão extrema.'
        } elseif ($livrePct -lt 15) {
            $script:Flags.DiscoCheio = $true
            Add-Achado ATENCAO 'Armazenamento' ('Pouco espaço livre em {0}: {1:N0}%' -f $env:SystemDrive, $livrePct) 'Mantenha pelo menos 15-20% livre.'
        }
    }

    # Dispositivos com erro
    try {
        $erros = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 -and $_.ConfigManagerErrorCode -ne 45 })
        if ($erros.Count) {
            $lista = ($erros | Select-Object -First 10 | ForEach-Object { '{0} (código {1})' -f $(if ($_.Name) { $_.Name } else { $_.DeviceID }), $_.ConfigManagerErrorCode }) -join '; '
            Add-Achado ATENCAO 'Drivers' ("{0} dispositivo(s) com erro no Gerenciador de Dispositivos" -f $erros.Count) "$lista. Código 28 = sem driver; 10/43 = falha ao iniciar/dispositivo com problema."
        } else {
            Add-Achado OK 'Drivers' 'Nenhum dispositivo com erro no Gerenciador de Dispositivos'
        }
    } catch {}

    # Plano de energia
    try {
        $pl = (powercfg /getactivescheme) -join ' '
        if ($pl -match '\((.+)\)') { $script:Inv['Plano de energia'] = $Matches[1] }
        if ($pl -match 'Economi|Power saver') {
            Add-Achado INFO 'Energia' 'Plano de energia em "Economia de energia"' 'Limita o desempenho do processador. Use "Equilibrado" ou "Alto desempenho".'
        }
    } catch {}

    # Bateria
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($bat.Count) {
        if ($bat[0].BatteryStatus -eq 1) {
            $script:Flags.NaBateria = $true
            Add-Achado ATENCAO 'Energia' 'O notebook está rodando NA BATERIA' 'Ligue o carregador: na bateria o processador é limitado e o resultado do teste de estresse fica distorcido.'
        }
        try {
            $xmlPath = Join-Path $env:TEMP 'diagpc_bateria.xml'
            powercfg /batteryreport /xml /output "$xmlPath" | Out-Null
            [xml]$x = Get-Content $xmlPath -Raw
            foreach ($b in $x.GetElementsByTagName('Battery')) {
                $design = Get-Num $b.DesignCapacity; $full = Get-Num $b.FullChargeCapacity
                if ($design -gt 0 -and $null -ne $full) {
                    $saude = $full / $design * 100
                    $txt = 'Capacidade original {0:N0} mWh, atual {1:N0} mWh, ciclos: {2}' -f $design, $full, $b.CycleCount
                    $script:Inv['Bateria'] = '{0:N0}% de saúde ({1})' -f $saude, $txt
                    if ($saude -lt 50) { Add-Achado CRITICO 'Bateria' ('Bateria muito desgastada: {0:N0}% da capacidade original' -f $saude) "$txt. Pode desligar sozinho fora da tomada. Troca recomendada." }
                    elseif ($saude -lt 75) { Add-Achado ATENCAO 'Bateria' ('Bateria desgastada: {0:N0}% da capacidade original' -f $saude) $txt }
                    else { Add-Achado OK 'Bateria' ('Bateria com {0:N0}% da capacidade original' -f $saude) $txt }
                }
            }
        } catch {}
    }
}

function Get-AnaliseEventos {
    Write-Etapa "Analisando logs do Windows (últimos $DiasLogs dias)"
    $desde = (Get-Date).AddDays(-$DiasLogs)

    # Desligamentos inesperados
    $kp = Get-Eventos 'System' 'Microsoft-Windows-Kernel-Power' @(41) $desde
    if ($kp.Count) {
        $semTela = @($kp | Where-Object { $v = 0; try { $v = [int64]$_.Properties[0].Value } catch {}; $v -eq 0 })
        $datas = ($kp | Select-Object -First 8 | ForEach-Object { $_.TimeCreated.ToString('dd/MM HH:mm') }) -join ', '
        $nivel = $(if ($kp.Count -ge 3) { 'CRITICO' } else { 'ATENCAO' })
        Add-Achado $nivel 'Desligamentos' ('{0} desligamento(s)/reinício(s) inesperado(s) nos últimos {1} dias' -f $kp.Count, $DiasLogs) `
            ('{0} sem tela azul (queda de energia, fonte, superaquecimento, ou alguém segurou o botão de ligar porque travou). Mais recentes: {1}' -f $semTela.Count, $datas)
        $script:Flags.Desligamentos = $kp.Count
        $script:Flags.DesligSemTela = $semTela.Count
        $kp | Select-Object -First 20 | ForEach-Object { Add-Evento $_ 'Desligamento inesperado' }
    } else {
        Add-Achado OK 'Desligamentos' "Nenhum desligamento inesperado registrado nos últimos $DiasLogs dias"
    }

    # Telas azuis
    $bsod = @()
    foreach ($prov in 'Microsoft-Windows-WER-SystemErrorReporting', 'BugCheck') {
        $bsod += Get-Eventos 'System' $prov @(1001) $desde
    }
    $codNomes = @{
        0x0A = 'IRQL_NOT_LESS_OR_EQUAL|driver ou RAM'; 0x19 = 'BAD_POOL_HEADER|driver ou RAM'
        0x1A = 'MEMORY_MANAGEMENT|RAM'; 0x1E = 'KMODE_EXCEPTION_NOT_HANDLED|driver'
        0x24 = 'NTFS_FILE_SYSTEM|disco'; 0x3B = 'SYSTEM_SERVICE_EXCEPTION|driver'
        0x4E = 'PFN_LIST_CORRUPT|RAM'; 0x50 = 'PAGE_FAULT_IN_NONPAGED_AREA|RAM ou driver'
        0x77 = 'KERNEL_STACK_INPAGE_ERROR|disco'; 0x7A = 'KERNEL_DATA_INPAGE_ERROR|disco'
        0x7E = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED|driver'; 0x9F = 'DRIVER_POWER_STATE_FAILURE|driver/energia'
        0xC2 = 'BAD_POOL_CALLER|driver'; 0xD1 = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL|driver'
        0xEF = 'CRITICAL_PROCESS_DIED|disco ou sistema'; 0xF4 = 'CRITICAL_OBJECT_TERMINATION|disco'
        0x101 = 'CLOCK_WATCHDOG_TIMEOUT|processador/overclock'; 0x116 = 'VIDEO_TDR_FAILURE|placa de vídeo'
        0x117 = 'VIDEO_TDR_TIMEOUT_DETECTED|placa de vídeo'; 0x119 = 'VIDEO_SCHEDULER_INTERNAL_ERROR|placa de vídeo'
        0x124 = 'WHEA_UNCORRECTABLE_ERROR|hardware (CPU, RAM, tensão, overclock)'; 0x133 = 'DPC_WATCHDOG_VIOLATION|driver ou firmware do SSD'
        0x139 = 'KERNEL_SECURITY_CHECK_FAILURE|driver ou RAM'; 0x13A = 'KERNEL_MODE_HEAP_CORRUPTION|driver'
        0x1E0 = 'VIDEO_TDR|placa de vídeo'; 0xA0 = 'INTERNAL_POWER_ERROR|energia'
    }
    $codigos = @{}
    foreach ($e in $bsod) {
        $txt = "$($e.Message) " + (($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ')
        $m = [regex]::Match($txt, '0x[0-9a-fA-F]{8}')
        if ($m.Success) {
            $cod = [Convert]::ToInt64($m.Value, 16)
            if (-not $codigos.ContainsKey($cod)) { $codigos[$cod] = 0 }
            $codigos[$cod]++
        }
        Add-Evento $e 'Tela azul (BSOD)'
    }
    $dumps = @(Get-ChildItem "$env:WINDIR\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue)
    if ($bsod.Count -or $dumps.Count) {
        $partes = foreach ($k in $codigos.Keys) {
            $nm = $codNomes[[int]$k]
            $cat = ''
            if ($nm) { $nmP = $nm -split '\|'; $cat = $nmP[1]; $nm = $nmP[0] } else { $nm = 'código não catalogado' }
            if ($cat -match 'RAM') { $script:Flags.BsodRam = $true }
            if ($cat -match 'disco') { $script:Flags.BsodDisco = $true }
            if ($cat -match 'vídeo') { $script:Flags.BsodGpu = $true }
            if ($cat -match 'hardware|processador') { $script:Flags.BsodHw = $true }
            '0x{0:X} {1} ({2}x){3}' -f $k, $nm, $codigos[$k], $(if ($cat) { " -> suspeita: $cat" } else { '' })
        }
        $det = ($partes -join '; ')
        if ($dumps.Count) { $det += ('{0}{1} arquivo(s) de minidump em C:\Windows\Minidump (mais recente {2:dd/MM/yyyy HH:mm}) - analise com WinDbg ou BlueScreenView.' -f $(if ($det) { '. ' } else { '' }), $dumps.Count, ($dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime) }
        $n = [Math]::Max($bsod.Count, $dumps.Count)
        Add-Achado $(if ($n -ge 2) { 'CRITICO' } else { 'ATENCAO' }) 'Tela azul' ('{0} tela(s) azul(is) registrada(s)' -f $n) $det
        $script:Flags.Bsod = $n
    } else {
        Add-Achado OK 'Tela azul' "Nenhuma tela azul registrada nos últimos $DiasLogs dias"
    }

    # WHEA
    $whea = Get-Eventos 'System' 'Microsoft-Windows-WHEA-Logger' $null $desde
    if ($whea.Count) {
        $fatais = @($whea | Where-Object { $_.Level -le 2 })
        $corr = $whea.Count - $fatais.Count
        $ex = ''
        try { $ex = (($whea | Select-Object -First 1).Message -split "`r?`n" | Where-Object { $_ -match 'Component|Componente|Error Source|Origem|Tipo' } | Select-Object -First 3) -join ' / ' } catch {}
        $script:Flags.Whea = $whea.Count
        if ($fatais.Count) {
            $script:Flags.WheaFatal = $true
            Add-Achado CRITICO 'Erro de hardware (WHEA)' ('{0} erro(s) FATAL(is) de hardware e {1} corrigido(s)' -f $fatais.Count, $corr) "O próprio processador/placa reportou erro de hardware. $ex Causas comuns: overclock/XMP, tensão instável, CPU, RAM, placa-mãe ou fonte."
        } elseif ($corr -ge 5) {
            Add-Achado ATENCAO 'Erro de hardware (WHEA)' ('{0} erro(s) de hardware corrigido(s)' -f $corr) "O hardware corrigiu sozinho, mas não deveria acontecer com frequência. $ex Geralmente PCIe (placa de vídeo/SSD NVMe mal encaixado, slot, energia) ou memória."
        } else {
            Add-Achado INFO 'Erro de hardware (WHEA)' ('{0} erro(s) de hardware corrigido(s)' -f $corr) $ex
        }
        $whea | Select-Object -First 15 | ForEach-Object { Add-Evento $_ 'Erro de hardware WHEA' }
    } else {
        Add-Achado OK 'Erro de hardware (WHEA)' 'Nenhum erro de hardware WHEA registrado'
    }

    # Erros de disco
    $graves = @(); $leves = @()
    $graves += Get-Eventos 'System' 'disk' @(7, 51) $desde
    $graves += Get-Eventos 'System' 'Ntfs' @(55) $desde
    $leves += Get-Eventos 'System' 'disk' @(11, 153) $desde
    foreach ($pv in 'storahci', 'stornvme', 'iaStorA', 'iaStorAC', 'iaStorAVC', 'storport') { $leves += Get-Eventos 'System' $pv @(11, 129) $desde }
    if ($graves.Count) {
        $script:Flags.DiscoErros = $true
        $dev = (($graves | ForEach-Object { if ($_.Message -match '(Harddisk\d+)') { $Matches[1] } }) | Select-Object -Unique) -join ', '
        Add-Achado CRITICO 'Erros de disco' ('{0} erro(s) grave(s) de disco (blocos defeituosos / erro de paginação / sistema de arquivos corrompido)' -f $graves.Count) "Dispositivo(s): $dev (Harddisk0 normalmente é o disco do Windows; pendrives/HDs externos também aparecem aqui). Faça backup."
        $graves | Select-Object -First 15 | ForEach-Object { Add-Evento $_ 'Erro de disco' }
    }
    if ($leves.Count) {
        $script:Flags.DiscoAvisos = $leves.Count
        Add-Achado $(if ($leves.Count -ge 10) { 'CRITICO' } else { 'ATENCAO' }) 'Erros de disco' ('{0} aviso(s) de disco (tentativas de leitura repetidas / reset do controlador)' -f $leves.Count) 'Típico de travamentos de alguns segundos. Verifique cabo SATA, porta, firmware do SSD e saúde do disco.'
        $leves | Select-Object -First 15 | ForEach-Object { Add-Evento $_ 'Aviso de disco' }
    }
    if (-not $graves.Count -and -not $leves.Count) { Add-Achado OK 'Erros de disco' 'Nenhum erro de disco nos logs' }

    # Driver de vídeo
    $tdr = Get-Eventos 'System' 'Display' @(4101) $desde
    $nv = @(); foreach ($pv in 'nvlddmkm', 'amdkmdag', 'amdkmdap', 'igfx', 'igfxn') { $nv += @(Get-Eventos 'System' $pv $null $desde | Where-Object { $_.Level -le 2 }) }
    $totalTdr = $tdr.Count + $nv.Count
    if ($totalTdr) {
        $script:Flags.Tdr = $totalTdr
        Add-Achado $(if ($totalTdr -ge 5) { 'CRITICO' } else { 'ATENCAO' }) 'Placa de vídeo' ('Driver de vídeo parou de responder/reiniciou {0} vez(es)' -f $totalTdr) 'Tela preta/piscando ou travamento em jogos. Causas: driver, superaquecimento da GPU, GPU com defeito, overclock ou fonte fraca.'
        @($tdr) + @($nv) | Select-Object -First 15 | ForEach-Object { Add-Evento $_ 'Driver de vídeo' }
    } else {
        Add-Achado OK 'Placa de vídeo' 'Nenhum travamento do driver de vídeo registrado'
    }

    # Limitação térmica pelo firmware
    $thr = Get-Eventos 'System' 'Microsoft-Windows-Kernel-Processor-Power' @(37) $desde
    if ($thr.Count -ge 10) {
        $script:Flags.ThrottleLog = $true
        Add-Achado ATENCAO 'Temperatura' ('Firmware limitou a velocidade do processador {0} vezes' -f $thr.Count) 'Geralmente por temperatura alta (poeira, pasta térmica, cooler) ou limite de energia.'
        $thr | Select-Object -First 5 | ForEach-Object { Add-Evento $_ 'Processador limitado' }
    } elseif ($thr.Count) {
        Add-Achado INFO 'Temperatura' ('Firmware limitou a velocidade do processador {0} vez(es)' -f $thr.Count) ''
    }

    # Programas travando / fechando
    $hang = Get-Eventos 'Application' 'Application Hang' @(1002) $desde
    $crash = Get-Eventos 'Application' 'Application Error' @(1000) $desde
    $resumoApps = {
        param($evs)
        ($evs | ForEach-Object { try { "$($_.Properties[0].Value)" } catch { '?' } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { '{0} ({1}x)' -f $_.Name, $_.Count }) -join ', '
    }
    if ($hang.Count) {
        $script:Flags.AppHangs = $hang.Count
        Add-Achado $(if ($hang.Count -ge 15) { 'ATENCAO' } else { 'INFO' }) 'Travamentos' ('{0} programa(s) "não respondendo" registrados' -f $hang.Count) ('Mais frequentes: ' + (& $resumoApps $hang))
    }
    if ($crash.Count) {
        Add-Achado $(if ($crash.Count -ge 30) { 'ATENCAO' } else { 'INFO' }) 'Travamentos' ('{0} programa(s) fecharam com erro' -f $crash.Count) ('Mais frequentes: ' + (& $resumoApps $crash))
    }

    # Resultado do Diagnóstico de Memória do Windows
    $md = Get-Eventos 'System' 'Microsoft-Windows-MemoryDiagnostics-Results' $null (Get-Date).AddDays(-365)
    if ($md.Count) {
        $ult = $md | Sort-Object TimeCreated -Descending | Select-Object -First 1
        if ($ult.Id -eq 1202) {
            $script:Flags.RamErros = $true
            Add-Achado CRITICO 'Memória RAM' ('Diagnóstico de Memória do Windows encontrou ERROS ({0:dd/MM/yyyy})' -f $ult.TimeCreated) 'Teste cada pente separadamente para achar o defeituoso.'
        } elseif ($ult.Id -eq 1201) {
            Add-Achado INFO 'Memória RAM' ('Diagnóstico de Memória do Windows sem erros ({0:dd/MM/yyyy})' -f $ult.TimeCreated) ''
        }
    }
}

function Get-Smartctl {
    foreach ($c in @((Join-Path $ToolsDir 'smartctl.exe'), "$env:ProgramFiles\smartmontools\bin\smartctl.exe")) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command smartctl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    try {
        Write-Host '   Baixando smartctl (smartmontools)...' -ForegroundColor Gray
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $dest = Join-Path $ToolsDir 'smartctl.exe'
        Invoke-WebRequest -Uri "$RepoRaw/ferramentas/smartctl.exe" -OutFile $dest -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop
        Unblock-File $dest -ErrorAction SilentlyContinue
        return $dest
    } catch {
        Write-Host "   smartctl indisponível ($($_.Exception.Message)). Saúde % só para discos NVMe." -ForegroundColor Yellow
        return $null
    }
}

function Write-SmartLog([string]$t) {
    try { Add-Content -Path (Join-Path $PastaRel 'smart_log.txt') -Value ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $t) -Encoding UTF8 } catch {}
}

function ConvertFrom-JsonSeguro([string]$txt) {
    if (-not $txt) { return $null }
    try { return ($txt | ConvertFrom-Json -ErrorAction Stop) }
    catch {
        Write-SmartLog "ConvertFrom-Json falhou ($($_.Exception.Message)); usando JavaScriptSerializer"
        try {
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
            $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $js.MaxJsonLength = 67108864
            return $js.DeserializeObject($txt)
        } catch { Write-SmartLog "JavaScriptSerializer falhou: $($_.Exception.Message)"; return $null }
    }
}

function Get-SerialNorm([string]$s) { return ($s -replace '[^0-9A-Za-z]', '').ToUpperInvariant() }

function Get-SmartAttr($j, [int]$id) {
    foreach ($a in @($j.ata_smart_attributes.table)) { if ($a.id -eq $id) { return $a } }
    return $null
}

# Calcula a saúde em % (estilo HD Sentinel) a partir do JSON do smartctl
function Get-SaudePct($j) {
    $motivos = New-Object System.Collections.Generic.List[string]
    $saude = 100.0
    $ehNvme = ("$($j.device.protocol)" -eq 'NVMe') -or ($null -ne $j.nvme_smart_health_information_log)
    $ehSsd = $ehNvme -or ($j.rotation_rate -eq 0)

    if ($ehNvme) {
        $n = $j.nvme_smart_health_information_log
        if ($n) {
            if ($null -ne $n.percentage_used) {
                $saude = 100 - [Math]::Min(100, [double]$n.percentage_used)
                if ($n.percentage_used -gt 0) { $motivos.Add("desgaste $($n.percentage_used)%") }
            }
            if ($null -ne $n.available_spare -and $n.available_spare -lt 100) {
                $saude = [Math]::Min($saude, [double]$n.available_spare)
                $motivos.Add("área reserva $($n.available_spare)%")
            }
            if ($n.media_errors -gt 0) {
                $saude -= 5 + [Math]::Min(45, [double]$n.media_errors)
                $motivos.Add("$($n.media_errors) erro(s) de mídia")
            }
            $cw = [int]$n.critical_warning
            if ($cw -band 1) { $saude = [Math]::Min($saude, 10); $motivos.Add('reserva abaixo do limite') }
            if ($cw -band 4) { $saude = [Math]::Min($saude, 20); $motivos.Add('confiabilidade degradada') }
            if ($cw -band 8) { $saude = [Math]::Min($saude, 1); $motivos.Add('SSD em modo somente leitura') }
        }
    } else {
        if ($ehSsd) {
            # 1) estatística padrão "Percentage Used Endurance Indicator"
            $usado = $null
            foreach ($pg in @($j.ata_device_statistics.pages)) {
                foreach ($e in @($pg.table)) { if ($e.name -match 'Percentage Used Endurance') { $usado = [double]$e.value } }
            }
            if ($null -ne $usado) {
                $saude = 100 - [Math]::Min(100, $usado)
                if ($usado -gt 0) { $motivos.Add("desgaste $usado%") }
            } else {
                # 2) atributo de vida útil do fabricante (valor normalizado = % restante)
                foreach ($id in 231, 202, 169, 233, 177, 248, 173) {
                    $a = Get-SmartAttr $j $id
                    if ($a -and "$($a.name)" -match 'Life|Wear|Endurance|Remain' -and $a.value -ge 0 -and $a.value -le 100) {
                        $saude = [double]$a.value
                        if ($a.value -lt 100) { $motivos.Add("vida útil restante $($a.value)% (atributo $id)") }
                        break
                    }
                }
            }
        }
        # setores defeituosos e erros (HD e SSD SATA)
        $raw = { param($id) $a = Get-SmartAttr $j $id; if ($a) { [double]$a.raw.value } else { 0 } }
        $r5 = & $raw 5; $r197 = & $raw 197; $r198 = & $raw 198; $r187 = & $raw 187; $r10 = & $raw 10
        $pen = [Math]::Min(200, $r5) * 0.5 + [Math]::Min(100, $r197) * 2 + [Math]::Min(100, $r198) * 2 + [Math]::Min(100, $r187) * 1
        if ($r10 -gt 0 -and -not $ehSsd) { $pen += 10; $motivos.Add("$r10 falha(s) de rotação do motor") }
        if ($r5 -gt 0) { $motivos.Add("$r5 setor(es) realocado(s)") }
        if ($r197 -gt 0) { $motivos.Add("$r197 setor(es) pendente(s)") }
        if ($r198 -gt 0) { $motivos.Add("$r198 setor(es) incorrigível(is)") }
        if ($r187 -gt 0) { $motivos.Add("$r187 erro(s) não corrigido(s) reportado(s)") }
        if ($pen -gt 0 -and $pen -lt 3) { $pen = 3 }
        $saude -= $pen
        foreach ($a in @($j.ata_smart_attributes.table)) {
            if ("$($a.when_failed)" -eq 'now') { $saude = [Math]::Min($saude, 5); $motivos.Add("atributo $($a.id) $($a.name) abaixo do limite do fabricante") }
        }
    }
    if ($j.smart_status -and $j.smart_status.passed -eq $false) { $saude = [Math]::Min($saude, 1); $motivos.Add('SMART reprovado') }
    $saude = [int][Math]::Round([Math]::Max(0, [Math]::Min(100, $saude)))
    return [pscustomobject]@{ Pct = $saude; Motivos = ($motivos -join ', '); Ssd = $ehSsd }
}

function Get-RotuloSaude([int]$p) {
    if ($p -ge 90) { return 'Excelente' }
    if ($p -ge 80) { return 'Boa' }
    if ($p -ge 50) { return 'Atenção' }
    return 'Ruim'
}

function Get-SaudeArmazenamento {
    Write-Etapa 'Verificando saúde dos discos (SMART)'
    $sysDisk = $null
    try { $sysDisk = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop).DiskNumber } catch {}
    $pds = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    foreach ($d in $pds) {
        $rc = $null
        try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $nome = "$($d.FriendlyName)".Trim()
        $ehSistema = ("$($d.DeviceId)" -eq "$sysDisk")
        $row = [pscustomobject]@{
            Disco = $nome + $(if ($ehSistema) { ' (Windows)' } else { '' })
            Nome = $nome; Serial = (Get-SerialNorm "$($d.SerialNumber)")
            Tipo = "$($d.MediaType)"; Barramento = "$($d.BusType)"
            Tamanho = '{0:N0} GB' -f ($d.Size / 1GB)
            SaudePct = $null; SaudeRotulo = '--'; SaudeMotivo = ''
            Saude = "$($d.HealthStatus)"; Status = ($d.OperationalStatus -join ', ')
            Temperatura = $(if ($rc -and $rc.Temperature) { "$($rc.Temperature) °C" } else { '--' })
            Desgaste = $(if ($rc -and $null -ne $rc.Wear) { "$($rc.Wear)%" } else { '--' })
            ErrosNaoCorrigidos = $(if ($rc) { [int64]$rc.ReadErrorsUncorrected + [int64]$rc.WriteErrorsUncorrected } else { '--' })
            HorasLigado = $(if ($rc -and $rc.PowerOnHours) { $rc.PowerOnHours } else { '--' })
            WearWin = $(if ($rc) { $rc.Wear } else { $null })
        }
        $script:Discos.Add($row)
        if ("$($d.HealthStatus)" -eq 'Unhealthy') {
            $script:Flags.SmartRuim = $true
            Add-Achado CRITICO 'Saúde do disco' "Disco $nome com status do Windows RUIM (Unhealthy)" 'O disco está falhando. Faça backup imediatamente e substitua.'
        } elseif ("$($d.HealthStatus)" -eq 'Warning') {
            $script:Flags.SmartRuim = $true
            Add-Achado CRITICO 'Saúde do disco' "Disco $nome com ALERTA do Windows (Warning)" "Status: $($row.Status). Faça backup e planeje a troca."
        }
        if ($rc) {
            if ($rc.Temperature -ge $LIM.DiscoCritico) { Add-Achado CRITICO 'Temperatura' "Disco $nome muito quente em repouso: $($rc.Temperature) °C" 'SSD NVMe sem dissipador/ventilação ou HD com problema.' }
            elseif ($rc.Temperature -ge $LIM.DiscoAtencao) { Add-Achado ATENCAO 'Temperatura' "Disco $nome quente: $($rc.Temperature) °C" '' }
        }
        if ($ehSistema -and "$($d.MediaType)" -eq 'HDD') {
            $script:Flags.HddSistema = $true
            Add-Achado ATENCAO 'Desempenho' "Windows instalado em HD mecânico ($nome)" 'Causa número 1 de lentidão e "travadinhas" no Windows 10/11. Troca por SSD resolve.'
        }
    }
    try {
        $fp = @(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure })
        foreach ($f in $fp) { $script:Flags.SmartRuim = $true; Add-Achado CRITICO 'Saúde do disco' 'SMART prevê FALHA iminente de um disco' "$($f.InstanceName). Faça backup imediatamente." }
    } catch {}

    # smartctl: atributos completos + saúde em %
    foreach ($r in $script:Discos) { Write-SmartLog ("Windows: {0} | tipo {1} | barramento {2} | serial {3} | status {4} | desgaste {5}" -f $r.Nome, $r.Tipo, $r.Barramento, $r.Serial, $r.Saude, $r.Desgaste) }
    $lidosSmart = 0
    $sc = Get-Smartctl
    Write-SmartLog "smartctl: $(if ($sc) { $sc } else { 'indisponível' })"
    if ($sc) {
        $scanTxt = ''
        try { $scanTxt = (& $sc --scan-open -j 2>&1 | ForEach-Object { "$_" }) -join "`n" } catch { Write-SmartLog "scan falhou: $($_.Exception.Message)" }
        Write-SmartLog "scan (código $LASTEXITCODE): $scanTxt"
        $scan = ConvertFrom-JsonSeguro $scanTxt
        foreach ($dev in @($scan.devices)) {
            if (-not $dev) { continue }
            try {
                $argsSc = @('-a', '-j', '-d', "$($dev.type)", "$($dev.name)")
                if ("$($dev.type)" -notmatch 'nvme') { $argsSc = @('-a', '-l', 'devstat', '-j', '-d', "$($dev.type)", "$($dev.name)") }
                $txt = (& $sc @argsSc 2>$null | ForEach-Object { "$_" }) -join "`n"
                Write-SmartLog ("{0} ({1}) código {2}, {3} caracteres" -f $dev.name, $dev.type, $LASTEXITCODE, $txt.Length)
                $j = ConvertFrom-JsonSeguro $txt
                if (-not $j -or (-not $j.ata_smart_attributes -and -not $j.nvme_smart_health_information_log)) {
                    $msgs = ''
                    try { $msgs = (@($j.smartctl.messages) | ForEach-Object { $_.string }) -join ' / ' } catch {}
                    Write-SmartLog "  sem dados SMART. $msgs"
                    continue
                }
                $nm = "$($j.model_name)".Trim()
                if (-not $nm) { $nm = "$($dev.name)" }

                # associa ao disco do Windows pelo número de série (ou modelo)
                $ser = Get-SerialNorm "$($j.serial_number)"
                $row = $script:Discos | Where-Object { $ser -and $_.Serial -and ($_.Serial -eq $ser -or $_.Serial.Contains($ser) -or $ser.Contains($_.Serial)) } | Select-Object -First 1
                if (-not $row) { $row = $script:Discos | Where-Object { $null -eq $_.SaudePct -and $nm -and ($_.Nome -like "*$nm*" -or $nm -like "*$($_.Nome)*") } | Select-Object -First 1 }
                if (-not $row) {
                    $row = [pscustomobject]@{
                        Disco = $nm; Nome = $nm; Serial = $ser; Tipo = ''; Barramento = "$($dev.type)"
                        Tamanho = $(if ($j.user_capacity.bytes) { '{0:N0} GB' -f ($j.user_capacity.bytes / 1GB) } else { '--' })
                        SaudePct = $null; SaudeRotulo = '--'; SaudeMotivo = ''; Saude = '--'; Status = ''
                        Temperatura = '--'; Desgaste = '--'; ErrosNaoCorrigidos = '--'; HorasLigado = '--'; WearWin = $null
                    }
                    $script:Discos.Add($row)
                }
                $h = Get-SaudePct $j
                $lidosSmart++
                Write-SmartLog "  $nm (serial $ser): saúde $($h.Pct)% - $($h.Motivos)"
                $row.SaudePct = $h.Pct; $row.SaudeRotulo = Get-RotuloSaude $h.Pct; $row.SaudeMotivo = $h.Motivos
                if ($row.Tipo -in '', 'Unspecified') { $row.Tipo = $(if ($h.Ssd) { 'SSD' } else { 'HDD' }) }
                if ($row.Temperatura -eq '--' -and $j.temperature.current) { $row.Temperatura = "$($j.temperature.current) °C" }
                if ($row.HorasLigado -eq '--' -and $j.power_on_time.hours) { $row.HorasLigado = $j.power_on_time.hours }

                foreach ($at in @($j.ata_smart_attributes.table)) {
                    if (-not $at) { continue }
                    $rv = [int64]$at.raw.value
                    switch ([int]$at.id) {
                        5 { if ($rv -gt 0) { $script:Flags.SmartRuim = $true; Add-Achado $(if ($rv -gt 50) { 'CRITICO' } else { 'ATENCAO' }) 'Saúde do disco' "$nm - $rv setor(es) realocado(s)" 'Setores defeituosos já substituídos. Se aumentar, o disco está morrendo.' } }
                        197 { if ($rv -gt 0) { $script:Flags.SmartRuim = $true; Add-Achado CRITICO 'Saúde do disco' "$nm - $rv setor(es) pendente(s)" 'Setores instáveis/ilegíveis: causa travamentos longos.' } }
                        198 { if ($rv -gt 0) { $script:Flags.SmartRuim = $true; Add-Achado CRITICO 'Saúde do disco' "$nm - $rv setor(es) incorrigível(is)" '' } }
                        199 { if ($rv -gt 0) { Add-Achado ATENCAO 'Saúde do disco' "$nm - $rv erro(s) de comunicação (CRC)" 'Troque o cabo SATA ou a porta. Não reduz a saúde do disco.' } }
                    }
                }
            } catch { Write-SmartLog "  erro em $($dev.name): $($_.Exception.Message)" }
        }
    }

    # LibreHardwareMonitor: segunda fonte (NVMe "Percentage Used", SATA "Remaining Life")
    if ($script:LHM) {
        try {
            foreach ($hw in $script:LHM.Hardware) {
                if ($hw.HardwareType.ToString() -ne 'Storage') { continue }
                $hw.Update()
                $nmL = "$($hw.Name)".Trim()
                $row = $script:Discos | Where-Object { $_.Nome -like "*$nmL*" -or $nmL -like "*$($_.Nome)*" } | Select-Object -First 1
                $sens = @($hw.Sensors)
                Write-SmartLog ("LHM: {0} -> {1}" -f $nmL, (($sens | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '; '))
                if (-not $row) { continue }
                $tmp = $sens | Where-Object { $_.SensorType.ToString() -eq 'Temperature' -and $_.Value -gt 0 } | Select-Object -First 1
                if ($row.Temperatura -eq '--' -and $tmp) { $row.Temperatura = '{0:N0} °C' -f $tmp.Value }
                if ($null -ne $row.SaudePct) { continue }
                $usado = $sens | Where-Object { $_.Name -eq 'Percentage Used' -and $null -ne $_.Value } | Select-Object -First 1
                $resta = $sens | Where-Object { $_.Name -eq 'Remaining Life' -and $null -ne $_.Value } | Select-Object -First 1
                $spare = $sens | Where-Object { $_.Name -eq 'Available Spare' -and $null -ne $_.Value } | Select-Object -First 1
                $p = $null; $mot = @()
                if ($usado) { $p = 100 - [Math]::Min(100, [double]$usado.Value); if ($usado.Value -gt 0) { $mot += ('desgaste {0:N0}%' -f $usado.Value) } }
                elseif ($resta) { $p = [Math]::Min(100, [double]$resta.Value); if ($p -lt 100) { $mot += ('vida útil restante {0:N0}%' -f $resta.Value) } }
                if ($null -ne $p -and $spare -and $spare.Value -lt 100) { $p = [Math]::Min($p, [double]$spare.Value); $mot += ('área reserva {0:N0}%' -f $spare.Value) }
                if ($null -ne $p) {
                    $p = [int][Math]::Round([Math]::Max(0, $p))
                    $row.SaudePct = $p; $row.SaudeRotulo = Get-RotuloSaude $p
                    $row.SaudeMotivo = (@($mot) + 'fonte: LibreHardwareMonitor') -join ', '
                    $lidosSmart++
                }
            }
        } catch { Write-SmartLog "LHM storage erro: $($_.Exception.Message)" }
    }

    # sem smartctl: usa o desgaste informado pelo Windows (normalmente só NVMe)
    foreach ($row in $script:Discos) {
        if ($null -eq $row.SaudePct -and $null -ne $row.WearWin) {
            $p = 100 - [Math]::Min(100, [int]$row.WearWin)
            if ($row.ErrosNaoCorrigidos -is [int64] -and $row.ErrosNaoCorrigidos -gt 0) { $p = [Math]::Max(0, $p - 5 - [Math]::Min(45, $row.ErrosNaoCorrigidos)) }
            $row.SaudePct = $p; $row.SaudeRotulo = Get-RotuloSaude $p
            $row.SaudeMotivo = $(if ($row.WearWin -gt 0) { "desgaste $($row.WearWin)% (Windows)" } else { '' })
        }
    }

    $semDados = @($script:Discos | Where-Object { $null -eq $_.SaudePct })
    if ($semDados.Count) {
        $raid = @($semDados | Where-Object { $_.Barramento -match 'RAID' })
        $det = 'Veja smart_log.txt na pasta do relatório.'
        if ($raid.Count) { $det = 'O disco está atrás de uma controladora Intel RST/VMD (modo RAID), que bloqueia a leitura do SMART. Programas como CrystalDiskInfo também costumam não ler nesse caso. ' + $det }
        Add-Achado INFO 'Saúde do disco' ('Saúde em % indisponível para: {0}' -f (($semDados | ForEach-Object { $_.Nome }) -join ', ')) $det
    }

    # resultado por disco
    foreach ($row in $script:Discos) {
        if ($null -eq $row.SaudePct) { continue }
        $tit = 'Disco {0}: saúde {1}% ({2})' -f $row.Nome, $row.SaudePct, $row.SaudeRotulo
        $det = $(if ($row.SaudeMotivo) { "Motivo: $($row.SaudeMotivo)." } else { 'Nenhum desgaste ou defeito registrado.' })
        if ($row.SaudePct -lt 50) {
            $script:Flags.SmartRuim = $true
            Add-Achado CRITICO 'Saúde do disco' $tit "$det Faça backup imediatamente e substitua o disco."
        } elseif ($row.SaudePct -lt 80) {
            Add-Achado ATENCAO 'Saúde do disco' $tit "$det Acompanhe e planeje a troca."
        } else {
            Add-Achado OK 'Saúde do disco' $tit $det
        }
    }
}

# ---------------------------------------------------------------------------
#  Avaliação das etapas
# ---------------------------------------------------------------------------
function Test-TempCpu($max, [string]$contexto) {
    if ($null -eq $max) { return }
    $obsNb = $(if ($script:EhNotebook) { ' Em notebooks é comum chegar perto disso, mas indica refrigeração no limite.' } else { '' })
    if ($max -ge $LIM.CpuCritico) {
        $script:Flags.CpuQuente = $true
        Add-Achado CRITICO 'Temperatura' ('Processador SUPERAQUECENDO: {0:N0} °C {1}' -f $max, $contexto) "Limite típico 95-105 °C: o processador reduz a velocidade e pode desligar o PC. Limpeza, troca de pasta térmica e verificação do cooler.$obsNb"
    } elseif ($max -ge $LIM.CpuAtencao) {
        $script:Flags.CpuMorno = $true
        Add-Achado ATENCAO 'Temperatura' ('Processador quente: {0:N0} °C {1}' -f $max, $contexto) "Recomenda-se limpeza e troca da pasta térmica.$obsNb"
    } else {
        Add-Achado OK 'Temperatura' ('Processador: máximo de {0:N0} °C {1}' -f $max, $contexto)
    }
}

function Test-TempGpu($st, [string]$contexto) {
    if ($null -ne $st.GpuTempMax) {
        if ($st.GpuTempMax -ge $LIM.GpuCritico) {
            $script:Flags.GpuQuente = $true
            Add-Achado CRITICO 'Temperatura' ('Placa de vídeo SUPERAQUECENDO: {0:N0} °C {1}' -f $st.GpuTempMax, $contexto) 'Limpeza, verificação das ventoinhas da placa e troca de pasta/thermal pads.'
        } elseif ($st.GpuTempMax -ge $LIM.GpuAtencao) {
            $script:Flags.GpuMorno = $true
            Add-Achado ATENCAO 'Temperatura' ('Placa de vídeo quente: {0:N0} °C {1}' -f $st.GpuTempMax, $contexto) 'Verifique poeira e ventoinhas.'
        } else {
            Add-Achado OK 'Temperatura' ('Placa de vídeo: máximo de {0:N0} °C {1}' -f $st.GpuTempMax, $contexto)
        }
    }
    if ($null -ne $st.GpuHotspotMax) {
        if ($st.GpuHotspotMax -ge $LIM.HotspotCritico) { $script:Flags.GpuQuente = $true; Add-Achado CRITICO 'Temperatura' ('Hot spot da GPU em {0:N0} °C {1}' -f $st.GpuHotspotMax, $contexto) 'Pasta térmica da GPU ressecada ou mal aplicada.' }
        elseif ($st.GpuHotspotMax -ge $LIM.HotspotAtencao) { Add-Achado ATENCAO 'Temperatura' ('Hot spot da GPU em {0:N0} °C {1}' -f $st.GpuHotspotMax, $contexto) '' }
        elseif ($null -ne $st.GpuTempMax -and ($st.GpuHotspotMax - $st.GpuTempMax) -ge 25) { Add-Achado ATENCAO 'Temperatura' ('Diferença grande entre núcleo e hot spot da GPU: {0:N0} °C' -f ($st.GpuHotspotMax - $st.GpuTempMax)) 'Sinal clássico de pasta térmica ruim na placa de vídeo.' }
    }
}

function Test-Throttling([string]$fase) {
    $a = @($script:Amostras | Where-Object { $_.Fase -eq $fase -and $_.CpuLoad -ge 85 -and $null -ne $_.CpuPerf })
    if ($a.Count -lt 12) { return }
    $ini = ($a | Select-Object -First 5 | Measure-Object CpuPerf -Average).Average
    $fim = ($a | Select-Object -Last ([int]($a.Count / 2)) | Measure-Object CpuPerf -Average).Average
    if ($ini -gt 0) {
        $queda = ($ini - $fim) / $ini * 100
        if ($queda -ge 20) {
            $script:Flags.Throttle = $true
            Add-Achado ATENCAO 'Desempenho' ('Processador perdeu {0:N0}% da velocidade durante a carga ({1:N0}% -> {2:N0}% da nominal)' -f $queda, $ini, $fim) 'Thermal throttling (aquecimento) ou limite de energia (fonte/carregador/VRM).'
        }
    }
    if ($fim -lt 50 -and -not $script:Flags.NaBateria) {
        $script:Flags.Throttle = $true
        Add-Achado ATENCAO 'Desempenho' ('Processador rodando a {0:N0}% da velocidade nominal sob carga máxima' -f $fim) 'Muito abaixo do normal: superaquecimento, plano de energia, carregador de notebook errado/fraco ou BIOS limitando.'
    }
}

function Test-EventosDuranteTeste {
    if (-not $script:InicioTestes) { return }
    $d = $script:InicioTestes
    $whea = Get-Eventos 'System' 'Microsoft-Windows-WHEA-Logger' $null $d
    if ($whea.Count) { $script:Flags.WheaFatal = $true; Add-Achado CRITICO 'Erro de hardware (WHEA)' ('{0} erro(s) de hardware aconteceram DURANTE o teste' -f $whea.Count) 'Hardware instável sob carga.' }
    $tdr = Get-Eventos 'System' 'Display' @(4101) $d
    if ($tdr.Count) { $script:Flags.Tdr = 1 + [int]$script:Flags.Tdr; Add-Achado CRITICO 'Placa de vídeo' ('O driver de vídeo travou/reiniciou {0} vez(es) DURANTE o teste' -f $tdr.Count) 'Placa de vídeo instável sob carga (temperatura, defeito, driver ou fonte).' }
    $dk = @(); $dk += Get-Eventos 'System' 'disk' @(7, 51, 153) $d
    foreach ($pv in 'storahci', 'stornvme') { $dk += Get-Eventos 'System' $pv @(129) $d }
    if ($dk.Count) { $script:Flags.DiscoErros = $true; Add-Achado CRITICO 'Erros de disco' ('{0} erro(s) de disco DURANTE o teste' -f $dk.Count) '' }
    @($whea) + @($tdr) + @($dk) | Where-Object { $_ } | ForEach-Object { Add-Evento $_ 'Durante o teste' }
}

# ---------------------------------------------------------------------------
#  Conclusões
# ---------------------------------------------------------------------------
function Get-Conclusoes {
    $F = $script:Flags
    $C = $script:Conclusoes
    $quente = $F.CpuQuente -or $F.GpuQuente
    if ($F.DesligouNoTeste) {
        if ($F.QuenteAoDesligar) { $C.Add("O PC desligou durante o teste anterior com temperatura alta ($(Fmt $F.TempAoDesligar '°C')): SUPERAQUECIMENTO é a causa mais provável. Limpeza completa, pasta térmica nova e conferir coolers.") }
        else { $C.Add('O PC desligou durante o teste anterior SEM temperatura alta: forte suspeita de FONTE (fraca, defeituosa ou genérica), alimentação (tomada/estabilizador/filtro) ou placa-mãe/VRM.') }
    }
    if ($F.Desligamentos -and $F.DesligSemTela) {
        if ($quente) { $C.Add('Desligamentos sem tela azul + temperaturas críticas no teste: provável SUPERAQUECIMENTO.') }
        elseif ($F.Emergencia) { $C.Add('Temperatura chegou ao nível de emergência no teste: resolva a refrigeração antes de qualquer outra coisa.') }
        else { $C.Add('Desligamentos sem tela azul, mas as temperaturas ficaram normais e o PC aguentou o teste: verifique fonte (falha intermitente), cabo de força, tomada/estabilizador, botão power e se o usuário está forçando o desligamento depois de travar.') }
    }
    if ($F.RamErros -or $F.BsodRam) { $C.Add('MEMÓRIA RAM suspeita: teste um pente por vez, limpe os contatos (borracha), desative XMP/DOCP na BIOS. Para confirmar, use MemTest86 em pendrive.') }
    if ($F.DiscoErros -or $F.SmartRuim -or $F.BsodDisco) { $C.Add('SSD/HD com problema: faça BACKUP imediatamente e substitua. Em SATA, troque o cabo antes de condenar o disco.') }
    elseif ($F.DiscoAvisos) { $C.Add('Avisos de disco nos logs (resets/retentativas) explicam travamentos de alguns segundos: cabo SATA, firmware do SSD, modo AHCI e saúde do disco.') }
    if ($F.Tdr -or $F.BsodGpu -or $F.GpuFalhou) { $C.Add('PLACA DE VÍDEO/driver: reinstale o driver limpo (DDU + driver novo do site). Se continuar com temperatura normal, suspeite da GPU ou da fonte.') }
    if ($F.CpuErros -or $F.WheaFatal -or $F.BsodHw) { $C.Add('INSTABILIDADE de hardware: remova overclock/undervolt, restaure padrões da BIOS (e atualize a BIOS). Persistindo: CPU, placa-mãe ou fonte.') }
    if ($quente -or $F.Throttle -or $F.CpuMorno -or $F.GpuMorno -or $F.ThrottleLog) { $C.Add('REFRIGERAÇÃO: limpeza de poeira, pasta térmica nova, conferir se todas as ventoinhas giram (e o fluxo de ar do gabinete).') }
    if ($F.HddSistema) { $C.Add('Lentidão/travadinhas: Windows em HD mecânico. Trocar por SSD é a melhoria mais efetiva.') }
    if ($F.PoucaRam) { $C.Add('Pouca RAM: upgrade para 8-16 GB.') }
    if ($F.DiscoCheio) { $C.Add('Libere espaço no disco do sistema (Limpeza de Disco, arquivos temporários, desinstalar programas).') }
    if ($F.AppHangs -ge 15 -and -not $C.Count) { $C.Add('Muitos programas "não respondendo", sem falha de hardware detectada: provável causa de software (programas em segundo plano, antivírus, Windows corrompido). Rode "sfc /scannow" e "DISM /Online /Cleanup-Image /RestoreHealth".') }
    if (-not $C.Count) { $C.Add('Nenhum problema de hardware encontrado nos testes. Se o defeito relatado continuar, suspeite de software/drivers (sfc /scannow, DISM, drivers atualizados) ou de falha intermitente: rode o modo Completo com mais tempo (60 min).') }
}

# ---------------------------------------------------------------------------
#  Relatório
# ---------------------------------------------------------------------------
function New-GraficoSvg {
    $a = $script:Amostras.ToArray()
    if ($a.Count -lt 3) { return '' }
    $W = 1000; $H = 260; $padL = 40; $padB = 22; $padT = 10
    $ymin = 20; $ymax = 110
    $n = $a.Count
    $X = { param($i) $padL + ($W - $padL - 10) * $i / ($n - 1) }
    $Y = { param($v) $padT + ($H - $padT - $padB) * (1 - ([Math]::Min($ymax, [Math]::Max($ymin, $v)) - $ymin) / ($ymax - $ymin)) }
    $Yl = { param($v) $padT + ($H - $padT - $padB) * (1 - [Math]::Min(100, [Math]::Max(0, $v)) / 100) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $W $H' class='graf' xmlns='http://www.w3.org/2000/svg'>")
    foreach ($t in 30, 50, 70, 90, 110) {
        $yy = (& $Y $t).ToString('0.#', $Cult)
        [void]$sb.Append("<line x1='$padL' x2='$($W-10)' y1='$yy' y2='$yy' stroke='#e3e6ea'/><text x='4' y='$yy' font-size='11' fill='#888' dy='4'>$t°</text>")
    }
    $fasePrev = $null
    for ($i = 0; $i -lt $n; $i++) {
        if ($a[$i].Fase -ne $fasePrev) {
            $xx = (& $X $i).ToString('0.#', $Cult)
            [void]$sb.Append("<line x1='$xx' x2='$xx' y1='$padT' y2='$($H-$padB)' stroke='#b9c0c8' stroke-dasharray='3,3'/><text x='$xx' y='$($H-6)' font-size='10' fill='#666' dx='3'>$(HtmlEnc $a[$i].Fase)</text>")
            $fasePrev = $a[$i].Fase
        }
    }
    $series = @(
        @{ P = 'CpuLoad'; Cor = '#c9ced6'; Esc = $Yl; W = 1.2 },
        @{ P = 'CpuTemp'; Cor = '#d9363e'; Esc = $Y; W = 2 },
        @{ P = 'GpuTemp'; Cor = '#2f6fdb'; Esc = $Y; W = 2 }
    )
    foreach ($s in $series) {
        $pts = for ($i = 0; $i -lt $n; $i++) {
            $v = $a[$i].($s.P)
            if ($null -ne $v) { '{0},{1}' -f (& $X $i).ToString('0.#', $Cult), (& $s.Esc $v).ToString('0.#', $Cult) }
        }
        if (@($pts).Count -gt 1) { [void]$sb.Append("<polyline fill='none' stroke='$($s.Cor)' stroke-width='$($s.W)' points='$($pts -join ' ')'/>") }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-Relatorio {
    Write-Etapa 'Gerando relatório'
    $ordem = @{ CRITICO = 0; ATENCAO = 1; INFO = 2; OK = 3 }
    $achados = @($script:Achados | Sort-Object { $ordem[$_.Nivel] })
    $nCrit = @($achados | Where-Object Nivel -eq 'CRITICO').Count
    $nAt = @($achados | Where-Object Nivel -eq 'ATENCAO').Count
    if ($nCrit) { $veredito = "PROBLEMAS ENCONTRADOS: $nCrit crítico(s), $nAt ponto(s) de atenção"; $vcls = 'crit' }
    elseif ($nAt) { $veredito = "$nAt ponto(s) de atenção - nenhum problema crítico"; $vcls = 'aten' }
    else { $veredito = 'Nenhum problema encontrado'; $vcls = 'ok' }
    $dur = Format-Duracao ((Get-Date) - $script:InicioGeral).TotalSeconds
    $rotulo = @{ CRITICO = 'CRÍTICO'; ATENCAO = 'ATENÇÃO'; INFO = 'INFO'; OK = 'OK' }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append(@"
<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DiagPC - $(HtmlEnc $env:COMPUTERNAME)</title>
<style>
body{font-family:"Segoe UI",Roboto,Arial,sans-serif;background:#f3f5f8;color:#1d2330;margin:0;padding:24px}
.box{max-width:1080px;margin:0 auto}
h1{margin:0 0 4px;font-size:26px}h2{font-size:18px;margin:28px 0 10px;border-bottom:2px solid #dde2e8;padding-bottom:6px}
.sub{color:#5b6573;font-size:14px}
.ver{padding:16px 20px;border-radius:10px;font-size:20px;font-weight:600;margin:18px 0;color:#fff}
.ver.crit{background:#c62828}.ver.aten{background:#e08a00}.ver.ok{background:#2e7d32}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;font-size:14px;box-shadow:0 1px 2px rgba(0,0,0,.06)}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #eceff3;vertical-align:top}th{background:#e9edf2;font-weight:600}
.tag{display:inline-block;min-width:70px;text-align:center;padding:2px 8px;border-radius:6px;font-size:12px;font-weight:700;color:#fff}
.CRITICO{background:#c62828}.ATENCAO{background:#e08a00}.INFO{background:#4b7bb5}.OK{background:#2e7d32}
.det{color:#555;font-size:13px;margin-top:3px}
ul.conc li{margin:6px 0;background:#fff;padding:10px 12px;border-radius:8px;list-style:none;border-left:4px solid #2f6fdb}
ul.conc{padding:0}
.graf{width:100%;background:#fff;border-radius:8px}
.leg span{margin-right:16px;font-size:13px}.leg i{display:inline-block;width:14px;height:4px;margin-right:5px;vertical-align:middle}
.barra{height:8px;background:#e6e9ee;border-radius:4px;margin:2px 0 4px;overflow:hidden}.barra div{height:100%}
.nota{font-size:12px;color:#6b7480;margin-top:24px}
</style></head><body><div class="box">
<h1>Relatório DiagPC</h1>
<div class="sub">$(HtmlEnc $script:Inv['Computador']) &middot; $(Get-Date -Format 'dd/MM/yyyy HH:mm') &middot; duração $dur &middot; modo $(HtmlEnc $Modo)</div>
<div class="ver $vcls">$(HtmlEnc $veredito)</div>
<h2>Conclusão / prováveis causas</h2><ul class="conc">
"@)
    foreach ($c in $script:Conclusoes) { [void]$sb.Append("<li>$(HtmlEnc $c)</li>") }
    [void]$sb.Append('</ul><h2>Problemas e verificações</h2><table><tr><th style="width:90px">Nível</th><th style="width:170px">Área</th><th>Resultado</th></tr>')
    foreach ($x in $achados) {
        $det = $(if ($x.Detalhe) { "<div class='det'>$(HtmlEnc $x.Detalhe)</div>" } else { '' })
        [void]$sb.Append("<tr><td><span class='tag $($x.Nivel)'>$($rotulo[$x.Nivel])</span></td><td>$(HtmlEnc $x.Categoria)</td><td>$(HtmlEnc $x.Titulo)$det</td></tr>")
    }
    [void]$sb.Append('</table>')

    # Etapas
    [void]$sb.Append('<h2>Etapas executadas</h2><table><tr><th>Etapa</th><th>Duração</th><th>Situação</th><th>CPU máx</th><th>CPU carga</th><th>CPU clock</th><th>GPU máx</th><th>GPU carga</th><th>Disco máx</th></tr>')
    foreach ($f in $script:Fases) {
        $st = Get-StatsFase $f.Nome
        $durF = $(if ($f.Fim) { Format-Duracao ($f.Fim - $f.Inicio).TotalSeconds } else { '--' })
        $sit = HtmlEnc $f.Situacao; if ($f.Obs) { $sit += "<div class='det'>$(HtmlEnc $f.Obs)</div>" }
        [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td>{8}</td></tr>' -f (HtmlEnc $f.Nome), $durF, $sit,
                (Fmt $st.CpuTempMax ' °C'), (Fmt $st.CpuLoadMed '%'), $(if ($st.CpuClockMed) { '{0:N2} GHz' -f ($st.CpuClockMed / 1000) } else { '--' }),
                (Fmt $st.GpuTempMax ' °C'), (Fmt $st.GpuLoadMed '%'), (Fmt $st.DiscoTempMax ' °C')))
    }
    [void]$sb.Append('</table>')

    $svg = New-GraficoSvg
    if ($svg) {
        [void]$sb.Append("<h2>Temperaturas ao longo do teste</h2><div class='leg'><span><i style='background:#d9363e'></i>CPU °C</span><span><i style='background:#2f6fdb'></i>GPU °C</span><span><i style='background:#c9ced6'></i>Carga da CPU (%)</span></div>$svg")
    }

    # Hardware
    [void]$sb.Append('<h2>Hardware</h2><table>')
    foreach ($k in $script:Inv.Keys) { [void]$sb.Append("<tr><th style='width:200px'>$(HtmlEnc $k)</th><td>$(HtmlEnc ([string]$script:Inv[$k]))</td></tr>") }
    [void]$sb.Append("<tr><th>Sensores</th><td>$(HtmlEnc $(if ($script:LHM) { 'LibreHardwareMonitor' } else { "Básicos do Windows - $($script:LHMErro)" }))</td></tr></table>")

    if ($script:Modulos) {
        [void]$sb.Append('<h2>Memória RAM</h2><table><tr><th>Slot</th><th>Tamanho</th><th>Velocidade</th><th>Fabricante</th><th>Modelo</th></tr>')
        foreach ($m in $script:Modulos) { [void]$sb.Append("<tr><td>$(HtmlEnc $m.Slot)</td><td>$($m.Tamanho)</td><td>$($m.Velocidade)</td><td>$(HtmlEnc $m.Fabricante)</td><td>$(HtmlEnc $m.Modelo)</td></tr>") }
        [void]$sb.Append('</table>')
    }
    if ($script:Discos.Count) {
        [void]$sb.Append('<h2>Discos</h2><table><tr><th>Disco</th><th>Saúde</th><th>Tipo</th><th>Tamanho</th><th>Status Windows</th><th>Temp.</th><th>Horas ligado</th></tr>')
        foreach ($d in $script:Discos) {
            if ($null -ne $d.SaudePct) {
                $cor = $(if ($d.SaudePct -ge 80) { '#2e7d32' } elseif ($d.SaudePct -ge 50) { '#e08a00' } else { '#c62828' })
                $sd = "<div class='barra'><div style='width:$($d.SaudePct)%;background:$cor'></div></div><b style='color:$cor'>$($d.SaudePct)%</b> $($d.SaudeRotulo)"
                if ($d.SaudeMotivo) { $sd += "<div class='det'>$(HtmlEnc $d.SaudeMotivo)</div>" }
            } else { $sd = '--' }
            [void]$sb.Append("<tr><td>$(HtmlEnc $d.Disco)<div class='det'>$(HtmlEnc $d.Barramento)</div></td><td style='min-width:190px'>$sd</td><td>$($d.Tipo)</td><td>$($d.Tamanho)</td><td>$($d.Saude)</td><td>$($d.Temperatura)</td><td>$($d.HorasLigado)</td></tr>")
        }
        [void]$sb.Append('</table>')
    }
    if ($script:Gpus) {
        [void]$sb.Append('<h2>Placa(s) de vídeo</h2><table><tr><th>Nome</th><th>Driver</th><th>Data do driver</th><th>Resolução</th></tr>')
        foreach ($g in $script:Gpus) { [void]$sb.Append(("<tr><td>{0}</td><td>{1}</td><td>{2:dd/MM/yyyy}</td><td>{3}</td></tr>" -f (HtmlEnc $g.Nome), $g.Driver, $g.DataDriver, $g.Resolucao)) }
        [void]$sb.Append('</table>')
    }
    if ($script:Eventos.Count) {
        [void]$sb.Append('<h2>Eventos relevantes do Windows</h2><table><tr><th style="width:120px">Data</th><th style="width:150px">Tipo</th><th>Fonte / descrição</th></tr>')
        foreach ($e in ($script:Eventos | Sort-Object Hora -Descending | Select-Object -First 60)) {
            [void]$sb.Append(("<tr><td>{0:dd/MM/yyyy HH:mm}</td><td>{1}</td><td>{2} ({3})<div class='det'>{4}</div></td></tr>" -f $e.Hora, (HtmlEnc $e.Tipo), (HtmlEnc $e.Fonte), $e.Id, (HtmlEnc $e.Descricao)))
        }
        [void]$sb.Append('</table>')
    }
    [void]$sb.Append("<div class='nota'>DiagPC $VersaoDiag - feito por Danilo Américo. Saúde dos discos em % calculada pelo DiagPC a partir do SMART (smartmontools). Leituras a cada 2 s em amostras_sensores.csv (mesma pasta). O teste de RAM cobre a memória livre do Windows; para teste completo de todos os endereços use MemTest86 (pendrive) ou o Diagnóstico de Memória do Windows (mdsched.exe). Temperaturas via LibreHardwareMonitor.</div></div></body></html>")
    Set-Content -Path $ArqHtml -Value $sb.ToString() -Encoding UTF8

    # TXT
    $t = New-Object Text.StringBuilder
    [void]$t.AppendLine("DiagPC $VersaoDiag (feito por Danilo Américo) - $($script:Inv['Computador'])")
    [void]$t.AppendLine("Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm')  Duração: $dur  Modo: $Modo")
    [void]$t.AppendLine("RESULTADO: $veredito")
    [void]$t.AppendLine('')
    [void]$t.AppendLine('CONCLUSÃO:')
    foreach ($c in $script:Conclusoes) { [void]$t.AppendLine(" - $c") }
    [void]$t.AppendLine('')
    foreach ($x in $achados) {
        [void]$t.AppendLine(('[{0}] {1}: {2}' -f $rotulo[$x.Nivel], $x.Categoria, $x.Titulo))
        if ($x.Detalhe) { [void]$t.AppendLine("      $($x.Detalhe)") }
    }
    [void]$t.AppendLine('')
    foreach ($k in $script:Inv.Keys) { [void]$t.AppendLine(('{0}: {1}' -f $k, $script:Inv[$k])) }
    Set-Content -Path $ArqTxt -Value $t.ToString() -Encoding UTF8

    Write-Host ''
    $cor = @{ crit = 'Red'; aten = 'Yellow'; ok = 'Green' }[$vcls]
    Write-Host "   RESULTADO: $veredito" -ForegroundColor $cor
    foreach ($c in $script:Conclusoes) { Write-Host "   -> $c" -ForegroundColor White }
    Write-Host ''
    Write-Host "   Relatório: $ArqHtml" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
#  Menu
# ---------------------------------------------------------------------------
function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  ____  _             ____   ____ ' -ForegroundColor Cyan
    Write-Host ' |  _ \(_) __ _  __ _|  _ \ / ___|' -ForegroundColor Cyan
    Write-Host ' | | | | |/ _` |/ _` | |_) | |    ' -ForegroundColor Cyan
    Write-Host ' | |_| | | (_| | (_| |  __/| |___ ' -ForegroundColor Cyan
    Write-Host ' |____/|_|\__,_|\__, |_|    \____|' -ForegroundColor Cyan
    Write-Host '                |___/   diagnóstico de hardware v' -NoNewline -ForegroundColor Cyan
    Write-Host $VersaoDiag -ForegroundColor Cyan
    Write-Host '                        feito por Danilo Américo' -ForegroundColor DarkGray
    Write-Host ''
}

function Read-SimNao([string]$p, [bool]$padrao = $true) {
    $sufixo = $(if ($padrao) { '[S/n]' } else { '[s/N]' })
    $r = Read-Host "   $p $sufixo"
    if (-not $r) { return $padrao }
    return ($r -match '^[sSyY]')
}

Show-Banner
if (-not $Modo) {
    Write-Host '   Escolha o modo:' -ForegroundColor White
    Write-Host '   [1] Rápido       ~10 min  (triagem)'
    Write-Host '   [2] Completo     ~30 min  (recomendado para "desliga sozinho" / "trava")'
    Write-Host '   [3] Personalizado         (você escolhe tempo e testes)'
    Write-Host '   [4] Só diagnóstico ~2 min (logs, SMART, inventário - sem estresse)'
    Write-Host ''
    $op = Read-Host '   Opção [2]'
    switch ($op) {
        '1' { $Modo = 'Rapido' }
        '3' { $Modo = 'Personalizado' }
        '4' { $Modo = 'Diagnostico' }
        default { $Modo = 'Completo' }
    }
}
$tamDiscoMB = 4096
switch ($Modo) {
    'Rapido' { if (-not $Minutos) { $Minutos = 10 }; $tamDiscoMB = 1024 }
    'Completo' { if (-not $Minutos) { $Minutos = 30 }; $tamDiscoMB = 4096 }
    'Diagnostico' { $Minutos = 2; $SemCPU = $true; $SemRAM = $true; $SemDisco = $true; $SemGPU = $true }
    'Personalizado' {
        if (-not $Minutos) {
            $m = Read-Host '   Duração total em minutos [45]'
            $Minutos = 45; if ($m -match '^\d+$' -and [int]$m -ge 5) { $Minutos = [int]$m }
        }
        if (-not $PSBoundParameters.ContainsKey('SemRAM')) { $SemRAM = -not (Read-SimNao 'Testar memória RAM?') }
        if (-not $PSBoundParameters.ContainsKey('SemCPU')) { $SemCPU = -not (Read-SimNao 'Estresse do processador?') }
        if (-not $PSBoundParameters.ContainsKey('SemGPU')) { $SemGPU = -not (Read-SimNao 'Estresse da placa de vídeo?') }
        if (-not $PSBoundParameters.ContainsKey('SemDisco')) { $SemDisco = -not (Read-SimNao 'Teste de gravação/leitura do SSD/HD?') }
        $tamDiscoMB = [Math]::Min(8192, [Math]::Max(1024, $Minutos * 100))
    }
}

# Distribuição do tempo
$tempoFixo = 30 + 90 + $(if ($SemDisco) { 0 } else { [int]($tamDiscoMB / 30) })
$orcamento = [Math]::Max(240, $Minutos * 60 - $tempoFixo)
$pesos = [ordered]@{}
if (-not $SemRAM) { $pesos.RAM = 0.30 }
if (-not $SemCPU) { $pesos.CPU = 0.25 }
if (-not $SemGPU) { $pesos.GPU = 0.25 }
if (-not $SemCPU -and -not $SemGPU) { $pesos.Combo = 0.20 }
$somaPesos = ($pesos.Values | Measure-Object -Sum).Sum
$tempos = @{}
foreach ($k in $pesos.Keys) { $tempos[$k] = [int]($orcamento * $pesos[$k] / $somaPesos) }

$planos = @()
if (-not $SemDisco) { $planos += "SSD/HD ($tamDiscoMB MB)" }
foreach ($k in $pesos.Keys) { $planos += '{0} {1}' -f @{ RAM = 'RAM'; CPU = 'CPU'; GPU = 'GPU'; Combo = 'CPU+GPU' }[$k], (Format-Duracao $tempos[$k]) }
Write-Host ''
Write-Host "   Modo: $Modo  |  Testes: $(if ($planos) { $planos -join ', ' } else { 'nenhum estresse' })" -ForegroundColor White
Write-Host '   Feche os programas abertos. Não use o PC durante o teste. Notebook: deixe na TOMADA.' -ForegroundColor Yellow
Write-Host '   Se o PC desligar sozinho no meio do teste, ligue e rode o DiagPC de novo: ele vai registrar isso.' -ForegroundColor Yellow
Write-Host ''

# ---------------------------------------------------------------------------
#  Execução
# ---------------------------------------------------------------------------
[DiagSys]::DesativarQuickEdit()
$nThreads = [Environment]::ProcessorCount

try {
    Test-ExecucaoAnterior
    Save-Estado 'Rodando'
    [DiagSys]::ManterAcordado($true)
    Initialize-Sensores

    Invoke-Fase -Nome 'Repouso' -Segundos $(if ($Modo -eq 'Diagnostico') { 15 } else { 30 })
    $st = Get-StatsFase 'Repouso'
    if ($null -ne $st.CpuTempMed) {
        if ($st.CpuTempMed -ge $LIM.CpuRepousoCritico) { $script:Flags.CpuQuente = $true; Add-Achado CRITICO 'Temperatura' ('Processador muito quente EM REPOUSO: {0:N0} °C' -f $st.CpuTempMed) 'Cooler parado/solto, pasta térmica seca ou poeira acumulada.' }
        elseif ($st.CpuTempMed -ge $LIM.CpuRepousoAtencao) { $script:Flags.CpuMorno = $true; Add-Achado ATENCAO 'Temperatura' ('Processador quente em repouso: {0:N0} °C' -f $st.CpuTempMed) 'O normal em repouso é 30-55 °C (notebooks até ~60 °C).' }
        else { Add-Achado OK 'Temperatura' ('Processador em repouso: {0:N0} °C' -f $st.CpuTempMed) }
    } else {
        Add-Achado INFO 'Temperatura' 'Não foi possível ler a temperatura do processador' "Sensor indisponível ($($script:LHMErro)). Veja a seção Sensores no LEIA-ME."
    }
    if ($null -ne $st.GpuTempMed -and $st.GpuTempMed -ge 70) { Add-Achado ATENCAO 'Temperatura' ('Placa de vídeo quente em repouso: {0:N0} °C' -f $st.GpuTempMed) 'Ventoinhas da placa podem estar paradas/sujas.' }
    if ($null -ne $st.CpuLoadMed -and $st.CpuLoadMed -ge 30) {
        $top = (Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object { $_.ProcessName }) -join ', '
        Add-Achado ATENCAO 'Desempenho' ('Processador {0:N0}% ocupado em repouso' -f $st.CpuLoadMed) "Algo está consumindo CPU em segundo plano (processos com mais CPU acumulada: $top). Pode ser atualização do Windows, antivírus ou malware."
    }

    Get-Inventario
    Get-AnaliseEventos
    Get-SaudeArmazenamento
    $script:InicioTestes = Get-Date

    # --- Disco ---
    if (-not $SemDisco) {
        $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
        $livreMB = [int64]($vol.FreeSpace / 1MB)
        $tam = [int64][Math]::Min($tamDiscoMB, ($livreMB - 3072) * 0.5)
        $tam = [int64]([Math]::Floor($tam / 4) * 4)
        if ($tam -ge 256) {
            $arqTeste = Join-Path $env:SystemDrive 'diagpc_teste_disco.tmp'
            Invoke-Fase -Nome 'Teste de SSD/HD' -Segundos 1800 `
                -Iniciar { [DiagDisk]::Start($arqTeste, $tam) } `
                -Terminou { [DiagDisk]::Done } `
                -Parar { if (-not [DiagDisk]::Done) { [DiagDisk]::Stop() } } `
                -Status { '{0} {1}/{2} MB' -f [DiagDisk]::Etapa, [DiagDisk]::DoneMB, [DiagDisk]::TotalMB }
            $w = [DiagDisk]::WriteMBps; $r = [DiagDisk]::ReadMBps
            $script:Inv['Velocidade do disco (teste)'] = 'gravação {0:N0} MB/s, leitura {1:N0} MB/s ({2} MB)' -f $w, $r, [DiagDisk]::WrittenMB
            if ([DiagDisk]::IoErrors -gt 0 -or [DiagDisk]::Mismatches -gt 0) {
                $script:Flags.DiscoErros = $true
                Add-Achado CRITICO 'Teste de disco' 'FALHA no teste de gravação/leitura do disco' ("{0}. {1} bloco(s) de dados corrompidos. Disco, cabo ou controlador com defeito (ou RAM instável)." -f [DiagDisk]::Error, [DiagDisk]::Mismatches)
            } elseif ([DiagDisk]::SetupFailed) {
                Add-Achado INFO 'Teste de disco' 'Teste de disco não pôde ser executado' ([DiagDisk]::Error)
            } elseif ([DiagDisk]::WrittenMB -gt 0) {
                $sysPd = $null
                try { $num = (Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')).DiskNumber; $sysPd = Get-PhysicalDisk | Where-Object { "$($_.DeviceId)" -eq "$num" } } catch {}
                $ehSsd = ($sysPd -and "$($sysPd.MediaType)" -eq 'SSD')
                $txtV = 'Gravação {0:N0} MB/s, leitura {1:N0} MB/s, {2} MB verificados sem erro' -f $w, $r, [DiagDisk]::WrittenMB
                if ($ehSsd -and ($w -lt 80 -or $r -lt 150)) { Add-Achado ATENCAO 'Teste de disco' "SSD lento: $txtV" 'Para SSD o esperado é acima de ~300 MB/s (SATA) ou ~1000 MB/s (NVMe). Causas: SSD cheio, sem cache/QLC saturado, modo IDE na BIOS, desgaste ou superaquecimento.' }
                elseif (-not $ehSsd -and $r -lt 50) { Add-Achado ATENCAO 'Teste de disco' "Disco muito lento: $txtV" 'HD mecânico desgastado ou com setores ruins.' }
                else { Add-Achado OK 'Teste de disco' $txtV }
            }
            $st = Get-StatsFase 'Teste de SSD/HD'
            if ($null -ne $st.DiscoTempMax -and $st.DiscoTempMax -ge 75) { Add-Achado ATENCAO 'Temperatura' ('SSD/HD chegou a {0:N0} °C durante o teste' -f $st.DiscoTempMax) 'SSD NVMe acima de ~75 °C reduz velocidade (throttling). Dissipador ou ventilação.' }

            try {
                Write-Host '   Verificando sistema de arquivos (sem alterar nada)...' -ForegroundColor Gray
                $letra = $env:SystemDrive.TrimEnd(':')
                $job = Start-Job -ScriptBlock { param($l) (Repair-Volume -DriveLetter $l -Scan -ErrorAction Stop).ToString() } -ArgumentList $letra
                if (Wait-Job $job -Timeout 300) {
                    $res = "$(Receive-Job $job -ErrorAction SilentlyContinue)"
                    if ($res -and $res -ne 'NoErrorsFound') {
                        Add-Achado ATENCAO 'Sistema de arquivos' "Sistema de arquivos com problemas ($res)" "Rode 'chkdsk $($env:SystemDrive) /f' e reinicie."
                    } elseif ($res) { Add-Achado OK 'Sistema de arquivos' 'Sistema de arquivos sem erros' }
                }
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            } catch {}
        } else {
            Add-Achado INFO 'Teste de disco' 'Teste de disco pulado: pouco espaço livre' ''
        }
    }

    # --- RAM ---
    if (-not $SemRAM) {
        $os = Get-CimInstance Win32_OperatingSystem
        $livreMB = [int64]($os.FreePhysicalMemory / 1KB)
        $alvo = [int64]($livreMB * 0.75) - 512
        if (-not [Environment]::Is64BitProcess) { $alvo = [Math]::Min($alvo, 1200) }
        $totalMB = [int64]($os.TotalVisibleMemorySize / 1KB)
        if ($alvo -ge 256) {
            Invoke-Fase -Nome 'Teste de memória RAM' -Segundos $tempos.RAM `
                -Iniciar { Write-Host '   Reservando memória...' -ForegroundColor Gray; [void][DiagMem]::Allocate($alvo); [DiagMem]::Start($nThreads) } `
                -Parar { [DiagMem]::Free() } `
                -Status { 'RAM {0:N1}GB passada {1} erros {2}' -f ([DiagMem]::AllocatedMB / 1024), [DiagMem]::Passes, [DiagMem]::Errors }
            $alocGB = '{0:N1} GB' -f ($alvo / 1024)
            $pct = $alvo / $totalMB * 100
            if ([DiagMem]::Errors -gt 0) {
                $script:Flags.RamErros = $true
                Add-Achado CRITICO 'Memória RAM' ('ERROS DE MEMÓRIA: {0} erro(s) encontrados no teste' -f [DiagMem]::Errors) ("Primeiro erro: {0}. Pente de memória com defeito, mal encaixado, XMP/overclock instável ou slot/placa-mãe. Teste um pente por vez." -f [DiagMem]::FirstError)
            } elseif ([DiagMem]::VerifiedMB -gt 0) {
                Add-Achado OK 'Memória RAM' ('Teste de memória sem erros ({0} testados, ~{1:N0}% da RAM, {2:N0} GB verificados)' -f $alocGB, $pct, ([DiagMem]::VerifiedMB / 1024)) 'Para cobrir 100% da memória, use MemTest86 em pendrive.'
            }
        } else {
            Add-Achado INFO 'Memória RAM' 'Teste de RAM pulado: pouca memória livre' ''
        }
    }

    # --- CPU ---
    if (-not $SemCPU) {
        Invoke-Fase -Nome 'Estresse do processador' -Segundos $tempos.CPU `
            -Iniciar { [DiagCpu]::Start($nThreads) } -Parar { [DiagCpu]::Stop() } `
            -Status { 'cálculos {0:N0} erros {1}' -f [DiagCpu]::Iterations, [DiagCpu]::Errors }
        $st = Get-StatsFase 'Estresse do processador'
        if ([DiagCpu]::Errors -gt 0) {
            $script:Flags.CpuErros = $true
            Add-Achado CRITICO 'Processador' ('O processador ERROU {0} cálculo(s) sob carga' -f [DiagCpu]::Errors) 'Instabilidade: overclock/undervolt, tensão, superaquecimento, fonte ou CPU/placa-mãe com defeito.'
        } else {
            Add-Achado OK 'Processador' ('Estresse do processador sem erros de cálculo ({0:N0} verificações)' -f [DiagCpu]::Iterations)
        }
        Test-TempCpu $st.CpuTempMax 'sob carga máxima'
        Test-Throttling 'Estresse do processador'
        if ($null -ne $st.CpuPowerMax) { $script:Inv['Consumo da CPU (máx.)'] = '{0:N0} W' -f $st.CpuPowerMax }
    }

    # --- GPU ---
    if (-not $SemGPU) {
        $okGpu = $false
        Invoke-Fase -Nome 'Estresse da placa de vídeo' -Segundos $tempos.GPU `
            -Iniciar { $script:okGpuIni = Start-GpuStress $tempos.GPU; if ($script:okGpuIni) { Start-Sleep 4 } } `
            -Parar { Stop-GpuStress } `
            -Terminou { -not $script:okGpuIni } `
            -Status { if ($script:GpuFalhaMsg) { 'FALHA' } else { 'teste WebGL' } }
        $okGpu = $script:okGpuIni
        if (-not $okGpu) {
            Add-Achado INFO 'Placa de vídeo' 'Teste de GPU não executado: Edge/Chrome não encontrado' ''
        } else {
            $st = Get-StatsFase 'Estresse da placa de vídeo'
            if ($script:GpuFalhaMsg) {
                $script:Flags.GpuFalhou = $true
                Add-Achado CRITICO 'Placa de vídeo' 'A placa de vídeo FALHOU durante o teste' $script:GpuFalhaMsg
            } elseif ($null -eq $script:GpuTitulo) {
                Add-Achado INFO 'Placa de vídeo' 'Não foi possível confirmar se o teste de GPU rodou' 'A janela do teste não foi identificada.'
            } else {
                $txt = 'Estresse da placa de vídeo concluído sem falhas'
                if ($null -ne $st.GpuFpsMed) { $txt += (' (média {0:N0} FPS, carga {1})' -f $st.GpuFpsMed, (Fmt $st.GpuLoadMed '%')) }
                Add-Achado OK 'Placa de vídeo' $txt
                if ($null -ne $st.GpuLoadMed -and $st.GpuLoadMed -lt 60) {
                    Add-Achado INFO 'Placa de vídeo' ('Carga média da GPU ficou em {0:N0}% no teste' -f $st.GpuLoadMed) 'Em notebook com duas placas o navegador pode ter usado o vídeo integrado. Para forçar a dedicada: Configurações > Sistema > Tela > Elementos gráficos > Edge > Alto desempenho.'
                }
            }
            Test-TempGpu $st 'sob carga máxima'
            if ($null -eq $st.GpuTempMax) { Add-Achado INFO 'Temperatura' 'Temperatura da placa de vídeo não disponível' 'Vídeo integrado normalmente não informa temperatura separada.' }
        }
    }

    # --- Combinado ---
    if ($pesos.Contains('Combo') -and $script:okGpuIni) {
        Invoke-Fase -Nome 'Teste combinado CPU+GPU' -Segundos $tempos.Combo `
            -Iniciar { [DiagCpu]::Start($nThreads); [void](Start-GpuStress $tempos.Combo); Start-Sleep 3 } `
            -Parar { [DiagCpu]::Stop(); Stop-GpuStress } `
            -Status { 'erros CPU {0}' -f [DiagCpu]::Errors }
        $st = Get-StatsFase 'Teste combinado CPU+GPU'
        $f = $script:Fases[$script:Fases.Count - 1]
        if ([DiagCpu]::Errors -gt 0) {
            $script:Flags.CpuErros = $true
            Add-Achado CRITICO 'Processador' ('Erros de cálculo no teste combinado: {0}' -f [DiagCpu]::Errors) 'Instável com carga total do sistema: suspeita de fonte ou tensão.'
        }
        Test-TempCpu $st.CpuTempMax 'no teste combinado'
        Test-TempGpu $st 'no teste combinado'
        if ($f.Situacao -eq 'Concluída') {
            $pot = ''
            if ($null -ne $st.CpuPowerMax -or $null -ne $st.GpuPowerMax) { $pot = 'Consumo medido: CPU {0}, GPU {1}.' -f (Fmt $st.CpuPowerMax ' W'), (Fmt $st.GpuPowerMax ' W') }
            Add-Achado OK 'Energia' ('O sistema aguentou CPU + GPU em carga máxima por {0} sem desligar' -f (Format-Duracao ($f.Fim - $f.Inicio).TotalSeconds)) "$pot Bom sinal para a fonte (não descarta falha intermitente)."
        }
    }

    Test-EventosDuranteTeste
    $script:Concluido = $true
}
finally {
    try { [DiagCpu]::Stop() } catch {}
    try { [DiagMem]::Free() } catch {}
    try { [DiagDisk]::Stop() } catch {}
    try { Stop-GpuStress } catch {}
    try { [DiagSys]::ManterAcordado($false) } catch {}
    try { if ($script:LHM) { $script:LHM.Close() } } catch {}
    if (-not $script:Concluido) { Add-Achado INFO 'Execução' 'Teste interrompido antes do fim - relatório parcial' '' }
    try { Get-Conclusoes; New-Relatorio } catch { Write-Host "Erro ao gerar relatório: $($_.Exception.Message)" -ForegroundColor Red }
    Save-Estado $(if ($script:Concluido) { 'Concluido' } else { 'Interrompido' })
    if (-not $NaoAbrir -and (Test-Path $ArqHtml)) { Start-Process $ArqHtml }
}

Write-Host ''
Read-Host '   Pressione ENTER para fechar' | Out-Null
