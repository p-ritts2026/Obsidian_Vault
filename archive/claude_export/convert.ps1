param(
    [string[]]$OnlyNames = $null,   # trial mode: only convert conversations whose name is in this list
    [string]$OutDir = "inbox/claude_conversations",
    [int]$SummaryThreshold = 100     # conversations with more messages than this get a summary section
)

$ErrorActionPreference = "Stop"

function Sanitize-FileName($name) {
    $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[{0}]" -f [Regex]::Escape($invalid)
    $clean = [Regex]::Replace($name, $pattern, '_')
    $clean = $clean.Trim()
    if ($clean.Length -gt 80) { $clean = $clean.Substring(0, 80) }
    return $clean
}

function Get-ToolNames($contentBlocks) {
    $names = @()
    foreach ($c in $contentBlocks) {
        if ($c.type -eq 'tool_use' -and $c.name) { $names += $c.name }
    }
    return ($names | Select-Object -Unique)
}

function Format-Timestamp($ts) {
    if (-not $ts) { return "" }
    try {
        $dt = [DateTime]::Parse($ts, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        return $dt.ToString("yyyy-MM-dd HH:mm")
    } catch {
        return $ts
    }
}

# Build the body of one message: walk content blocks in order, emitting
# plain text as-is and expanding create_file tool_use blocks inline so the
# artifact Claude produced stays part of the readable transcript.
function Build-MessageBody($contentBlocks, $fallbackText) {
    $parts = @()
    foreach ($c in $contentBlocks) {
        if ($c.type -eq 'text' -and $c.text) {
            $parts += $c.text
        }
        elseif ($c.type -eq 'tool_use' -and $c.name -eq 'create_file') {
            $path = $c.input.path
            $fileText = $c.input.file_text
            if ($fileText) {
                $block = "**作成ファイル: ``$path``**`n`n" + '```markdown' + "`n$fileText`n" + '```'
                $parts += $block
            }
        }
    }
    if ($parts.Count -eq 0 -and $fallbackText) { $parts += $fallbackText }
    return ($parts -join "`n`n")
}

# Hand-written summaries for the long, iterative-debugging conversations
# (inserted under the frontmatter when a conversation exceeds $SummaryThreshold messages).
$Summaries = @{
    "動画編集マニュアルの構成と進め方" = @(
        "- お笑いサークル向け動画編集マニュアル（Premiere Pro + DaVinci Resolve）の構成を対話しながら設計。"
        "- Part0（準備）〜Part5（困ったときに）まで、章ごとに内容を確認・修正しながら執筆。音量調整・暗転処理・トランジションなど実務手順を細かく反映。"
        "- 最終的にWordファイル化し、さらに体言止めのスライド形式にも整形して完成。"
    ) -join "`n"

    "MediaPipe鼻座標でTouchDesignerカメラ制御" = @(
        "- TouchDesignerでMediaPipeの鼻・耳座標からカメラのPan/Dolly制御を実装し、細かいバグ修正とパラメータ調整を反復。"
        "- 空間音響（HRTF風の左右差・距離減衰）を実装し、インタラクション対象のモチーフを「カエル」に決定。"
        "- 実装効率を優先し、TouchDesignerからUnity（Virtual-Showcaseベース）への移行を決断、視点追従の再実装に着手。"
        "- 会話が長くなったため、次チャットへの引き継ぎ用要約の作成を依頼して終了。"
    ) -join "`n"

    "Virtual-Showcaseプロジェクトの次フェーズ準備" = @(
        "- 前チャットからの引き継ぎで開始。カエル3Dモデルの軽量化（Blenderでのデシメート）・配置・Deformパッケージによるタッチ変形を実装。"
        "- Steam Audioによる空間音響（左右差・距離減衰・頭部方向連動）を調整。"
        "- ハーフミラー投影用の上下反転表示処理（Shader/Canvas）を試行錯誤の末に実装。"
        "- Leap Motionでの接触インタラクション統合中にドライバ互換性・フレームレート低下の問題に直面。"
        "- 会話上限のため次チャットへ引き継ぎ、大学院口頭試問向け研究報告書作成へ話題が移り終了。"
    ) -join "`n"
}

$json = Get-Content -Raw "inbox/claude_export/conversations.json" | ConvertFrom-Json

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$results = @()

foreach ($conv in $json) {
    if ($OnlyNames -and ($OnlyNames -notcontains $conv.name)) { continue }

    $date = ""
    if ($conv.created_at) { $date = $conv.created_at.Substring(0,10) }
    $titleSafe = Sanitize-FileName $conv.name
    $fileName = "${date}_${titleSafe}.md"
    $filePath = Join-Path $OutDir $fileName

    $msgCount = 0
    if ($conv.chat_messages) { $msgCount = $conv.chat_messages.Count }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("title: `"$($conv.name)`"")
    [void]$sb.AppendLine("created: $($conv.created_at)")
    [void]$sb.AppendLine("updated: $($conv.updated_at)")
    [void]$sb.AppendLine("source: claude_export/conversations.json")
    [void]$sb.AppendLine("uuid: $($conv.uuid)")
    [void]$sb.AppendLine("message_count: $msgCount")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# $($conv.name)")
    [void]$sb.AppendLine("")

    if ($msgCount -gt $SummaryThreshold -and $Summaries.ContainsKey($conv.name)) {
        [void]$sb.AppendLine("## 要約")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine($Summaries[$conv.name])
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("---")
        [void]$sb.AppendLine("")
    }

    if ($msgCount -eq 0) {
        [void]$sb.AppendLine("_(メッセージなし)_")
    }

    foreach ($m in $conv.chat_messages) {
        $speaker = if ($m.sender -eq 'human') { "あなた" } else { "Claude" }
        $ts = Format-Timestamp $m.created_at
        [void]$sb.AppendLine("## $speaker  _(${ts})_")
        [void]$sb.AppendLine("")

        $toolNames = Get-ToolNames $m.content
        if ($toolNames.Count -gt 0) {
            [void]$sb.AppendLine("*(ツール使用: $($toolNames -join ', '))*")
            [void]$sb.AppendLine("")
        }

        $text = Build-MessageBody $m.content $m.text
        if (-not $text) { $text = "_(テキストなし)_" }
        [void]$sb.AppendLine($text)
        [void]$sb.AppendLine("")

        $attachedFiles = @()
        if ($m.attachments) { $attachedFiles += $m.attachments }
        if ($m.files) { $attachedFiles += $m.files }
        if ($attachedFiles.Count -gt 0) {
            $names = $attachedFiles | ForEach-Object { $_.file_name }
            [void]$sb.AppendLine("*(添付ファイル: $($names -join ', '))*")
            [void]$sb.AppendLine("")
        }

        [void]$sb.AppendLine("---")
        [void]$sb.AppendLine("")
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($filePath, $sb.ToString(), $utf8NoBom)
    $results += [PSCustomObject]@{ File = $filePath; Messages = $msgCount }
}

$results | Format-Table -AutoSize
