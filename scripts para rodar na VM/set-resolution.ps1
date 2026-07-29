# set-resolution.ps1
#
# Ajusta a resolucao da sessao console da VM (default 1920x1080).
#
# FERRAMENTA MANUAL — NAO roda no startup. Foi cogitada para o startup-master.ps1 quando se
# suspeitava que o viewport pequeno da VM (~1024x768) causava a falha do desafio Cloudflare. Em
# 2026-07-28 isso foi DESCARTADO por medicao: a causa real era o `scale: 0.15` do clip em
# `captureAndSave` (cdp/cdp.js), que vaza como page scale factor e deixa a pagina renderizada a
# 15% no canto superior esquerdo — o clique do solver acertava a coordenada CSS e errava a tela.
# Corrigido com `scale: 1`. A resolucao da VM nao tinha relacao com o problema.
#
# Continua util para: diagnosticar o que o driver de video oferece (`-Query`), ou ajustar a
# resolucao pontualmente para acompanhar a VM por VNC/RDP em tela maior.
#
# Idempotente: se ja estiver no alvo, nao faz nada. A resolucao e por sessao — aplicar depois do
# autologon.
#
# Uso:
#   .\set-resolution.ps1                 # aplica 1920x1080
#   .\set-resolution.ps1 -Width 1600 -Height 900
#   .\set-resolution.ps1 -Query          # so relata (nao altera nada)
#
# NOTA (PowerShell 5.1): este script evita executaveis nativos de proposito. Chamadas nativas que
# escrevem em stderr viram NativeCommandError e abortam o .ps1 no Windows PowerShell 5.1.

param(
    [int]$Width  = 1920,
    [int]$Height = 1080,
    [switch]$Query
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class DisplayApi
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int   dmFields;
        public int   dmPositionX;
        public int   dmPositionY;
        public int   dmDisplayOrientation;
        public int   dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int   dmBitsPerPel;
        public int   dmPelsWidth;
        public int   dmPelsHeight;
        public int   dmDisplayFlags;
        public int   dmDisplayFrequency;
        public int   dmICMMethod;
        public int   dmICMIntent;
        public int   dmMediaType;
        public int   dmDitherType;
        public int   dmReserved1;
        public int   dmReserved2;
        public int   dmPanningWidth;
        public int   dmPanningHeight;
    }

    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int CDS_UPDATEREGISTRY    = 0x00000001;
    public const int CDS_TEST              = 0x00000002;
    public const int DISP_CHANGE_SUCCESSFUL = 0;
    public const int DM_PELSWIDTH  = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettings(ref DEVMODE devMode, int flags);
}
"@

function Get-ModoAtual {
    $dm = New-Object DisplayApi+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]([DisplayApi+DEVMODE]))
    # [NullString]::Value e obrigatorio: o PowerShell marshala $null para uma string VAZIA em
    # parametros [string] de P/Invoke, e EnumDisplaySettings("") falha (retorna 0). Com
    # [NullString]::Value vai NULL de verdade = "o display atual".
    if ([DisplayApi]::EnumDisplaySettings([NullString]::Value, [DisplayApi]::ENUM_CURRENT_SETTINGS, [ref]$dm) -eq 0) {
        return $null
    }
    return $dm
}

function Get-ModosDisponiveis {
    $modos = @()
    $i = 0
    while ($true) {
        $dm = New-Object DisplayApi+DEVMODE
        $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]([DisplayApi+DEVMODE]))
        if ([DisplayApi]::EnumDisplaySettings([NullString]::Value, $i, [ref]$dm) -eq 0) { break }
        $modos += [PSCustomObject]@{ Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight; Bpp = $dm.dmBitsPerPel }
        $i++
    }
    return $modos
}

$atual = Get-ModoAtual
if ($null -eq $atual) {
    Write-Host "[RESOLUCAO] Falha ao ler o modo atual (sessao sem display?). Nada a fazer."
    exit 0
}
Write-Host "[RESOLUCAO] Atual: $($atual.dmPelsWidth)x$($atual.dmPelsHeight) @ $($atual.dmBitsPerPel)bpp"

$modos = Get-ModosDisponiveis
$distintos = $modos | Select-Object Width, Height -Unique | Sort-Object Width, Height
Write-Host "[RESOLUCAO] Modos suportados pelo driver: $($distintos.Count)"
$maior = $distintos | Sort-Object { $_.Width * $_.Height } -Descending | Select-Object -First 1
if ($maior) { Write-Host "[RESOLUCAO] Maior disponivel: $($maior.Width)x$($maior.Height)" }

if ($Query) {
    Write-Host "[RESOLUCAO] Modo -Query: nada foi alterado."
    $distintos | ForEach-Object { Write-Host ("  - {0}x{1}" -f $_.Width, $_.Height) }
    exit 0
}

if ($atual.dmPelsWidth -eq $Width -and $atual.dmPelsHeight -eq $Height) {
    Write-Host "[RESOLUCAO] Ja esta em ${Width}x${Height}. Nada a fazer."
    exit 0
}

$suportado = $distintos | Where-Object { $_.Width -eq $Width -and $_.Height -eq $Height }
if (-not $suportado) {
    Write-Host "[RESOLUCAO] AVISO: o driver de video NAO oferece ${Width}x${Height}."
    Write-Host "[RESOLUCAO] O adaptador virtual do Azure so expoe os modos acima. Para ir alem,"
    Write-Host "[RESOLUCAO] e preciso um display driver virtual (indirect display) na imagem base."
    if ($maior) {
        Write-Host "[RESOLUCAO] Tentando o maior disponivel: $($maior.Width)x$($maior.Height)"
        $Width  = $maior.Width
        $Height = $maior.Height
        if ($atual.dmPelsWidth -eq $Width -and $atual.dmPelsHeight -eq $Height) {
            Write-Host "[RESOLUCAO] Ja esta no maior modo disponivel. Nada a fazer."
            exit 0
        }
    } else {
        exit 1
    }
}

$novo = Get-ModoAtual
$novo.dmPelsWidth  = $Width
$novo.dmPelsHeight = $Height
$novo.dmFields     = [DisplayApi]::DM_PELSWIDTH -bor [DisplayApi]::DM_PELSHEIGHT

# CDS_TEST primeiro: valida sem aplicar, evita deixar a sessao num estado ruim.
$teste = [DisplayApi]::ChangeDisplaySettings([ref]$novo, [DisplayApi]::CDS_TEST)
if ($teste -ne [DisplayApi]::DISP_CHANGE_SUCCESSFUL) {
    Write-Host "[RESOLUCAO] CDS_TEST recusou ${Width}x${Height} (codigo $teste). Nao aplicado."
    exit 1
}

# CDS_UPDATEREGISTRY: persiste no perfil, entao o proximo logon ja sobe na resolucao certa.
$r = [DisplayApi]::ChangeDisplaySettings([ref]$novo, [DisplayApi]::CDS_UPDATEREGISTRY)
if ($r -eq [DisplayApi]::DISP_CHANGE_SUCCESSFUL) {
    $confere = Get-ModoAtual
    Write-Host "[RESOLUCAO] Aplicado: $($confere.dmPelsWidth)x$($confere.dmPelsHeight)"
    exit 0
} else {
    Write-Host "[RESOLUCAO] ChangeDisplaySettings falhou (codigo $r)."
    exit 1
}
