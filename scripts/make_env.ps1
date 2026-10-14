# .env.example 을 읽어 .env 를 만든다 (로컬 docker compose 용).
#   - 이름에 PASSWORD / SECRET / KEY 가 들어가고 값이 빈 항목에 무작위 값을 넣는다.
#     PASSWORD: 영문·숫자 32자 (db/init/02-grants.sh 가 영문·숫자만 받는다)
#     SECRET·KEY: 32바이트 무작위 값의 Base64
#   - 나머지 줄(주석, 값이 있는 항목)은 그대로 옮긴다.
#   - 만든 값은 화면에 출력하지 않는다. 이미 .env 가 있으면 덮어쓰지 않고 멈춘다.
#
# 실행 (저장소 루트):  powershell -ExecutionPolicy Bypass -File scripts\make_env.ps1

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$examplePath = Join-Path $root '.env.example'
$envPath = Join-Path $root '.env'

if (Test-Path -LiteralPath $envPath) {
    Write-Host ".env 가 이미 있어서 그대로 둡니다. 새로 만들려면 .env 를 지우고 다시 실행하세요." -ForegroundColor Yellow
    Write-Host "(주의: MySQL 데이터가 이미 있으면 비밀번호가 맞지 않게 됩니다. 그때는 docker compose down -v 로 DB 도 다시 만드세요.)"
    exit 0
}
if (-not (Test-Path -LiteralPath $examplePath)) {
    throw ".env.example 을 찾을 수 없습니다: $examplePath"
}

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

function New-RandomBytes([int]$count) {
    $bytes = New-Object byte[] $count
    $rng.GetBytes($bytes)
    return ,$bytes
}

function New-RandomAlphaNumeric([int]$length) {
    # 62글자 중에서 고르되, 치우침이 없도록 248 이상인 바이트는 버린다 (248 = 62 * 4).
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $sb = New-Object System.Text.StringBuilder
    while ($sb.Length -lt $length) {
        foreach ($b in (New-RandomBytes 64)) {
            if ($b -lt 248 -and $sb.Length -lt $length) {
                [void]$sb.Append($chars[$b % 62])
            }
        }
    }
    return $sb.ToString()
}

$filled = New-Object System.Collections.Generic.List[string]
$lines = foreach ($line in [System.IO.File]::ReadAllLines($examplePath)) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*$') {
        $name = $Matches[1]
        if ($name -match 'PASSWORD') {
            $filled.Add($name)
            "$name=$(New-RandomAlphaNumeric 32)"
            continue
        }
        if ($name -match 'SECRET|KEY') {
            $filled.Add($name)
            "$name=$([Convert]::ToBase64String((New-RandomBytes 32)))"
            continue
        }
    }
    $line
}
$rng.Dispose()

# BOM 없는 UTF-8 로 저장 (docker compose 가 BOM 을 변수 이름의 일부로 읽지 않도록)
[System.IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ".env 를 만들었습니다. 무작위 값을 넣은 항목: $($filled -join ', ')" -ForegroundColor Green
Write-Host "(값은 출력하지 않습니다. .env 는 Git 에 올리지 마세요.)"
