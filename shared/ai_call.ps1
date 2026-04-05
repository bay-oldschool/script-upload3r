param(
    [Parameter(Mandatory)][string]$promptfile,
    [Parameter(Mandatory)][string]$outputfile,
    [string]$apikey = "",
    [string]$model = "gemini-2.5-flash-lite",
    [ValidateSet("gemini","ollama","groq","grok","cerebras","sambanova","openrouter","huggingface")][string]$provider = "gemini",
    [string]$baseurl = "http://localhost:11434",
    [string]$systemfile = ""
)

$prompt = [System.IO.File]::ReadAllText($promptfile, [System.Text.Encoding]::UTF8)
$sysText = ""
if ($systemfile -and (Test-Path $systemfile)) {
    $sysText = [System.IO.File]::ReadAllText($systemfile, [System.Text.Encoding]::UTF8)
}

# Manual JSON string escaping (PS5.1 ConvertTo-Json breaks emoji surrogate pairs)
function Escape-JsonString($s) {
    $s.Replace('\', '\\').Replace('"', '\"').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`t", '\t')
}

# Qwen3 models have thinking mode on by default — disable it with /no_think
if ($model -match 'qwen3') {
    $prompt += "`n/no_think"
}

# OpenAI-compatible provider URLs
$openaiUrls = @{
    groq       = "https://api.groq.com/openai/v1/chat/completions"
    grok       = "https://api.x.ai/v1/chat/completions"
    cerebras   = "https://api.cerebras.ai/v1/chat/completions"
    sambanova  = "https://api.sambanova.ai/v1/chat/completions"
    openrouter = "https://openrouter.ai/api/v1/chat/completions"
    huggingface = "https://api-inference.huggingface.co/models/$model/v1/chat/completions"
}

if ($provider -eq "ollama") {
    $url = "$baseurl/api/chat"
    $messages = @()
    if ($sysText) {
        $messages += @{ role = "system"; content = $sysText }
    }
    $messages += @{ role = "user"; content = $prompt }
    $bodyObj = @{ model = $model; messages = $messages; stream = $false }
    $json = $bodyObj | ConvertTo-Json -Depth 10 -Compress
} elseif ($openaiUrls.ContainsKey($provider)) {
    $url = $openaiUrls[$provider]
    # Build JSON manually to preserve emoji surrogate pairs
    $escapedPrompt = Escape-JsonString $prompt
    $msgArray = ''
    if ($sysText) {
        $escapedSys = Escape-JsonString $sysText
        $msgArray = '[{"role":"system","content":"' + $escapedSys + '"},{"role":"user","content":"' + $escapedPrompt + '"}]'
    } else {
        $msgArray = '[{"role":"user","content":"' + $escapedPrompt + '"}]'
    }
    $json = '{"model":"' + (Escape-JsonString $model) + '","messages":' + $msgArray + '}'
} else {
    # Gemini
    $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apikey}"
    $escapedPrompt = Escape-JsonString $prompt
    if ($sysText) {
        $escapedSys = Escape-JsonString $sysText
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
    if ($provider -ne "ollama" -and $provider -ne "gemini") {
        $webRequest.Headers.Add("Authorization", "Bearer $apikey")
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
    } elseif ($provider -eq "gemini") {
        if ($parsed.error) {
            Write-Host "Error: $($parsed.error.message)" -ForegroundColor Red
            exit 1
        }
        $text = $parsed.candidates[0].content.parts[0].text
    } else {
        # OpenAI-compatible response (groq, grok, cerebras, sambanova, openrouter, huggingface)
        if ($parsed.error) {
            Write-Host "Error: $($parsed.error.message)" -ForegroundColor Red
            exit 1
        }
        $text = $parsed.choices[0].message.content
    }

    # Strip <think>...</think> blocks (qwen3 thinking mode leakage)
    $text = [regex]::Replace($text, '(?s)<think>.*?</think>\s*', '')

    # Strip markdown formatting that AI may produce despite instructions
    # Convert **text** to [b]text[/b]
    $text = [regex]::Replace($text, '\*\*([^*]+)\*\*', '[b]$1[/b]')
    # Remove leading * or - list markers
    $text = [regex]::Replace($text, '(?m)^\s*[\*\-]\s+', '')

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
