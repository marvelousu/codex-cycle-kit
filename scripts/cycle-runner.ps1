#requires -Version 5.1
<#
.SYNOPSIS
    Cycle runner: parent 駆動の実装サイクルを 1 つ commit までオーケストレーションします。

.DESCRIPTION
    1 サイクル = 1 コミット。cycle-worker sub-agent が編集を終え、Validate / Capture メソッド名を
    WORKER_RESULT で返した後、parent(orchestrator)セッションから起動されます。

    フェーズ:
      1. Validate: バッチツールで $ValidateMethod を起動
      2. Capture: バッチツールで $CaptureMethod を起動(レビュー用 artifact: PNG / metrics / log)
      3. Build: バッチツールで $BuildMethod を起動(実行可能 artifact、たとえば player .exe)
      4. Smoke: ビルド成果物を $SmokeSeconds 秒動かし、ログを failure pattern で grep

    どこかのフェーズで失敗した場合: git reset --hard HEAD を実行し、failure log の末尾をサイクル devlog に追記し、非ゼロで exit します。
    全フェーズ通過した場合: サイクル devlog のタイトル行から commit subject を導出し、git add / commit / push を実行します。

    デフォルトは Unity Editor + Windows player ビルド(リファレンス実装)に向けています。スクリプトは
    パラメータ化されているので、Unity 以外のプロジェクトは -BatchTool / -BatchArgsTemplate で自前のバッチツールに差し替えられます。
    プロジェクトに compile-and-run smoke フェーズがなければ、-SkipBuild(または -BuildMethod 省略)を指定します。

.PARAMETER CycleNumber
    サイクル ordinal(例: 1、25)です。ログファイル名と commit body に使います。

.PARAMETER ValidateMethod
    validate バッチの fully-qualified callable です。worker が WORKER_RESULT で返します。

.PARAMETER CaptureMethod
    capture バッチの fully-qualified callable です(レビュー用 PNG / metrics / その他 observable を生成します)。
    worker が WORKER_RESULT で返します。

.PARAMETER DevlogPath
    サイクル devlog .md の絶対パスまたはリポ相対パスです。最初の H1 行が commit subject になります。

.PARAMETER BuildMethod
    build バッチの fully-qualified callable です(実行可能 artifact を生成します)。任意で、
    空のままなら build と smoke のフェーズをスキップします。

.PARAMETER Audience
    Capture 出力の prefix ルーティングです。worker セッション向けにレビュー用 artifact を出すなら 'worker'、
    parent 自身のレビュー pass なら 'parent_review'(デフォルト)を指定します。
    env CYCLE_AUDIENCE として export されるので、capture メソッドが尊重できます。尊重しない場合は
    runner が capture 出力ディレクトリ内の未 tag artifact を rename して prefix を付けます。

.PARAMETER CaptureOutputDir
    新規生成された capture artifact(デフォルト PNG)を runner が scan するディレクトリです。
    audience prefix の適用に使います。デフォルトは <ProjectPath>/docs/devlog/screenshots です。

.PARAMETER CaptureFilter
    CaptureOutputDir 内で runner が rename するファイル glob です。デフォルトは '*.png' です。

.PARAMETER BuildExe
    ビルド成果物の明示パス(任意)。省略した場合、runner はビルドログを $BuildArtifactPattern で
    parse し、見つからなければ <ProjectPath>/Builds/ 配下の最終更新ファイルにフォールバックします。

.PARAMETER BuildArtifactPattern
    ビルドログから生成成果物のパスを抽出する regex です。最初のキャプチャグループがパスになります。
    デフォルトは Unity の "player built: <path>.exe" ログ行にマッチします。

.PARAMETER ProjectPath
    プロジェクトルートです。デフォルトは本スクリプトの位置から解決したリポルート($PSScriptRoot\..)です。

.PARAMETER BatchTool
    バッチ実行ファイルのパスです。デフォルトは Unity.exe(env CYCLE_BATCH_TOOL または -BatchTool で上書き可)。

.PARAMETER BatchArgsTemplate
    バッチツール用の引数テンプレートです。placeholder {projectPath} / {method} / {logFile} に対応します。
    デフォルトは Unity Editor の -executeMethod 起動形にマッチします。

.PARAMETER SmokeArgsTemplate
    smoke フェーズでビルド成果物を実行するときの引数テンプレートです。placeholder {logFile} に対応します。
    デフォルトは Unity player の -batchmode -nographics -logFile 起動形にマッチします。

