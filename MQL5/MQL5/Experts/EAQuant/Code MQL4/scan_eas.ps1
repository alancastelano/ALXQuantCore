# EA Scanner - Classify MQ4 Expert Advisors
# Strategy: Trend|MeanReversal|Breakout|GridMartingale|Scalping|MultiStrategy
# Class: A (75-100) | B (50-74) | C (0-49)

$eaPath = "C:\ALXQuant\MQL5\MQL5\Experts\EAQuant\Code MQL4\EAs"
$jsonOut = "C:\ALXQuant\MQL5\MQL5\Experts\EAQuant\Code MQL4\ea_classification.json"
$csvOut = "C:\ALXQuant\MQL5\MQL5\Experts\EAQuant\Code MQL4\ea_classification.csv"

$files = Get-ChildItem $eaPath -Filter "*.mq4" -File
$results = @()

foreach($f in $files) {
    $lines = Get-Content $f.FullName -First 100 -ErrorAction SilentlyContinue
    if($null -eq $lines) { continue }
    $joined = $lines -join "`n"
    $joinedLower = $joined.ToLower()

    # --- STRATEGY DETECTION ---
    $strategy = "Unknown"
    $stratScore = 0

    # Trend indicators
    $hasMA = $joinedLower -match '(iMA\(|moving.?average|ema|sma|wma)'
    $hasADX = $joinedLower -match '(iADX\(|adx)'
    $hasMACD = $joinedLower -match '(iMACD\(|macd)'
    $hasIchimoku = $joinedLower -match '(ichimoku|iIchimoku)'
    $trendIndicators = @($hasMA, $hasADX, $hasMACD, $hasIchimoku) | Where-Object { $_ }
    $trendCount = $trendIndicators.Count

    # Mean Reversal indicators
    $hasRSI = $joinedLower -match '(iRSI\(|rsi)'
    $hasStoch = $joinedLower -match '(iStochastic\(|stoch)'
    $hasCCI = $joinedLower -match '(iCCI\(|cci)'
    $hasBollinger = $joinedLower -match '(iBands\(|bollinger)'
    $hasDeMarker = $joinedLower -match '(iDeMarker\(|demarker)'
    $reversalIndicators = @($hasRSI, $hasStoch, $hasCCI, $hasBollinger, $hasDeMarker) | Where-Object { $_ }
    $reversalCount = $reversalIndicators.Count

    # Breakout indicators
    $hasFractals = $joinedLower -match '(iFractals\(|fractal)'
    $hasPivot = $joinedLower -match '(pivot|iPivot)'
    $hasDonchian = $joinedLower -match '(donchian|channel)'
    $hasBreakout = $joinedLower -match '(breakout|break.?out|straddle|pending.?order|buystop|sellstop)'
    $breakoutCount = @($hasFractals, $hasPivot, $hasDonchian, $hasBreakout) | Where-Object { $_ }.Count

    # Grid/Martingale
    $hasGrid = $joinedLower -match '(grid|pipsstep|pip.?step|gridstep)'
    $hasMartingale = $joinedLower -match '(martingale|lot.?multipl|lotmultipl|marti|doubling|averaging)'
    $hasAntiMart = $joinedLower -match '(anti.?mart|safe.?mode|equity.?stop|max.?drawdown)'
    $gridMartCount = @($hasGrid, $hasMartingale) | Where-Object { $_ }.Count

    # Scalping
    $hasScalping = $joinedLower -match '(scalp|scalper|pips?.?target|small.?profit|fast.?close|trailing)'
    $hasMomentum = $joinedLower -match '(momentum|breakout.?bar|average.?bar|candle.?body|ExpBar)'
    $scalpCount = @($hasScalping, $hasMomentum) | Where-Object { $_ }.Count

    # Multi-strategy
    $strategyTypes = @()
    if($trendCount -ge 2) { $strategyTypes += "Trend" }
    if($reversalCount -ge 2) { $strategyTypes += "MeanReversal" }
    if($breakoutCount -ge 2) { $strategyTypes += "Breakout" }
    if($gridMartCount -ge 1) { $strategyTypes += "GridMartingale" }
    if($scalpCount -ge 1) { $strategyTypes += "Scalping" }

    if($strategyTypes.Count -ge 2) {
        $strategy = "MultiStrategy"
    } elseif($strategyTypes.Count -eq 1) {
        $strategy = $strategyTypes[0]
    } else {
        # Fallback: check what's most prominent
        if($hasGrid -or $hasMartingale) { $strategy = "GridMartingale" }
        elseif($hasScalping -or $hasMomentum) { $strategy = "Scalping" }
        elseif($trendCount -ge 1) { $strategy = "Trend" }
        elseif($reversalCount -ge 1) { $strategy = "MeanReversal" }
        elseif($hasBreakout) { $strategy = "Breakout" }
        else { $strategy = "Unknown" }
    }

    # --- CODE QUALITY ---
    $codeQuality = "clean"
    $qualityPenalty = 0

    # Check for obfuscation
    $obfuscatedPatterns = @('G_d_', 'G_v_', 'I_i_', 'I_v_', 'Id_', 'Gd_', 'Gi_', 'Gg_', 'Gk_')
    $obfuscatedCount = 0
    foreach($pat in $obfuscatedPatterns) {
        $obfuscatedCount += ([regex]::Matches($joined, $pat)).Count
    }
    if($obfuscatedCount -gt 10) {
        $codeQuality = "obfuscated"
        $qualityPenalty = 30
    } elseif($obfuscatedCount -gt 3) {
        $codeQuality = "partially_obfuscated"
        $qualityPenalty = 15
    }

    # Check for comments (good sign)
    $hasComments = $joined -match '(//|/\*|copyright|author)'
    # Check for function names
    $functionCount = ([regex]::Matches($joined, '(void|int|double|bool|string)\s+\w+\(')).Count

    # --- RISK MANAGEMENT ---
    $hasSL = $joinedLower -match '(stoploss|stop.?loss|sl\b|equitystop|equity.?stop)'
    $hasTP = $joinedLower -match '(takeprofit|take.?profit|tp\b|target.?profit)'
    $hasTrailing = $joinedLower -match '(trailing|tral\b|trail)'
    $hasMaxSpread = $joinedLower -match '(maxspread|max.?spread|spread.?filter)'
    $hasMaxSlippage = $joinedLower -match '(maxslippage|slippage)'
    $hasEquityStop = $joinedLower -match '(equitystop|equity.?stop|balance.?stop|account.?stop)'
    $hasMaxOrders = $joinedLower -match '(maxorders|max.?orders|max.?trades|level.?limit)'
    $hasMoneyMgmt = $joinedLower -match '(money.?manag|risk.?per.?lot|riskpercent|lot.?risk|autolot|auto.?lot)'
    $hasTimeFilter = $joinedLower -match '(time.?filter|session|hour.?start|hour.?end|trade.?hour|trading.?hour)'
    $hasFridayFilter = $joinedLower -match '(friday|trade.?friday|close.?friday)'

    $riskScore = 0
    if($hasSL) { $riskScore += 2 }
    if($hasTP) { $riskScore += 2 }
    if($hasTrailing) { $riskScore += 2 }
    if($hasMaxSpread) { $riskScore += 1 }
    if($hasMaxSlippage) { $riskScore += 1 }
    if($hasEquityStop) { $riskScore += 2 }
    if($hasMaxOrders) { $riskScore += 1 }
    if($hasMoneyMgmt) { $riskScore += 2 }
    if($hasTimeFilter) { $riskScore += 1 }
    if($hasFridayFilter) { $riskScore += 1 }

    # --- SCORING (0-100, calibrated for bell curve) ---
    $totalScore = 0

    # Strategy clarity (0-20)
    if($strategy -ne "Unknown") { $totalScore += 12 }
    if($strategyTypes.Count -ge 2) { $totalScore += 5 }
    if($strategyTypes.Count -ge 3) { $totalScore += 3 }

    # Risk management (0-30)
    if($hasSL) { $totalScore += 6 }
    if($hasTP) { $totalScore += 5 }
    if($hasTrailing) { $totalScore += 4 }
    if($hasEquityStop) { $totalScore += 5 }
    if($hasMaxSpread) { $totalScore += 3 }
    if($hasMaxSlippage) { $totalScore += 2 }
    if($hasMaxOrders) { $totalScore += 3 }
    if($hasMoneyMgmt) { $totalScore += 4 }

    # Code quality (0-25)
    if($codeQuality -eq "clean") { $totalScore += 18 }
    elseif($codeQuality -eq "partially_obfuscated") { $totalScore += 8 }
    else { $totalScore += 0 }
    if($hasComments) { $totalScore += 4 }
    if($functionCount -gt 10) { $totalScore += 3 }
    elseif($functionCount -gt 5) { $totalScore += 1 }

    # Strategy complexity (0-15)
    if($trendCount -ge 2) { $totalScore += 6 }
    elseif($trendCount -ge 1) { $totalScore += 3 }
    if($reversalCount -ge 2) { $totalScore += 5 }
    elseif($reversalCount -ge 1) { $totalScore += 2 }
    if($breakoutCount -ge 2) { $totalScore += 5 }
    if($scalpCount -ge 2) { $totalScore += 4 }

    # Time/session filter (0-5)
    if($hasTimeFilter) { $totalScore += 3 }
    if($hasFridayFilter) { $totalScore += 2 }

    # PENALTIES (mild, -0 to -15)
    if($hasMartingale -and -not $hasAntiMart) { $totalScore -= 5 }
    if($hasGrid -and -not $hasMaxOrders) { $totalScore -= 3 }
    if(-not $hasSL -and -not $hasEquityStop) { $totalScore -= 5 }
    if($codeQuality -eq "obfuscated") { $totalScore -= 10 }
    if($functionCount -lt 3) { $totalScore -= 3 }

    $totalScore = [Math]::Max(0, [Math]::Min(100, $totalScore))

    # Classification (calibrated to actual distribution: min=5, max=70, avg=43)
    $class = "C"
    if($totalScore -ge 62) { $class = "A" }
    elseif($totalScore -ge 48) { $class = "B" }

    # Indicators list
    $indicators = @()
    if($hasMA) { $indicators += "MA" }
    if($hasADX) { $indicators += "ADX" }
    if($hasMACD) { $indicators += "MACD" }
    if($hasIchimoku) { $indicators += "Ichimoku" }
    if($hasRSI) { $indicators += "RSI" }
    if($hasStoch) { $indicators += "Stochastic" }
    if($hasCCI) { $indicators += "CCI" }
    if($hasBollinger) { $indicators += "Bollinger" }
    if($hasDeMarker) { $indicators += "DeMarker" }
    if($hasFractals) { $indicators += "Fractals" }
    if($hasPivot) { $indicators += "Pivot" }
    if($hasDonchian) { $indicators += "Donchian" }

    # Timeframe detection
    $tf = "Any"
    if($joinedLower -match 'period_m1[^0-9]|period_m1\b') { $tf = "M1" }
    elseif($joinedLower -match 'period_m5[^0-9]|period_m5\b') { $tf = "M5" }
    elseif($joinedLower -match 'period_m15[^0-9]|period_m15\b') { $tf = "M15" }
    elseif($joinedLower -match 'period_m30[^0-9]|period_m30\b') { $tf = "M30" }
    elseif($joinedLower -match 'period_h1[^0-9]|period_h1\b') { $tf = "H1" }
    elseif($joinedLower -match 'period_h4[^0-9]|period_h4\b') { $tf = "H4" }
    elseif($joinedLower -match 'period_d1[^0-9]|period_d1\b') { $tf = "D1" }

    $obj = [PSCustomObject]@{
        file         = $f.Name
        class        = $class
        strategy     = $strategy
        score        = $totalScore
        code_quality = $codeQuality
        has_sl       = $hasSL
        has_tp       = $hasTP
        has_trailing = $hasTrailing
        has_grid     = $hasGrid
        has_martingale = $hasMartingale
        has_equity_stop = $hasEquityStop
        has_time_filter = $hasTimeFilter
        has_money_mgmt = $hasMoneyMgmt
        indicators   = ($indicators -join ", ")
        timeframe    = $tf
        function_count = $functionCount
        obfuscated_count = $obfuscatedCount
    }

    $results += $obj
}

# Output JSON
$json = $results | ConvertTo-Json -Depth 3
$json | Out-File $jsonOut -Encoding UTF8

# Output CSV
$results | Export-Csv $csvOut -NoTypeInformation -Encoding UTF8

# Summary
$summary = $results | Group-Object class | Select-Object Name, Count
$stratSummary = $results | Group-Object strategy | Select-Object Name, Count

Write-Host "=== CLASSIFICATION SUMMARY ==="
Write-Host ""
Write-Host "By Class:"
$summary | ForEach-Object { Write-Host "  $($_.Name): $($_.Count) EAs" }
Write-Host ""
Write-Host "By Strategy:"
$stratSummary | ForEach-Object { Write-Host "  $($_.Name): $($_.Count) EAs" }
Write-Host ""
Write-Host "Class A breakdown:"
$results | Where-Object { $_.class -eq "A" } | Group-Object strategy | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
Write-Host ""
Write-Host "Output: $jsonOut"
Write-Host "CSV: $csvOut"
