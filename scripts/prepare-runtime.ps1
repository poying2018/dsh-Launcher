# Pre-bundle the portable runtime (Node + pnpm + @deepseek-ai/dsh) into
# resources/runtime. electron-builder ships it via extraResources, so a fresh
# install can boot dsh straight from the install directory with zero downloads
# (true offline deployment).
#
# Layout matches what runtime.ts "Online Install" (installRuntime) produces:
#   resources/runtime/node   (node.exe + npm/pnpm)
#   resources/runtime/dsh    (full dsh package closure)
# At app runtime, ~/.dsh-runtime (runtimeRoot) wins, the installer-bundled copy
# is the fallback.
#
# Idempotent: steps are skipped when their output already exists. The build
# machine needs access to npmmirror. Note: keep this file ASCII-only -- Windows
# PowerShell 5.1 reads BOM-less .ps1 as ANSI, and non-ASCII bytes can break parsing.
#
# Usage (repo root):
#   powershell -ExecutionPolicy Bypass -File scripts\prepare-runtime.ps1

param(
    [string]$NodeVersion = "v22.20.0"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$out = Join-Path $repo "resources\runtime"
$node = Join-Path $out "node"
$dsh = Join-Path $out "dsh"
$REG = "https://registry.npmmirror.com"

New-Item -ItemType Directory -Force -Path $node, $dsh | Out-Null

Write-Host "== 1/3 Node $NodeVersion =="
if (-not (Test-Path (Join-Path $node "node.exe"))) {
    $zip = Join-Path $out "node-$NodeVersion-win-x64.zip"
    if (-not (Test-Path $zip)) {
        Invoke-WebRequest "https://registry.npmmirror.com/-/binary/node/$NodeVersion/node-$NodeVersion-win-x64.zip" -OutFile $zip
    }
    $stage = Join-Path $out "node-stage"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $stage -Force
    Get-ChildItem (Join-Path $stage "node-$NodeVersion-win-x64") | Move-Item -Destination $node -Force
    Remove-Item $stage -Recurse -Force
    Remove-Item $zip -Force
} else {
    Write-Host "  exists, skipping download"
}
Write-Host "  node.exe: $((Get-Item (Join-Path $node 'node.exe')).FullName)"

Write-Host "== 2/3 pnpm (into the node dir, same layout as Online Install) =="
$npm = Join-Path $node "npm.cmd"
$pnpm = Join-Path $node "pnpm.cmd"
if (-not (Test-Path $pnpm)) {
    # Pin the global prefix so pnpm.cmd lands next to node.exe (runtime.ts expects it at nodeDir()).
    $env:NPM_CONFIG_PREFIX = $node
    & $npm install -g pnpm --registry=$REG --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "pnpm install failed (exit $LASTEXITCODE)" }
}
if (-not (Test-Path $pnpm)) { throw "pnpm.cmd not found at expected location: $pnpm" }
Write-Host "  pnpm.cmd: $pnpm"

Write-Host "== 3/3 @deepseek-ai/dsh@latest (into the dsh dir) =="
$pkg = Join-Path $dsh "package.json"
if (-not (Test-Path $pkg)) {
    Set-Content -Path $pkg -Value '{ "name": "dsh-runtime", "private": true, "version": "0.0.0" }' -Encoding UTF8
}
$bin = Join-Path $dsh "node_modules\@deepseek-ai\dsh\lib\bin.js"
if (-not (Test-Path $bin)) {
    Push-Location $dsh
    try {
        & $pnpm add "@deepseek-ai/dsh@latest" --registry=$REG --config.strictDepBuilds=false
        if ($LASTEXITCODE -ne 0) { throw "dsh install failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}
if (-not (Test-Path $bin)) { throw "dsh entry not found: $bin" }
Write-Host "  dsh bin: $bin"
Write-Host "== Done: bundled runtime ready (shipped with the installer, no network needed) =="
