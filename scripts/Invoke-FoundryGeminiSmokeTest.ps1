<#
.SYNOPSIS
    Runs an end-to-end smoke test against a Google Gemini BYOM connection in Microsoft Foundry.

.DESCRIPTION
    Authenticates via Azure CLI ('az login'), creates an ephemeral Prompt Agent targeting
    '<ConnectionName>/<ModelName>', invokes the Foundry Responses API, prints latency and
    token telemetry, and removes the temporary agent version in a finally block.

.EXAMPLE
    .\scripts\Invoke-FoundryGeminiSmokeTest.ps1 `
        -ProjectEndpoint "https://<your-foundry-resource>.services.ai.azure.com/api/projects/<your-project-name>" `
        -ConnectionName "gemini-byom" `
        -ModelName "gemini-3.5-flash-lite"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://.+\.services\.ai\.azure\.com/api/projects/.+$')]
    [string]$ProjectEndpoint,

    [Parameter(Mandatory = $false)]
    [string]$ConnectionName = "gemini-byom",

    [Parameter(Mandatory = $false)]
    [string]$ModelName = "gemini-3.5-flash-lite",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"

$ProjectBase = $ProjectEndpoint.TrimEnd('/')
$FullModel = "$ConnectionName/$ModelName"
$AgentName = "gemini-byom-smoke-test"
$CreatedVersion = $null

Write-Host "Acquiring Microsoft Foundry Entra ID token via Azure CLI..." -ForegroundColor Cyan
$Token = (& az account get-access-token --resource "https://ai.azure.com" --query accessToken -o tsv)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Token)) {
    throw "Failed to acquire access token. Run 'az login' and ensure your account has the 'Azure AI User' role."
}

$Headers = @{
    Authorization  = "Bearer $Token"
    "Content-Type" = "application/json"
}

try {
    Write-Host "Creating temporary Prompt Agent '$AgentName' -> '$FullModel'..." -ForegroundColor Cyan
    $CreateBody = @{
        description = "Temporary smoke-test agent for Gemini BYOM verification"
        definition  = @{
            kind         = "prompt"
            model        = $FullModel
            instructions = "Reply concisely in one short sentence."
        }
    } | ConvertTo-Json -Depth 6

    $Created = Invoke-RestMethod `
        -Method Post `
        -Uri "$ProjectBase/agents/$AgentName/versions?api-version=v1" `
        -Headers $Headers `
        -Body $CreateBody

    $CreatedVersion = $Created.version
    Write-Host "Created '$($Created.name)' v$CreatedVersion. Sending test prompt..." -ForegroundColor Cyan

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $InvokeBody = @{
        input           = "Ping! Confirm in one short sentence that you are $ModelName responding via Microsoft Foundry."
        agent_reference = @{
            name = $AgentName
            type = "agent_reference"
        }
    } | ConvertTo-Json -Depth 6

    $Response = Invoke-RestMethod `
        -Method Post `
        -Uri "$ProjectBase/openai/responses?api-version=2025-05-15-preview" `
        -Headers $Headers `
        -Body $InvokeBody `
        -TimeoutSec $TimeoutSeconds
    $Stopwatch.Stop()

    $ReplyText = ""
    foreach ($item in @($Response.output)) {
        if ($item.type -eq "message") {
            foreach ($block in @($item.content)) {
                if ($block.text) { $ReplyText += $block.text }
            }
        }
    }

    Write-Host "`nSUCCESS in $($Stopwatch.ElapsedMilliseconds) ms (status: $($Response.status))" -ForegroundColor Green
    Write-Host "Model : $($Response.model)"
    Write-Host "Reply : $ReplyText"
    if ($Response.usage) {
        Write-Host "Usage : input=$($Response.usage.input_tokens), output=$($Response.usage.output_tokens), total=$($Response.usage.total_tokens)"
    }
}
catch {
    $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "N/A" }
    Write-Host "`nSMOKE TEST FAILED (HTTP $StatusCode)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) {
        Write-Host $_.ErrorDetails.Message -ForegroundColor Yellow
    }
    throw
}
finally {
    if ($CreatedVersion) {
        Invoke-RestMethod `
            -Method Delete `
            -Uri "$ProjectBase/agents/$AgentName/versions/$($CreatedVersion)?api-version=v1" `
            -Headers $Headers `
            -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Cleaned up temporary agent '$AgentName' v$CreatedVersion." -ForegroundColor DarkGray
    }
}