.PARAMETER SmokeSeconds
    smoke の実行時間(秒)です。デフォルトは 20 です。

.PARAMETER SmokePatterns
    smoke ログを grep する failure pattern の regex です(パイプ区切り alternation)。マッチ数は 0 でなければなりません。

.PARAMETER SkipBuild
    build と smoke のフェーズを完全にスキップします。smoke する compile ステップがないプロジェクトで使います。

.PARAMETER SkipPush
    ローカルで commit するが、push はしません。

.PARAMETER CommitPath
    commit 前に stage する path allowlist の明示指定です。省略時のデフォルトは `git add -A` です。
    パスはリポ相対または絶対のどちらでも可です。Unity プロジェクトで、バッチ validation が
    authored ではない side effect で scene や ProjectSettings を dirty にする場合に使います。

.PARAMETER NoRollback
    フェーズ失敗時に git reset --hard HEAD を実行しません。failure tail の devlog 追記と
    非ゼロ exit は通常通り行います。呼び出し側が手動 inspect のために dirty worktree を保持したい場合に使います。

.PARAMETER DryRun
    解決済みのプランを出力して終了します。バッチ起動も git の変更もしません。

.EXAMPLE
    # Unity Editor のリファレンスサイクル(Unity プロジェクトにそのまま使える)
    pwsh -File tools/cycle-runner.ps1 `
        -CycleNumber 2 `
        -ValidateMethod Project.EditorTools.SetupClass.ValidateTopicBatch `
        -CaptureMethod  Project.EditorTools.SetupClass.CaptureTopicCycle02ScreenshotsBatch `
        -BuildMethod    Project.EditorTools.SetupClass.BuildAndValidateBatch `
        -DevlogPath     docs/devlog/2026-05-23_topic_cycle02.md `
        -Audience       parent_review

.EXAMPLE
    # Unity 以外のプロジェクト(例: Node.js codegen パイプライン)
    pwsh -File tools/cycle-runner.ps1 `
        -CycleNumber 7 `
        -ValidateMethod scripts/validate.js `
        -CaptureMethod  scripts/capture.js `
        -DevlogPath     docs/devlog/cycle07.md `
        -BatchTool      node `
        -BatchArgsTemplate '{method} --project "{projectPath}" --log "{logFile}"' `
        -SkipBuild
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$CycleNumber,
    [Parameter(Mandatory = $true)][string]$ValidateMethod,
    [Parameter(Mandatory = $true)][string]$CaptureMethod,
    [Parameter(Mandatory = $true)][string]$DevlogPath,
    [string]$BuildMethod = '',
    [ValidateSet('worker', 'parent_review')][string]$Audience = 'parent_review',
    [string]$CaptureOutputDir = '',
    [string]$CaptureFilter = '*.png',
    [string]$BuildExe = '',
    [string]$BuildArtifactPattern = 'player built:\s*(.+\.exe)',
    [string]$ProjectPath = '',
    [string]$BatchTool = '',
    [string]$BatchArgsTemplate = '-batchmode -quit -projectPath "{projectPath}" -executeMethod {method} -logFile "{logFile}"',
    [string]$SmokeArgsTemplate = '-batchmode -nographics -logFile "{logFile}"',
    [int]$SmokeSeconds = 20,
    [string]$SmokePatterns = 'Error|Exception|Assert|NullReference|Font Atlas Texture|DrawObjectsPass|RenderGraph',
    [string[]]$CommitPath = @(),
    [switch]$SkipBuild,
    [switch]$SkipPush,
    [switch]$NoRollback,
    [switch]$DryRun
)

# PS 5.1 native exe stderr workaround: leave $ErrorActionPreference at Continue so that
# NativeCommandError-wrapped stderr does not trip a Stop terminator.
$ErrorActionPreference = 'Continue'
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

if (-not $ProjectPath) {
    $ProjectPath = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
}
if (-not (Test-Path $ProjectPath)) {
    throw "ProjectPath not found: $ProjectPath"
}

if (-not $BatchTool) {
    if ($env:CYCLE_BATCH_TOOL) { $BatchTool = $env:CYCLE_BATCH_TOOL }
    else { $BatchTool = 'C:\Program Files\Unity\Hub\Editor\6000.3.14f1\Editor\Unity.exe' }
}
if (-not (Test-Path $BatchTool)) {
    throw "BatchTool not found at: $BatchTool (override with -BatchTool or `$env:CYCLE_BATCH_TOOL)"
}

