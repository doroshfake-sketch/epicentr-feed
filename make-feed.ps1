# Генерує XML-фід для автооновлення наявності й цін на Епіцентрі із залишків KeyCRM.
# Ключ API: змінна середовища KEYCRM_API_KEY.
# Використання: powershell -File make-feed.ps1 -Out epicentr.xml
param(
    [string]$Out = "epicentr.xml"
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$key = $env:KEYCRM_API_KEY
if (-not $key) { throw "Не задано KEYCRM_API_KEY" }
$headers = @{ Authorization = "Bearer $key"; Accept = 'application/json' }

# Артикули, які не чіпаємо (як у навичці pereoblik-epicentr)
$ignore = @('350-23-41','h202-9-42','h202-9-43','8896-5-41','st8080-16')

function Get-Page([int]$page) {
    $url = "https://openapi.keycrm.app/v1/offers/stocks?limit=50&page=$page"
    for ($try = 1; $try -le 6; $try++) {
        try { return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60 }
        catch {
            if ($try -eq 6) { throw }
            Start-Sleep -Seconds (5 * $try)
        }
    }
}

$all = New-Object System.Collections.Generic.List[object]
$page = 1
do {
    $r = Get-Page $page
    foreach ($o in $r.data) { $all.Add($o) }
    $last = [int]$r.last_page
    $page++
    Start-Sleep -Milliseconds 1100   # ліміт KeyCRM ~60 запитів/хв
} while ($page -le $last)

# Збираємо пропозиції: артикул -> (доступно, ціна)
$offers = [ordered]@{}
function Add-Offer($sku, $avail, $price) {
    $k = $sku.ToLowerInvariant()
    if ($ignore -contains $k) { return }
    if ($offers.Contains($k)) {
        # дубль артикула: беремо той, де більше доступно
        if ($avail -le $offers[$k].avail) { return }
    }
    $offers[$k] = [pscustomobject]@{ sku = $sku; avail = $avail; price = $price }
}

foreach ($o in $all) {
    $sku = ([string]$o.sku).Trim()
    if (-not $sku) { continue }
    if ($sku -match '\s') { continue }            # Епіцентр не приймає артикули з пробілами
    $price = [double]$o.price
    if ($price -le 0) { continue }
    $avail = [double]$o.quantity - [double]$o.reserve
    Add-Offer $sku $avail $price
    # На Епіцентрі моделі M370 записані як 370-x-y
    if ($sku -match '^[Mm](370-.+)$') { Add-Offer $Matches[1] $avail $price }
}

$inv = [Globalization.CultureInfo]::InvariantCulture
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sb.AppendLine('<yml_catalog date="' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + '">')
[void]$sb.AppendLine('<offers>')
foreach ($x in $offers.Values) {
    $id = [Security.SecurityElement]::Escape($x.sku)
    $isAv = $x.avail -gt 0
    $a = if ($isAv) { 'true' } else { 'false' }
    $st = if ($isAv) { 'in_stock' } else { 'out_of_stock' }
    $p = $x.price.ToString('0.##', $inv)
    [void]$sb.AppendLine("<offer id=`"$id`" available=`"$a`"><price>$p</price><availability>$st</availability></offer>")
}
[void]$sb.AppendLine('</offers>')
[void]$sb.AppendLine('</yml_catalog>')

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path (Get-Location) $Out), $sb.ToString(), $utf8)
$inStock = @($offers.Values | Where-Object { $_.avail -gt 0 }).Count
Write-Output "Готово: $($offers.Count) товарів у фіді, з них в наявності $inStock (з KeyCRM отримано $($all.Count))"
