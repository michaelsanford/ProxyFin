<#
.SYNOPSIS
    Non-mutating diagnostic verification script for proxyfin and Jellyfin public exposure.

.DESCRIPTION
    Audits the host environment, Docker containers, Windows Defender Firewall,
    public IPv4/IPv6 addresses vs Route53 DNS A/AAAA records, and TLS certificate
    health. This script is strictly read-only and does not modify any system state.

.PARAMETER Domain
    The fully qualified domain name to test (default: read from .env or jellyfin.example.com).

.PARAMETER LocalPort
    The local TCP port Jellyfin listens on (default: 8096).

.PARAMETER ProxyPort
    The external HTTPS proxy port (default: 443).

.PARAMETER SkipRemoteChecks
    Switch to skip public WAN, DNS, and remote TLS tests.

.EXAMPLE
    .\Verify-Setup.ps1
    .\Verify-Setup.ps1 -Domain "jellyfin.example.com"
#>

[CmdletBinding()]
param(
    [string]$Domain,
    [int]$LocalPort = 8096,
    [int]$ProxyPort = 443,
    [switch]$SkipRemoteChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# Output helpers
function Write-Header([string]$Text) {
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Write-CheckResult([string]$Status, [string]$Message, [string]$Guidance = "") {
    switch ($Status) {
        "PASS" { Write-Host "[PASS] " -ForegroundColor Green -NoNewline; Write-Host $Message }
        "WARN" { Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
        "FAIL" { Write-Host "[FAIL] " -ForegroundColor Red -NoNewline; Write-Host $Message }
        "INFO" { Write-Host "[INFO] " -ForegroundColor Blue -NoNewline; Write-Host $Message }
    }
    if ($Guidance) {
        Write-Host "       -> Guidance: $Guidance" -ForegroundColor DarkGray
    }
}

# 1. Load Environment Configuration
Write-Header "Configuration & Environment"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $scriptDir ".env"
$envConfig = @{}

if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $envConfig[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    Write-CheckResult "PASS" "Found .env file at $envFile"
} else {
    Write-CheckResult "WARN" ".env file not found at $envFile (using defaults)" "Copy .env.example to .env and insert your AWS credentials."
}

if (-not $Domain) {
    if ($envConfig.ContainsKey("DOMAIN") -and $envConfig["DOMAIN"]) {
        if ($envConfig.ContainsKey("SUBDOMAIN") -and $envConfig["SUBDOMAIN"]) {
            $Domain = "$($envConfig['SUBDOMAIN']).$($envConfig['DOMAIN'])"
        } else {
            $Domain = $envConfig["DOMAIN"]
            Write-CheckResult "WARN" "No SUBDOMAIN found in .env; testing bare DOMAIN '$Domain'." "Set SUBDOMAIN=your-host in .env if the proxy is served from a subdomain."
        }
    } else {
        $Domain = "jellyfin.example.com"
        Write-CheckResult "WARN" "No DOMAIN found in .env; using placeholder 'jellyfin.example.com'" "Set DOMAIN=your.domain.com and SUBDOMAIN=your-host in .env or pass -Domain parameter."
    }
}
Write-CheckResult "INFO" "Target domain: $Domain"

# Check AWS credentials placeholder
if ($envConfig.ContainsKey("AWS_ACCESS_KEY_ID")) {
    $key = $envConfig["AWS_ACCESS_KEY_ID"]
    if ($key -like "*YOUR_*" -or -not $key) {
        Write-CheckResult "WARN" "AWS_ACCESS_KEY_ID contains placeholder or empty value." "Ensure a valid AWS IAM access key for user 'proxyfin' is configured in .env."
    } else {
        Write-CheckResult "PASS" "AWS_ACCESS_KEY_ID is populated."
    }
}

# Check ddns.json (rendered by the ddns-config container from config\ddns.json.template)
$ddnsFile = Join-Path $scriptDir "data\ddns\config.json"
if (Test-Path $ddnsFile) {
    Write-CheckResult "PASS" "Found rendered ddns config at $ddnsFile"
} else {
    Write-CheckResult "WARN" "data\ddns\config.json not found." "Run 'docker compose up -d --build' to render it from config\ddns.json.template via the ddns-config service."
}

# 2. Local Jellyfin Service Check
Write-Header "Local Jellyfin Service (Port $LocalPort)"
$jellyfinListening = $false
try {
    $connections = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
    if ($connections) {
        $jellyfinListening = $true
        Write-CheckResult "PASS" "Port $LocalPort is open and listening locally on the host."
    } else {
        Write-CheckResult "WARN" "Nothing is currently listening on local port $LocalPort." "Ensure the Jellyfin server is started."
    }
} catch {
    Write-CheckResult "WARN" "Could not inspect local network connections: $_"
}

if ($jellyfinListening) {
    try {
        $jfUrl = "http://127.0.0.1:$LocalPort/System/Info/Public"
        $jfResp = Invoke-RestMethod -Uri $jfUrl -TimeoutSec 3 -ErrorAction Stop
        $serverName = $jfResp.ServerName
        $version = $jfResp.Version
        Write-CheckResult "PASS" "Jellyfin API responding. Server: '$serverName', Version: $version"
    } catch {
        Write-CheckResult "WARN" "Jellyfin port is listening, but public API request failed: $_" "Check Jellyfin server logs."
    }
}

# 3. Docker & Proxy Containers Check
Write-Header "Docker & Proxy Containers"
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $dockerCmd) {
    Write-CheckResult "FAIL" "Docker command not found in PATH." "Ensure Docker Desktop is installed and in PATH."
} else {
    Write-CheckResult "PASS" "Docker CLI is available."
    $dockerInfo = & docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-CheckResult "FAIL" "Docker daemon is not running or accessible." "Start Docker Desktop on Windows."
    } else {
        Write-CheckResult "PASS" "Docker daemon is running."
        
        # Check containers
        $containers = @("proxyfin-caddy", "proxyfin-ddns")
        foreach ($c in $containers) {
            $status = & docker inspect -f '{{.State.Status}}' $c 2>$null
            if ($LASTEXITCODE -eq 0 -and $status -eq "running") {
                Write-CheckResult "PASS" "Container '$c' is running."
            } else {
                Write-CheckResult "WARN" "Container '$c' is not running (Status: '$status')." "Run 'docker compose up -d --build' to start services."
            }
        }
    }
}

# 4. Windows Defender Firewall Check
Write-Header "Windows Defender Firewall"
try {
    $rules = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue
    $matchingRule = $null

    if ($rules) {
        foreach ($r in $rules) {
            $ports = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $r -ErrorAction SilentlyContinue
            if ($ports -and $ports.Protocol -eq "TCP" -and ($ports.LocalPort -contains "$ProxyPort")) {
                $matchingRule = $r
                break
            }
        }
    }

    if ($matchingRule) {
        Write-CheckResult "PASS" "Inbound firewall rule found allowing TCP port $ProxyPort ('$($matchingRule.DisplayName)')."
    } else {
        Write-CheckResult "WARN" "No explicit inbound rule found allowing TCP port $ProxyPort." "Run PowerShell as Admin: New-NetFirewallRule -DisplayName 'Proxyfin Reverse Proxy (HTTPS)' -Direction Inbound -LocalPort $ProxyPort -Protocol TCP -Action Allow"
    }
} catch {
    Write-CheckResult "WARN" "Could not inspect Windows Firewall rules (may require elevated permissions): $_"
}

# 5. Remote WAN, DNS, and TLS Checks
if (-not $SkipRemoteChecks) {
    Write-Header "Public WAN & Route53 DNS Resolution"
    
    # Get current public IPv4
    $publicIpv4 = $null
    try {
        $publicIpv4 = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5 -ErrorAction Stop).Trim()
        Write-CheckResult "PASS" "Detected host public IPv4: $publicIpv4"
    } catch {
        Write-CheckResult "WARN" "Could not detect public IPv4: $_"
    }

    # Get current public IPv6
    $publicIpv6 = $null
    try {
        $ipv6Resp = (Invoke-RestMethod -Uri "https://api64.ipify.org" -TimeoutSec 5 -ErrorAction Stop).Trim()
        if ($ipv6Resp -match ":") {
            $publicIpv6 = $ipv6Resp
            Write-CheckResult "PASS" "Detected host public IPv6: $publicIpv6"
        } else {
            Write-CheckResult "INFO" "No public IPv6 detected from host (ISP/Fizz router may not support IPv6 traversal)."
        }
    } catch {
        Write-CheckResult "INFO" "IPv6 query timed out or unavailable. (Standard on IPv4-only residential connections)."
    }

    # Resolve DNS A record
    try {
        $dnsA = Resolve-DnsName -Name $Domain -Type A -Server 1.1.1.1 -ErrorAction Stop
        $resolvedA = ($dnsA | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
        Write-CheckResult "INFO" "DNS A record for $Domain resolves to: $resolvedA"

        if ($publicIpv4 -and $resolvedA -eq $publicIpv4) {
            Write-CheckResult "PASS" "Route53 A record matches your current public IPv4 ($publicIpv4)."
        } elseif ($publicIpv4) {
            Write-CheckResult "WARN" "Route53 A record ($resolvedA) does not match public IPv4 ($publicIpv4)." "Allow ddns-updater time to sync, or check AWS credentials in .env."
        }
    } catch {
        Write-CheckResult "FAIL" "Failed to resolve DNS A record for ${Domain}: $_" "Ensure the A record exists in Route53 zone."
    }

    # Resolve DNS AAAA record
    try {
        $dnsAAAA = Resolve-DnsName -Name $Domain -Type AAAA -Server 1.1.1.1 -ErrorAction Stop
        $resolvedAAAA = ($dnsAAAA | Where-Object { $_.Type -eq 'AAAA' } | Select-Object -First 1).IPAddress
        Write-CheckResult "INFO" "DNS AAAA record for $Domain resolves to: $resolvedAAAA"

        if ($publicIpv6 -and $resolvedAAAA -eq $publicIpv6) {
            Write-CheckResult "PASS" "Route53 AAAA record matches current public IPv6 ($publicIpv6)."
        } elseif ($publicIpv6) {
            Write-CheckResult "WARN" "Route53 AAAA record ($resolvedAAAA) does not match public IPv6 ($publicIpv6)." "Verify ddns-updater IPv6 settings."
        }
    } catch {
        Write-CheckResult "INFO" "No DNS AAAA record found for $Domain." "Expected if IPv6 is not actively routed."
    }

    # 6. Remote TLS Certificate Audit
    Write-Header "Remote TLS Certificate & HTTPS Handshake"
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcpClient.ConnectAsync($Domain, $ProxyPort)
        if (-not $connectTask.Wait(5000)) {
            throw "TCP connection to ${Domain}:${ProxyPort} timed out after 5 seconds."
        }

        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, { param($s,$c,$ch,$e) return $true })
        $sslStream.AuthenticateAsClient($Domain)

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
        $issuer = $cert.Issuer
        $subject = $cert.Subject
        $validTo = [DateTime]::Parse($cert.GetExpirationDateString())
        $daysRemaining = ($validTo - (Get-Date)).Days

        Write-CheckResult "PASS" "TLS Handshake successful with $Domain"
        Write-CheckResult "INFO" "Certificate Issuer: $issuer"
        Write-CheckResult "INFO" "Certificate Subject: $subject"
        Write-CheckResult "INFO" "Valid until: $validTo ($daysRemaining days remaining)"

        if ($daysRemaining -le 0) {
            Write-CheckResult "FAIL" "TLS Certificate has EXPIRED!" "Check Caddy logs for Let's Encrypt renewal errors: docker logs proxyfin-caddy"
        } elseif ($daysRemaining -lt 30) {
            Write-CheckResult "WARN" "TLS Certificate expires in less than 30 days." "Caddy should automatically renew around 30 days before expiration."
        } else {
            Write-CheckResult "PASS" "TLS Certificate is healthy."
        }

        $sslStream.Close()
        $tcpClient.Close()

        # Check HTTPS API endpoint
        $httpsResp = Invoke-WebRequest -Uri "https://$Domain/System/Info/Public" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-CheckResult "PASS" "HTTPS endpoint reachable. HTTP Status: $($httpsResp.StatusCode)"

        # Check HSTS header
        $hstsHeader = $httpsResp.Headers["Strict-Transport-Security"]
        if ($hstsHeader) {
            Write-CheckResult "PASS" "HSTS Header detected: $hstsHeader"
        } else {
            Write-CheckResult "WARN" "Strict-Transport-Security header not returned by server." "Check Caddyfile header configuration."
        }
    } catch {
        Write-CheckResult "WARN" "Remote HTTPS check failed: $_" "Check if router port forwarding for TCP $ProxyPort is active and pointing to this PC's local IP."
    }
}

Write-Header "Diagnostic Verification Complete"
Write-Host "All checks completed without making any configuration changes.`n" -ForegroundColor DarkCyan