$DevlogResolved = $DevlogPath
if (-not [System.IO.Path]::IsPathRooted($DevlogResolved)) {
    $DevlogResolved = Join-Path $ProjectPath $DevlogPath
}
if (-not (Test-Path $DevlogResolved)) {
    throw "Devlog not found: $DevlogResolved"
}

if (-not $CaptureOutputDir) {
    $CaptureOutputDir = Join-Path $ProjectPath 'docs/devlog/screenshots'
}

$ToolsDir = Join-Path $ProjectPath 'tools'
$LogsDir = Join-Path $ToolsDir 'logs'
$BatchLogsDir = Join-Path $ProjectPath 'Logs'
if (-not (Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }
if (-not (Test-Path $BatchLogsDir)) { New-Item -ItemType Directory -Path $BatchLogsDir | Out-Null }

$Stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$CycleTag = "cycle-{0:D2}-{1}" -f $CycleNumber, $Stamp
$RunLog = Join-Path $LogsDir "$CycleTag.log"

$RunBuildSmoke = (-not $SkipBuild) -and ($BuildMethod -ne '')

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Run {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $RunLog -Value $line -Encoding utf8
}

function Append-File {
    param([string]$SrcPath, [string]$Header)
    Add-Content -Path $RunLog -Value "`n===== $Header =====" -Encoding utf8
    if (Test-Path $SrcPath) {
        Get-Content -Path $SrcPath -Encoding utf8 | Add-Content -Path $RunLog -Encoding utf8
    } else {
        Add-Content -Path $RunLog -Value "(file not found: $SrcPath)" -Encoding utf8
    }
}

function Expand-Template {
    param([string]$Template, [hashtable]$Vars)
    $out = $Template
    foreach ($k in $Vars.Keys) {
        $out = $out.Replace('{' + $k + '}', $Vars[$k])
    }
    return $out
}

# ---------------------------------------------------------------------------
# Plan summary
# ---------------------------------------------------------------------------

Write-Run "Cycle runner starting"
Write-Run "  CycleNumber    : $CycleNumber"
Write-Run "  ProjectPath    : $ProjectPath"
Write-Run "  BatchTool      : $BatchTool"
Write-Run "  ValidateMethod : $ValidateMethod"
Write-Run "  CaptureMethod  : $CaptureMethod"
if ($RunBuildSmoke) {
    Write-Run "  BuildMethod    : $BuildMethod"
} else {
    Write-Run "  BuildMethod    : (skipped)"
}
Write-Run "  Audience       : $Audience"
Write-Run "  CaptureOutDir  : $CaptureOutputDir"
Write-Run "  DevlogPath     : $DevlogResolved"
Write-Run "  SmokeSeconds   : $SmokeSeconds"
Write-Run "  SmokePatterns  : $SmokePatterns"
Write-Run "  CommitPath     : $($CommitPath -join '; ')"
Write-Run "  NoRollback     : $NoRollback"
Write-Run "  RunLog         : $RunLog"

if ($DryRun) {
    Write-Run "DryRun set; exiting without invoking batch tool or git."
    exit 0
}

# ---------------------------------------------------------------------------
# Phase invocation helpers
# ---------------------------------------------------------------------------

$env:CYCLE_AUDIENCE = $Audience
$env:CYCLE_NUMBER = "$CycleNumber"

function Invoke-Batch {
    param(
        [string]$PhaseName,
        [string]$Method,
        [string]$LogFile
    )
    Write-Run "Phase '$PhaseName' begin: $Method"
    $argString = Expand-Template -Template $BatchArgsTemplate -Vars @{
        projectPath = $ProjectPath
        method      = $Method
        logFile     = $LogFile
    }
    # Split expanded args while preserving double-quoted segments. The template is an
    # argument string, not a command line with an executable prefix, so do not drop
    # the first token.
    $argv = [regex]::Matches($argString, '("[^"]*"|\S+)') |
        ForEach-Object { $_.Value.Trim('"') }
    $proc = Start-Process -FilePath $BatchTool -ArgumentList $argv -PassThru -Wait -WindowStyle Hidden
    $exit = $proc.ExitCode
    Append-File -SrcPath $LogFile -Header "$PhaseName batch log ($LogFile)"
    if ($exit -ne 0) {
        Write-Run "Phase '$PhaseName' FAILED with exit $exit"
        return $false
    }
    Write-Run "Phase '$PhaseName' passed"
    return $true
}

function Rollback-AndReport {
    param([string]$PhaseName)
    if ($NoRollback) {
        Write-Run "NoRollback set; preserving worktree after $PhaseName failure"
    } else {
        Write-Run "Rolling back via 'git reset --hard HEAD' due to $PhaseName failure"
        Push-Location $ProjectPath
        try {
            git reset --hard HEAD | Out-Null
        } finally {
            Pop-Location
        }
    }
    $tail = ""
    if (Test-Path $RunLog) {
        $tail = (Get-Content $RunLog -Tail 80) -join "`n"
    }
    $failureText = @"

## Cycle $CycleNumber failure ($PhaseName) -- $Stamp

```
$tail
```
"@
    Add-Content -Path $DevlogResolved -Value $failureText -Encoding utf8
    Write-Run "Failure tail appended to devlog: $DevlogResolved"
}

# ---------------------------------------------------------------------------
# Phase 1: validate
# ---------------------------------------------------------------------------

$ValidateLog = Join-Path $BatchLogsDir "$CycleTag-validate.log"
if (-not (Invoke-Batch -PhaseName 'validate' -Method $ValidateMethod -LogFile $ValidateLog)) {
    Rollback-AndReport -PhaseName 'validate'
    exit 1
}

# ---------------------------------------------------------------------------
# Phase 2: capture
# ---------------------------------------------------------------------------

$CaptureLog = Join-Path $BatchLogsDir "$CycleTag-capture.log"
if (-not (Invoke-Batch -PhaseName 'capture' -Method $CaptureMethod -LogFile $CaptureLog)) {
    Rollback-AndReport -PhaseName 'capture'
    exit 1
}

# Audience prefix enforcement: if the capture method ignored CYCLE_AUDIENCE,
# prepend the prefix here to keep worker_/parent_review_ partitioning consistent.
if (Test-Path $CaptureOutputDir) {
    Get-ChildItem -Path $CaptureOutputDir -Recurse -Filter $CaptureFilter -File `
        | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) } `
        | Where-Object { $_.Name -notmatch '^(worker_|parent_review_)' } `
        | ForEach-Object {
            $newName = "{0}_{1}" -f $Audience, $_.Name
            $newPath = Join-Path $_.DirectoryName $newName
            if (Test-Path $newPath) { Remove-Item $newPath -Force }
            Move-Item -Path $_.FullName -Destination $newPath
            Write-Run "Renamed capture artifact for audience '$Audience': $($_.Name) -> $newName"
        }
}

# ---------------------------------------------------------------------------
# Phase 3: build
# ---------------------------------------------------------------------------

if ($RunBuildSmoke) {
    $BuildLog = Join-Path $BatchLogsDir "$CycleTag-build.log"
    if (-not (Invoke-Batch -PhaseName 'build' -Method $BuildMethod -LogFile $BuildLog)) {
        Rollback-AndReport -PhaseName 'build'
        exit 1
    }

    # Resolve the built artifact path.
    if (-not $BuildExe) {
        $match = Select-String -Path $BuildLog -Pattern $BuildArtifactPattern -AllMatches `
            | Select-Object -Last 1
        if ($match) {
            $BuildExe = $match.Matches[0].Groups[1].Value.Trim()
        }
    }
    if (-not $BuildExe -or -not (Test-Path $BuildExe)) {
        $BuildsDir = Join-Path $ProjectPath 'Builds'
        if (Test-Path $BuildsDir) {
            $candidate = Get-ChildItem -Path $BuildsDir -Recurse -Filter '*.exe' -File `
                | Sort-Object LastWriteTime -Descending `
                | Select-Object -First 1
            if ($candidate) { $BuildExe = $candidate.FullName }
        }
    }
    if (-not $BuildExe -or -not (Test-Path $BuildExe)) {
        Write-Run "Could not resolve built artifact (build log pattern + Builds/ scan both failed)"
        Rollback-AndReport -PhaseName 'build-artifact-resolve'
        exit 1
    }
    Write-Run "Resolved built artifact: $BuildExe"

    # ---------------------------------------------------------------------------
    # Phase 4: smoke
    # ---------------------------------------------------------------------------

    $SmokeLog = Join-Path $BatchLogsDir "$CycleTag-smoke.log"
    Write-Run "Phase 'smoke' begin: $BuildExe (run for $SmokeSeconds s)"

    $smokeArgString = Expand-Template -Template $SmokeArgsTemplate -Vars @{
        logFile = $SmokeLog
    }
    $smokeArgv = $smokeArgString -split ' '

    $proc = Start-Process -FilePath $BuildExe `
        -ArgumentList $smokeArgv `
        -PassThru -WindowStyle Hidden

    Start-Sleep -Seconds $SmokeSeconds

    if (-not $proc.HasExited) {
        try { Stop-Process -Id $proc.Id -Force } catch {}
    }

    Append-File -SrcPath $SmokeLog -Header "smoke log ($SmokeLog)"

    # Note: do not name this $matches -- that collides with the $Matches automatic variable.
    $smokeHits = @()
    if (Test-Path $SmokeLog) {
        $smokeHits = @(Select-String -Path $SmokeLog -Pattern $SmokePatterns)
    }
    if ($smokeHits.Count -gt 0) {
        Write-Run "Phase 'smoke' FAILED: $($smokeHits.Count) pattern hits"
        foreach ($m in ($smokeHits | Select-Object -First 20)) {
            Write-Run "  smoke hit: $($m.Line.Trim())"
        }
        Rollback-AndReport -PhaseName 'smoke'
        exit 1
    }
    Write-Run "Phase 'smoke' passed: 0 pattern hits"
} else {
    Write-Run "Build + smoke phases skipped (-SkipBuild set or no -BuildMethod)"
}

