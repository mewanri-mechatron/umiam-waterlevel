# Keep readings from today 00:00 local onward; delete older from Firebase RTDB.
$ErrorActionPreference = 'Stop'
$apiKey = 'AIzaSyBHAQdfBcowfRfcEga0eqC95ADL-9KXtYM'
$db = 'https://umiam-waterlevel-default-rtdb.asia-southeast1.firebasedatabase.app'
$stationId = 'station_001'
$startLocal = Get-Date -Year 2026 -Month 11 -Day 20 -Hour 0 -Minute 0 -Second 0
$cutoff = [DateTimeOffset]::new($startLocal).ToUnixTimeSeconds()

Write-Host "Cutoff (local midnight): $startLocal  epoch=$cutoff"

$authResp = Invoke-WebRequest `
  -Uri "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$apiKey" `
  -Method POST `
  -ContentType 'application/json; charset=UTF-8' `
  -Body '{"returnSecureToken":true}' `
  -UseBasicParsing
$auth = $authResp.Content | ConvertFrom-Json
$token = $auth.idToken
if (-not $token) { throw 'Anonymous auth failed' }
Write-Host 'Auth OK'

$root = Invoke-RestMethod -Uri "$db/water/readings/$stationId.json"
if ($null -eq $root) {
  Write-Host 'No readings node.'
  exit 0
}

$toDelete = New-Object System.Collections.Generic.List[string]
$keptRows = @()
foreach ($prop in $root.PSObject.Properties) {
  $key = $prop.Name
  $row = $prop.Value
  $mt = 0
  if ($null -ne $row.measurement_time) { $mt = [int64]$row.measurement_time }
  if ($mt -lt $cutoff) {
    [void]$toDelete.Add($key)
  } else {
    $keptRows += ,@{ key = $key; row = $row; mt = $mt }
  }
}

Write-Host "Delete $($toDelete.Count) · keep $($keptRows.Count)"

# Multi-path null updates in chunks (faster than one DELETE each).
$chunkSize = 200
for ($i = 0; $i -lt $toDelete.Count; $i += $chunkSize) {
  $chunk = $toDelete.GetRange($i, [Math]::Min($chunkSize, $toDelete.Count - $i))
  $patch = @{}
  foreach ($key in $chunk) {
    $patch["water/readings/$stationId/$key"] = $null
  }
  $json = $patch | ConvertTo-Json -Compress -Depth 5
  Invoke-WebRequest `
    -Uri "$db/.json?auth=$token" `
    -Method PATCH `
    -ContentType 'application/json; charset=UTF-8' `
    -Body $json `
    -UseBasicParsing | Out-Null
  Write-Host ("Patched {0}/{1}" -f [Math]::Min($i + $chunkSize, $toDelete.Count), $toDelete.Count)
}

$latest = $null
foreach ($k in $keptRows) {
  if ($null -eq $latest -or $k.mt -gt $latest.mt) { $latest = $k }
}
if ($null -ne $latest) {
  $body = $latest.row | ConvertTo-Json -Depth 8 -Compress
  Invoke-WebRequest `
    -Uri "$db/water/latest/$stationId.json?auth=$token" `
    -Method PUT `
    -ContentType 'application/json; charset=UTF-8' `
    -Body $body `
    -UseBasicParsing | Out-Null
  Write-Host "Updated water/latest/$stationId"
} else {
  Invoke-WebRequest `
    -Uri "$db/water/latest/$stationId.json?auth=$token" `
    -Method DELETE `
    -UseBasicParsing | Out-Null
  Write-Host "Cleared water/latest/$stationId"
}

Write-Host "Done. Deleted=$($toDelete.Count) Kept=$($keptRows.Count)"
