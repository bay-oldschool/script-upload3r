param(
    [Parameter(Mandatory)][string]$promptfile,
    [Parameter(Mandatory)][string]$outputfile,
    [string]$apikey = "",
    [string]$model = "gemini-2.5-flash-lite",
    [ValidateSet("gemini","ollama")][string]$provider = "gemini",
    [string]$baseurl = "http://localhost:11434",
    [string]$systemfile = ""
)

$prompt = [System.IO.File]::ReadAllText($promptfile, [System.Text.Encoding]::UTF8)
$sysText = ""
if ($systemfile -and (Test-Path $systemfile)) {
    $sysText = [System.IO.File]::ReadAllText($systemfile, [System.Text.Encoding]::UTF8)
}

if ($provider -eq "ollama") {
    $url = "$baseurl/api/chat"
    $messages = @()
    if ($sysText) {
        $messages += @{ role = "system"; content = $sysText }
    }
    # Qwen3 models have thinking mode on by default — disable it with /no_think
    if ($model -match '^qwen3') {
        $prompt += "`n/no_think"
    }
    $messages += @{ role = "user"; content = $prompt }
    $bodyObj = @{ model = $model; messages = $messages; stream = $false }
    # ConvertTo-Json with high depth; -Compress removes whitespace
    $json = $bodyObj | ConvertTo-Json -Depth 10 -Compress
} else {
    $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apikey}"
    # Gemini: manual JSON escaping (ConvertTo-Json in PS5.1 breaks emoji surrogate pairs)
    $escapedPrompt = $prompt.Replace('\', '\\').Replace('"', '\"').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`t", '\t')
    if ($sysText) {
        $escapedSys = $sysText.Replace('\', '\\').Replace('"', '\"').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`t", '\t')
        $json = '{"system_instruction":{"parts":[{"text":"' + $escapedSys + '"}]},"contents":[{"parts":[{"text":"' + $escapedPrompt + '"}]}]}'
    } else {
        $json = '{"contents":[{"parts":[{"text":"' + $escapedPrompt + '"}]}]}'
    }
}

$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

try {
    $webRequest = [System.Net.HttpWebRequest]::Create($url)
    $webRequest.Method = "POST"
    $webRequest.ContentType = "application/json; charset=utf-8"
    $webRequest.ContentLength = $bytes.Length
    if ($provider -eq "ollama") {
        $webRequest.Timeout = 600000
        $webRequest.ReadWriteTimeout = 600000
    }
    $stream = $webRequest.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()

    $response = $webRequest.GetResponse()
    $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $responseText = $reader.ReadToEnd()
    $reader.Close()
    $response.Close()

    $parsed = $responseText | ConvertFrom-Json
    if ($provider -eq "ollama") {
        $text = $parsed.message.content
    } else {
        if ($parsed.error) {
            Write-Host "Error: $($parsed.error.message)" -ForegroundColor Red
            exit 1
        }
        $text = $parsed.candidates[0].content.parts[0].text
    }

    # Strip <think>...</think> blocks (qwen3 thinking mode leakage)
    $text = [regex]::Replace($text, '(?s)<think>.*?</think>\s*', '')

    if (-not $text) {
        Write-Warning "$provider returned empty response (skipped)"
        exit 0
    }

    Write-Host $text
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outputfile, $text, $utf8NoBom)
} catch {
    if ($_.Exception.Response) {
        $errReader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $errBody = $errReader.ReadToEnd()
        Write-Warning "$provider API error (skipped): $errBody"
    } else {
        Write-Warning "$provider API error (skipped): $($_.Exception.Message)"
    }
    exit 0
}