# ---------------------------------------------------------------------------
# Commit + push
# ---------------------------------------------------------------------------

$titleLine = (Get-Content $DevlogResolved -TotalCount 5 -Encoding utf8 `
    | Where-Object { $_ -match '^# ' } `
    | Select-Object -First 1)
if (-not $titleLine) {
    Write-Run "Could not find an H1 title line in devlog; aborting commit"
    exit 1
}
$commitSubject = ($titleLine -replace '^#\s+', '').Trim()

Push-Location $ProjectPath
try {
    $devlogRel = (Resolve-Path -Relative $DevlogResolved -ErrorAction SilentlyContinue)
    if (-not $devlogRel) { $devlogRel = $DevlogResolved }
    $commitBody = "Cycle $CycleNumber. Devlog: $devlogRel"

    # Write the commit message to a temp file and use -F to avoid PS native-arg quoting pitfalls.
    $msgFile = New-TemporaryFile
    Set-Content -Path $msgFile -Value "$commitSubject" -Encoding utf8
    Add-Content -Path $msgFile -Value "" -Encoding utf8
    Add-Content -Path $msgFile -Value "$commitBody" -Encoding utf8

    Write-Run "Committing: $commitSubject"
    if ($CommitPath -and $CommitPath.Count -gt 0) {
        foreach ($path in $CommitPath) {
            $stagePath = $path
            if ([System.IO.Path]::IsPathRooted($stagePath)) {
                $resolvedStagePath = Resolve-Path -LiteralPath $stagePath -ErrorAction SilentlyContinue
                if ($resolvedStagePath) {
                    $stagePath = Resolve-Path -Relative $resolvedStagePath.Path
                }
            }
            Write-Run "  staging path: $stagePath"
            git add -- "$stagePath"
            if ($LASTEXITCODE -ne 0) {
                Write-Run "git add failed for $stagePath (exit $LASTEXITCODE)"
                exit 1
            }
        }
    } else {
        git add -A
    }
    git commit -F $msgFile.FullName
    $commitExit = $LASTEXITCODE
    Remove-Item $msgFile -ErrorAction SilentlyContinue
    if ($commitExit -ne 0) {
        Write-Run "git commit failed (exit $commitExit)"
        exit 1
    }
    if (-not $SkipPush) {
        Write-Run "Pushing to origin"
        git push
        if ($LASTEXITCODE -ne 0) {
            Write-Run "git push failed (exit $LASTEXITCODE) -- commit is local; resolve and retry manually"
            exit 1
        }
    } else {
        Write-Run "SkipPush set; commit stayed local"
    }
} finally {
    Pop-Location
}

Write-Run "Cycle $CycleNumber completed cleanly"
exit 0
