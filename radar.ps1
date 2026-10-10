#requires -Version 7.5
<#
  Radar des Cotes, version autonome (GitHub Actions + Telegram).
  A chaque passage (toutes les 15 min) :
    - lit les messages Telegram (enregistrement des paris, commandes) ;
    - toutes les 2 h entre 8 h et 22 h (heure de Paris) : analyse les cotes 1xBet / Pinnacle
      (1N2, plus/moins de buts, handicap asiatique), produit le Top 10 et le combine, verifie les cotes en direct
      avant d'alerter, et recupere les resultats des matchs des paris et des alertes ;
    - ecrit docs/data/*.json pour la page web et etat/etat.json pour la memoire du robot.
  Variables d'environnement : ODDS_API_KEY, TELEGRAM_TOKEN, PAGE_URL (facultatif), TZ=Europe/Paris.
#>
param([string]$TestFile, [switch]$ForceAnalysis, [string[]]$TestMessages)   # TestMessages : simule des messages Telegram (mode test)
$ErrorActionPreference = 'Stop'
$Root      = if ($env:RADAR_ROOT) { $env:RADAR_ROOT } else { $PSScriptRoot }
$StateDir  = Join-Path $Root 'etat'
$CacheDir  = Join-Path $StateDir 'cache'
$StateFile = Join-Path $StateDir 'etat.json'
$DataDir   = Join-Path (Join-Path $Root 'docs') 'data'
$OutFile   = Join-Path $DataDir 'resultat.json'
$HistFile  = Join-Path $DataDir 'historique.json'
$BetsFile  = Join-Path $DataDir 'paris.json'
New-Item -ItemType Directory -Force $CacheDir, $DataDir | Out-Null

# ---------- reglages ----------
$Leagues = [ordered]@{
  'soccer_france_ligue_one'       = 'Ligue 1'
  'soccer_france_ligue_two'       = 'Ligue 2'
  'soccer_epl'                    = 'Premier League'
  'soccer_efl_champ'              = 'Championship'
  'soccer_spain_la_liga'          = 'La Liga'
  'soccer_spain_segunda_division' = 'La Liga 2'
  'soccer_italy_serie_a'          = 'Serie A'
  'soccer_italy_serie_b'          = 'Serie B'
  'soccer_germany_bundesliga'     = 'Bundesliga'
  'soccer_germany_bundesliga2'    = '2. Bundesliga'
}
$Book             = 'onexbet'   # 1xBet
$RefBook          = 'pinnacle'  # reference a faible marge (obligatoire)
$Markets          = 'h2h,totals,spreads'
$MinEv            = 0.02        # valeur minimale d'un pari retenu (+2 %)
$ComboTarget      = 2.5         # cote totale minimale du combine
$ComboMaxLegs     = 3
$LegMinProb       = 0.5         # chaque match du combine : plus de 50 % de chances
$KellyFraction    = 0.25        # mise conseillee = 1/4 de Kelly
$WindowHours      = 36          # matchs qui commencent dans les 36 prochaines heures
$RefreshHours     = 8           # age maximal des cotes avant nouvelle requete
$MaxCreditsPerDay = 40
$ReserveCredits   = 6           # gardes chaque jour pour les verifications et les resultats
$AnalysisEveryMin = 110         # une analyse toutes les 2 h environ
$ActiveFromHour   = 8           # heure locale
$ActiveToHour     = 22

$inv = [Globalization.CultureInfo]::InvariantCulture
$fr  = [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
$nowUtc = [DateTime]::UtcNow
$nowLocal = Get-Date
$today  = $nowLocal.ToString('yyyy-MM-dd')
$key     = if ($env:ODDS_API_KEY) { $env:ODDS_API_KEY.Trim() } else { '' }
$tgToken = if ($env:TELEGRAM_TOKEN) { $env:TELEGRAM_TOKEN.Trim() } else { '' }
$PageUrl = $env:PAGE_URL

function Iso([DateTime]$d) { $d.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv) }
function Save-Json($obj, $path) { $obj | ConvertTo-Json -Depth 14 | Set-Content -Path $path -Encoding utf8 }
function ToUtc([string]$s) { [DateTimeOffset]::Parse($s, $inv).UtcDateTime }
function Fmt-Pt([double]$x, [switch]$Sign) { $s = $x.ToString('0.0#', $fr); if ($Sign -and $x -gt 0) { "+$s" } else { $s } }
function Eur([double]$x) { $x.ToString('0.00', $fr) + ' €' }
function Pct([double]$x, [string]$f = '0') { ($x * 100).ToString($f, $fr) + ' %' }
function Odd([double]$x) { $x.ToString('0.00', $fr) }
function HtmlEnc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }
function KoLocal([string]$iso) { (ToUtc $iso).ToLocalTime().ToString('ddd d MMM HH:mm', $fr) }

# ---------- etat persistant ----------
$state = @{ day = $today; usedToday = 0; remaining = $null; fetched = @{}; log = @(); rejected = @(); lastAnalysis = $null
  tg = @{ offset = 0; chatId = $null; botUsername = $null }; bets = @(); nextBet = 1; bankroll0 = $null; events = @{} }
if (Test-Path $StateFile) {
  try { $s = Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable -DateKind String; foreach ($k in $s.Keys) { $state[$k] = $s[$k] } } catch {}
}
if ($TestFile) { $StateFile = Join-Path $StateDir 'test-etat.json'; $OutFile = Join-Path $DataDir 'test-resultat.json'; $HistFile = Join-Path $DataDir 'test-historique.json'; $BetsFile = Join-Path $DataDir 'test-paris.json' }
if ($state.day -ne $today) { $state.day = $today; $state.usedToday = 0 }
foreach ($k in 'fetched', 'events', 'tg') { if (-not $state[$k]) { $state[$k] = @{} } }
$state.bets = @($state.bets | Where-Object { $_ })
$state.log = @($state.log | Where-Object { $_ -and (ToUtc $_.at) -gt $nowUtc.AddDays(-30) } | Select-Object -Last 100)
$state.rejected = @($state.rejected | Where-Object { $_ -and (ToUtc $_.at) -gt $nowUtc.AddHours(-6) })
foreach ($id in @($state.events.Keys)) { if ((ToUtc $state.events[$id].kickoff) -lt $nowUtc.AddDays(-4)) { $state.events.Remove($id) } }
$script:Remaining = $state.remaining
function Get-NotifLog { , @($state.log | Sort-Object @{ e = { $_.at } } -Descending) }

# ---------- Telegram ----------
function Tg([string]$method, [hashtable]$body = @{}) {
  if (-not $tgToken -or $TestFile) { return $null }
  try {
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$tgToken/$method" -ContentType 'application/json; charset=utf-8' `
      -Body ($body | ConvertTo-Json -Depth 6 -Compress -EscapeHandling EscapeNonAscii) -TimeoutSec 30
  } catch { Write-Output "Telegram $method impossible : $($_.Exception.Message)"; $null }
}
function Send-Tg([string]$text) {
  if ($TestFile) { Write-Output "[Telegram] $text"; return }
  if ($state.tg.chatId) { Tg 'sendMessage' @{ chat_id = $state.tg.chatId; text = $text; parse_mode = 'HTML'; disable_web_page_preview = $true } | Out-Null }
}
function Get-PageLink { if ($PageUrl) { "`n<a href=`"$PageUrl`">Ouvrir Radar des Cotes</a>" } else { '' } }
function Get-Help {
  "<b>Radar des Cotes</b>`nJe vous préviens dès qu'un combiné 1xBet intéressant est trouvé, et je suis vos paris.`n`n" +
  "/top : meilleurs paris du moment`n/paris : votre bankroll et vos paris en cours`n/bankroll 80 : régler la bankroll de départ`n" +
  "/gagne 3, /perdu 3, /rembourse 3 : corriger le résultat du pari n°3`n/auto 3 : revenir au résultat automatique`n/supprime 3 : supprimer le pari n°3`n`n" +
  "Pour enregistrer un pari, utilisez le formulaire de l'onglet « Mes paris » de la page : il ouvre Telegram avec le pari prêt à envoyer." + (Get-PageLink)
}

# ---------- paris de l'utilisateur ----------
function CodeNum([string]$s) { [double]::Parse(($s -replace 'm', '-' -replace 'p', '.'), $inv) }
function Get-BetProfit($b) { switch ($b.status) { 'gagné' { $b.stake * ($b.totalOdds - 1) } 'perdu' { - $b.stake } default { 0 } } }
function Get-Bankroll { if ($null -eq $state.bankroll0) { return $null }; $p = 0.0; foreach ($b in $state.bets) { $p += (Get-BetProfit $b) }; $state.bankroll0 + $p }
function Get-LegLabel([string]$mk, [int]$idx, [string]$line, [string]$h, [string]$a) {
  $pt = if ($line) { [double]::Parse($line, $inv) } else { 0 }
  switch ($mk) {
    'h2h'     { @("Victoire $h", 'Match nul', "Victoire $a")[$idx] }
    'dc'      { @("1X : $h ou nul", '12 : pas de nul', "X2 : nul ou $a")[$idx] }
    'totals'  { @("Plus de $(Fmt-Pt $pt) buts", "Moins de $(Fmt-Pt $pt) buts")[$idx] }
    'spreads' { @("$h $(Fmt-Pt $pt -Sign)", "$a $(Fmt-Pt (-$pt) -Sign)")[$idx] }
  }
}
function Get-LegProb($ev, [string]$mk, [int]$idx, [string]$line) {
  if (-not $ev) { return $null }
  $mkts = @($ev.markets)
  if ($mk -eq 'dc') {
    $h2 = $mkts | Where-Object { $_.marketKey -eq 'h2h' } | Select-Object -First 1
    if (-not $h2) { return $null }
    $p = @($h2.p); return @(($p[0] + $p[1]), ($p[0] + $p[2]), ($p[1] + $p[2]))[$idx]
  }
  $x = $mkts | Where-Object { $_.marketKey -eq $mk -and ((-not $line -and -not "$($_.line)") -or ("$($_.line)" -and $line -and [double]::Parse("$($_.line)", $inv) -eq [double]::Parse($line, $inv))) } | Select-Object -First 1
  if ($x) { @($x.p)[$idx] } else { $null }
}
function Format-Bet($b) {
  $lines = foreach ($l in $b.legs) { "• $(HtmlEnc $l.pickName) — $(HtmlEnc $l.home) – $(HtmlEnc $l.away) ($(KoLocal $l.kickoff)) @ $(Odd $l.odd)" + $(if ($l.result) { " : <b>$($l.result)</b>" } else { '' }) }
  ($lines -join "`n")
}
function Add-BetFromCode([string]$code) {
  if ($code -notmatch '^(\d+(?:p\d+)?)_(\d+(?:p\d+)?)_(.+)$') { Send-Tg "Code de pari illisible. Réessayez depuis l'onglet « Mes paris » de la page."; return }
  $stake = CodeNum $Matches[1]; $total = CodeNum $Matches[2]; $legCodes = $Matches[3].Split('_')
  $legs = @()
  foreach ($lc in $legCodes) {
    if ($lc -notmatch '^([0-9a-f]{6})([hdts])(\d)(m?\d+(?:p\d+)?)?o(\d+(?:p\d+)?)$') { Send-Tg "Une sélection du pari est illisible : rien n'a été enregistré."; return }
    $id6 = $Matches[1]; $mk = @{ h = 'h2h'; d = 'dc'; t = 'totals'; s = 'spreads' }[$Matches[2]]; $idx = [int]$Matches[3]
    $line = if ($Matches[4]) { (CodeNum $Matches[4]).ToString($inv) } else { '' }; $odd = CodeNum $Matches[5]
    $evId = @($state.events.Keys | Where-Object { $_.StartsWith($id6) }) | Select-Object -First 1
    if (-not $evId) { Send-Tg "Je ne retrouve pas un des matchs de ce pari (il a peut-être déjà commencé) : rien n'a été enregistré."; return }
    $ev = $state.events[$evId]
    $legs += [ordered]@{ eventId = $evId; sportKey = $ev.sportKey; league = $ev.league; home = $ev.home; away = $ev.away; kickoff = $ev.kickoff
      marketKey = $mk; market = @{ h2h = '1N2'; dc = 'Double chance'; totals = 'Buts'; spreads = 'Handicap asiatique' }[$mk]; line = $line; idx = $idx
      pickName = (Get-LegLabel $mk $idx $line $ev.home $ev.away); odd = $odd; p = (Get-LegProb $ev $mk $idx $line); result = $null; score = $null }
  }
  $bet = [ordered]@{ n = [int]$state.nextBet; createdAt = (Iso $nowUtc); stake = $stake; totalOdds = $total; legs = $legs; manualStatus = $null; status = 'en attente' }
  $state.nextBet = [int]$state.nextBet + 1
  $state.bets += $bet
  $msg = "<b>Pari n°$($bet.n) enregistré</b> : $(Eur $stake) à la cote $(Odd $total)`n$(Format-Bet $bet)"
  $ps = @($legs | ForEach-Object { $_.p })
  if (@($ps | Where-Object { $null -eq $_ }).Count -eq 0) { $P = 1.0; foreach ($p in $ps) { $P *= $p }; $msg += "`nChance estimée : $(Pct $P) · valeur : $(Pct ($P * $total - 1) '+0.0;-0.0')" }
  $bk = Get-Bankroll
  if ($bk -and $stake / $bk -gt 0.05) { $msg += "`n<b>Attention</b> : cette mise représente $(Pct ($stake / $bk)) de votre bankroll ($(Eur $bk))." }
  Send-Tg ($msg + (Get-PageLink))
}
function Set-BetManual([string]$action, [string]$arg) {
  $n = 0; if (-not [int]::TryParse(($arg -replace '[^\d]', ''), [ref]$n)) { Send-Tg 'Indiquez le numéro du pari, par exemple : /gagne 3'; return }
  $b = $state.bets | Where-Object { [int]$_.n -eq $n } | Select-Object -First 1
  if (-not $b) { Send-Tg "Je ne trouve pas le pari n°$n."; return }
  if ($action -eq 'supprime') { $state.bets = @($state.bets | Where-Object { [int]$_.n -ne $n }); Send-Tg "Pari n°$n supprimé."; return }
  $b.manualStatus = @{ gagne = 'gagné'; perdu = 'perdu'; rembourse = 'remboursé'; auto = $null }[$action]
  Update-BetStatus $b | Out-Null
  Send-Tg ("Pari n°$n : " + $(if ($b.manualStatus) { "marqué <b>$($b.manualStatus)</b> par vous." } else { 'retour au résultat automatique.' }) + $(if ((Get-Bankroll)) { " Bankroll : $(Eur (Get-Bankroll))." } else { '' }))
}
function Get-Status($legs) {
  $rs = @($legs | ForEach-Object { $_.result })
  if ($rs -contains 'perdu') { 'perdu' } elseif (@($rs | Where-Object { $_ -eq 'gagné' }).Count -eq @($legs).Count) { 'gagné' }
  elseif ($rs -contains 'inconnu') { 'inconnu' } else { 'en attente' }
}
function Update-BetStatus($b) { $old = $b.status; $b.status = if ($b.manualStatus) { $b.manualStatus } else { Get-Status $b.legs }; return ($old -ne $b.status) }
function Get-BetsSummary {
  $bk = Get-Bankroll
  $pend = @($state.bets | Where-Object { $_.status -eq 'en attente' })
  $s = if ($null -ne $bk) { "<b>Bankroll</b> : $(Eur $bk) (départ $(Eur $state.bankroll0))" } else { 'Bankroll de départ non réglée : écrivez par exemple /bankroll 80' }
  $s += "`n$(@($state.bets).Count) pari(s) enregistré(s), $($pend.Count) en cours."
  foreach ($b in $pend) { $s += "`n`n<b>Pari n°$($b.n)</b> : $(Eur $b.stake) @ $(Odd $b.totalOdds)`n$(Format-Bet $b)" }
  $s + (Get-PageLink)
}
function Invoke-StartCode([string]$code) {
  if ($code -match '^bk(\d+(?:p\d+)?)$') { $state.bankroll0 = CodeNum $Matches[1]; Send-Tg "Bankroll de départ réglée à $(Eur $state.bankroll0)."; return }
  if ($code -match '^r([glvad])(\d+)$') { Set-BetManual (@{ g = 'gagne'; l = 'perdu'; v = 'rembourse'; a = 'auto'; d = 'supprime' }[$Matches[1]]) $Matches[2]; return }
  if ($code -eq 'paris') { Send-Tg (Get-BetsSummary); return }
  Add-BetFromCode $code
}
function Invoke-TgCommand([string]$t) {
  $parts = $t -split '\s+', 2; $cmd = ($parts[0].ToLower() -replace '@.*$', ''); $arg = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
  $cmd = $cmd -replace 'é', 'e'
  if ($cmd -eq '/start') { if ($arg) { Invoke-StartCode $arg } else { Send-Tg (Get-Help) } }
  elseif ($cmd -in '/aide', '/help') { Send-Tg (Get-Help) }
  elseif ($cmd -eq '/paris') { Send-Tg (Get-BetsSummary) }
  elseif ($cmd -eq '/top') { $script:WantTop = $true }
  elseif ($cmd -eq '/bankroll') {
    $v = 0.0
    if ([double]::TryParse(($arg -replace ',', '.' -replace '[^\d.]', ''), [Globalization.NumberStyles]::Float, $inv, [ref]$v) -and $v -gt 0) { $state.bankroll0 = $v; Send-Tg "Bankroll de départ réglée à $(Eur $v)." }
    else { Send-Tg 'Écrivez par exemple : /bankroll 80' }
  }
  elseif ($cmd -in '/gagne', '/perdu', '/rembourse', '/auto', '/supprime') { Set-BetManual $cmd.TrimStart('/') $arg }
  else { Send-Tg ("Je n'ai pas compris ce message.`n`n" + (Get-Help)) }
}
function Invoke-Telegram {
  if (-not $tgToken -or $TestFile) { return }
  if (-not $state.tg.botUsername) { $me = Tg 'getMe'; if ($me -and $me.ok) { $state.tg.botUsername = [string]$me.result.username } }
  $up = Tg 'getUpdates' @{ offset = [long]$state.tg.offset; timeout = 0; allowed_updates = @('message') }
  if (-not $up -or -not $up.ok) { return }
  foreach ($u in $up.result) {
    $state.tg.offset = [long]$u.update_id + 1
    $m = $u.message
    if (-not $m -or -not $m.text) { continue }
    if (-not $state.tg.chatId) {
      if ($m.chat.type -ne 'private') { continue }
      $state.tg.chatId = [long]$m.chat.id   # le premier a ecrire au robot en devient le proprietaire
    }
    if ([long]$m.chat.id -ne [long]$state.tg.chatId) { continue }
    try { Invoke-TgCommand ([string]$m.text).Trim() } catch { Send-Tg "Erreur en traitant votre message : $(HtmlEnc $_.Exception.Message)" }
  }
}

# ---------- The Odds API ----------
function Invoke-Api([string]$path, [hashtable]$query = @{}) {
  $parts = @("apiKey=$key") + @($query.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" })
  $r = Invoke-WebRequest -Uri ("https://api.the-odds-api.com/v4/$path" + '?' + ($parts -join '&')) -TimeoutSec 40
  $rem = $r.Headers['x-requests-remaining']; if ($rem) { $script:Remaining = [int][double]"$($rem | Select-Object -First 1)" }
  $last = $r.Headers['x-requests-last']; $cost = if ($last) { [int][double]"$($last | Select-Object -First 1)" } else { 0 }
  $state.usedToday += $cost
  [pscustomobject]@{ Data = ($r.Content | ConvertFrom-Json -DateKind String -NoEnumerate); Cost = $cost; Raw = $r.Content }
}
function Test-Credits { $TestFile -or $null -eq $script:Remaining -or $script:Remaining -gt 3 }

# ---------- probabilites sans marge (methode de Shin) ----------
function Get-Fair([double[]]$odds) {
  $imp = [double[]]@($odds | ForEach-Object { 1.0 / $_ })
  $S = ($imp | Measure-Object -Sum).Sum
  if ($S -le 1.0000001) { return , [double[]]@($imp | ForEach-Object { $_ / $S }) }
  $calc = { param($z) foreach ($p in $imp) { ([math]::Sqrt($z * $z + 4 * (1 - $z) * $p * $p / $S) - $z) / (2 * (1 - $z)) } }
  $lo = 0.0; $hi = 0.6
  for ($i = 0; $i -lt 60; $i++) { $m = ($lo + $hi) / 2; if (((& $calc $m) | Measure-Object -Sum).Sum -gt 1) { $lo = $m } else { $hi = $m } }
  $r = [double[]]@(& $calc (($lo + $hi) / 2)); $t = ($r | Measure-Object -Sum).Sum
  return , [double[]]@($r | ForEach-Object { $_ / $t })
}

# ---------- lecture des marches ----------
function Test-HalfLine([double]$pt) { [math]::Abs(([math]::Abs($pt) * 2) % 2 - 1) -lt 1e-9 }
function Get-BookLines($bm, [string]$mkey, [string]$h, [string]$a) {
  $out = @{}
  $m = $bm.markets | Where-Object key -eq $mkey | Select-Object -First 1
  if (-not $m) { return $out }
  if ($mkey -eq 'h2h') {
    $o = @{}; foreach ($x in $m.outcomes) { $o[[string]$x.name] = [double]$x.price }
    if ($o.ContainsKey($h) -and $o.ContainsKey($a) -and $o.ContainsKey('Draw')) { $out[''] = [double[]]@($o[$h], $o['Draw'], $o[$a]) }
  } elseif ($mkey -eq 'totals') {
    $g = @{}
    foreach ($x in $m.outcomes) {
      $pt = [double]$x.point
      if (Test-HalfLine $pt) { $k = $pt.ToString($inv); if (-not $g[$k]) { $g[$k] = @{} }; $g[$k][[string]$x.name] = [double]$x.price }
    }
    foreach ($k in $g.Keys) { if ($g[$k]['Over'] -and $g[$k]['Under']) { $out[$k] = [double[]]@($g[$k]['Over'], $g[$k]['Under']) } }
  } elseif ($mkey -eq 'spreads') {
    $hp = @{}; $ap = @{}
    foreach ($x in $m.outcomes) {
      $pt = [double]$x.point
      if (Test-HalfLine $pt) {
        if ([string]$x.name -eq $h) { $hp[$pt.ToString($inv)] = [double]$x.price }
        elseif ([string]$x.name -eq $a) { $ap[(-$pt).ToString($inv)] = [double]$x.price }
      }
    }
    foreach ($k in $hp.Keys) { if ($ap.ContainsKey($k)) { $out[$k] = [double[]]@($hp[$k], $ap[$k]) } }
  }
  foreach ($k in @($out.Keys)) { if (@($out[$k] | Where-Object { $_ -le 1 }).Count) { $out.Remove($k) } }
  return $out
}
function Get-Items($e) {
  $items = [Collections.Generic.List[object]]::new()
  $h = [string]$e.home_team; $a = [string]$e.away_team
  $bx = $e.bookmakers | Where-Object key -eq $Book | Select-Object -First 1
  $bp = $e.bookmakers | Where-Object key -eq $RefBook | Select-Object -First 1
  if (-not $bx -or -not $bp) { return , $items }
  foreach ($mk in 'h2h', 'totals', 'spreads') {
    $lx = Get-BookLines $bx $mk $h $a; $lp = Get-BookLines $bp $mk $h $a
    foreach ($line in $lx.Keys) {
      if (-not $lp.ContainsKey($line)) { continue }
      $n = if ($mk -eq 'h2h') { 3 } else { 2 }
      $market = @{ h2h = '1N2'; totals = 'Buts'; spreads = 'Handicap asiatique' }[$mk]
      $names = @(for ($j = 0; $j -lt $n; $j++) { Get-LegLabel $mk $j $line $h $a })
      $codes = if ($mk -eq 'h2h') { @('1', 'N', '2') } elseif ($mk -eq 'totals') { @("+$(Fmt-Pt ([double]::Parse($line, $inv)))", "-$(Fmt-Pt ([double]::Parse($line, $inv)))") }
               else { @("H1 $(Fmt-Pt ([double]::Parse($line, $inv)) -Sign)", "H2 $(Fmt-Pt (-[double]::Parse($line, $inv)) -Sign)") }
      $items.Add([pscustomobject]@{ marketKey = $mk; market = $market; line = $line; names = $names; codes = $codes; ox = $lx[$line]; op = $lp[$line] })
    }
  }
  return , $items
}
function Get-Picks($e, $it, [string]$league, [string]$sportKey, [string]$kickoff) {
  $fair = Get-Fair $it.op
  $margin = (($it.ox | ForEach-Object { 1 / $_ }) | Measure-Object -Sum).Sum - 1
  for ($j = 0; $j -lt $it.ox.Count; $j++) {
    $p = $fair[$j]; $o = $it.ox[$j]; $ev = $p * $o - 1
    [pscustomobject][ordered]@{
      eventId = [string]$e.id; sportKey = $sportKey; league = $league; home = [string]$e.home_team; away = [string]$e.away_team; kickoff = $kickoff
      market = $it.market; marketKey = $it.marketKey; line = $it.line; idx = $j; pick = $it.codes[$j]; pickName = $it.names[$j]; names = $it.names
      odd = $o; p = [math]::Round($p, 4); fairOdd = [math]::Round(1 / $p, 3); ev = [math]::Round($ev, 4)
      quality = [math]::Round($ev / ($o * [math]::Sqrt($p * (1 - $p))), 4); kelly = [math]::Round([math]::Max(0.0, $ev) / ($o - 1), 4)
      refSource = 'Pinnacle'; odds1x = $it.ox; refOdds = [double[]]@($it.op | ForEach-Object { [math]::Round($_, 3) }); margin1x = [math]::Round($margin, 4)
    }
  }
}
function Get-LegKey($l) { "$($l.eventId)|$($l.marketKey)|$($l.line)|$($l.idx)" }
function Get-Sig($legs) { (@($legs | ForEach-Object { Get-LegKey $_ }) | Sort-Object) -join '~' }
function New-Combo($legs) {
  $odds = 1.0; $prob = 1.0; foreach ($l in $legs) { $odds *= $l.odd; $prob *= $l.p }
  $ev = $prob * $odds - 1
  $legs = @($legs | Sort-Object kickoff)
  [ordered]@{ legs = $legs; totalOdds = [math]::Round($odds, 3); prob = [math]::Round($prob, 4); ev = [math]::Round($ev, 4)
    stakePct = [math]::Round([math]::Max(0.0, $ev) / ($odds - 1) * $KellyFraction, 4); signature = (Get-Sig $legs); firstKickoff = $legs[0].kickoff
    verified = $false; verifiedAt = $null; notifiedAt = $null }
}
function Confirm-Leg($leg) {
  $res = Invoke-Api "sports/$($leg.sportKey)/events/$($leg.eventId)/odds" @{ bookmakers = "$Book,$RefBook"; markets = $leg.marketKey; oddsFormat = 'decimal' }
  $e = $res.Data; if ($e -is [array]) { $e = $e[0] }
  $items = Get-Items $e
  $it = $items | Where-Object { $_.marketKey -eq $leg.marketKey -and $_.line -eq $leg.line } | Select-Object -First 1
  if (-not $it) { return $null }
  $p = Get-Picks $e $it $leg.league $leg.sportKey $leg.kickoff | Where-Object { $_.idx -eq $leg.idx } | Select-Object -First 1
  if (-not $p -or $p.ev -lt $MinEv -or $p.p -lt $LegMinProb) { return $null }
  return $p
}
function Set-LegResult($leg, [int]$hg, [int]$ag) {
  $leg.score = "$hg-$ag"
  $line = if ("$($leg.line)") { [double]::Parse([string]$leg.line, $inv) } else { 0 }
  $i = [int]$leg.idx
  $won = if ($leg.marketKey -eq 'h2h') { ($i -eq 0 -and $hg -gt $ag) -or ($i -eq 1 -and $hg -eq $ag) -or ($i -eq 2 -and $ag -gt $hg) }
         elseif ($leg.marketKey -eq 'dc') { ($i -eq 0 -and $hg -ge $ag) -or ($i -eq 1 -and $hg -ne $ag) -or ($i -eq 2 -and $ag -ge $hg) }
         elseif ($leg.marketKey -eq 'totals') { if ($i -eq 0) { ($hg + $ag) -gt $line } else { ($hg + $ag) -lt $line } }
         else { if ($i -eq 0) { ($hg + $line) -gt $ag } else { ($ag - $line) -gt $hg } }
  $leg.result = if ($won) { 'gagné' } else { 'perdu' }
}

# ---------- analyse complete ----------
function Invoke-Analysis {
  $fromDt = $nowUtc.AddMinutes(20); $toDt = $nowUtc.AddHours($WindowHours)
  $from = Iso $fromDt; $to = Iso $toDt
  $leagueInfo = [Collections.Generic.List[object]]::new()
  $allEvents = [Collections.Generic.List[object]]::new()
  $candidates = @(); $perDay = 0

  if ($TestFile) {
    foreach ($e in (Get-Content $TestFile -Raw | ConvertFrom-Json -DateKind String -NoEnumerate)) {
      $e | Add-Member -NotePropertyName sportKey -NotePropertyValue 'test' -Force; $allEvents.Add($e)
    }
  } else {
    $active = @{}; foreach ($s in (Invoke-Api 'sports').Data) { $active[$s.key] = $true }
    foreach ($k in $Leagues.Keys) {
      if (-not $active.ContainsKey($k)) { $leagueInfo.Add([ordered]@{ key = $k; name = $Leagues[$k]; events = 0; status = 'hors saison' }); continue }
      $evs = @((Invoke-Api "sports/$k/events" @{ commenceTimeFrom = $from; commenceTimeTo = $to }).Data)
      if ($evs.Count -eq 0) { $leagueInfo.Add([ordered]@{ key = $k; name = $Leagues[$k]; events = 0; status = 'pas de match' }); continue }
      $first = ($evs | ForEach-Object { ToUtc ([string]$_.commence_time) } | Measure-Object -Minimum).Minimum
      $candidates += [pscustomobject]@{ key = $k; n = $evs.Count; last = $state.fetched[$k]; first = $first }
    }
    $d = $nowLocal; $daysLeft = [DateTime]::DaysInMonth($d.Year, $d.Month) - $d.Day + 1
    $perDay = $MaxCreditsPerDay
    if ($null -ne $script:Remaining) { $perDay = [int][math]::Min($MaxCreditsPerDay, [math]::Floor($script:Remaining / $daysLeft)) }
    $marketCount = $Markets.Split(',').Count
    foreach ($c in ($candidates | Sort-Object @{ e = { [bool]$_.last } }, first)) {
      $cacheFile = Join-Path $CacheDir "$($c.key).json"
      $age = if ($c.last -and (Test-Path $cacheFile)) { ($nowUtc - (ToUtc $c.last)).TotalHours } else { 1e9 }
      $status = 'cache'
      if ($age -ge $RefreshHours -and ($state.usedToday + $marketCount) -le ($perDay - $ReserveCredits)) {
        $res = Invoke-Api "sports/$($c.key)/odds" @{ bookmakers = "$Book,$RefBook"; markets = $Markets; oddsFormat = 'decimal'; commenceTimeFrom = $from; commenceTimeTo = $to }
        Set-Content $cacheFile $res.Raw -Encoding utf8
        $state.fetched[$c.key] = $nowUtc.ToString('o'); $status = 'à jour'; $age = 0
      } elseif (-not (Test-Path $cacheFile)) {
        $leagueInfo.Add([ordered]@{ key = $c.key; name = $Leagues[$c.key]; events = $c.n; status = 'budget du jour atteint' }); continue
      }
      foreach ($e in (Get-Content $cacheFile -Raw | ConvertFrom-Json -DateKind String -NoEnumerate)) {
        $e | Add-Member -NotePropertyName league -NotePropertyValue $Leagues[$c.key] -Force
        $e | Add-Member -NotePropertyName sportKey -NotePropertyValue $c.key -Force
        $allEvents.Add($e)
      }
      $leagueInfo.Add([ordered]@{ key = $c.key; name = $Leagues[$c.key]; events = $c.n; status = $status; ageHours = [math]::Round([math]::Min($age, 999), 1) })
    }
  }

  # Analyse de chaque match
  $logLegs = @{}
  foreach ($n in $state.log) { foreach ($l in $n.legs) { if ($l.eventId) { $k = Get-LegKey $l; if (-not $logLegs[$k]) { $logLegs[$k] = @() }; $logLegs[$k] += , $l } } }
  $allPicks = [Collections.Generic.List[object]]::new(); $scanned = 0; $withBoth = 0
  $matchList = [Collections.Generic.List[object]]::new()
  foreach ($e in $allEvents) {
    $ko = ToUtc ([string]$e.commence_time)
    if ($ko -lt $fromDt -or $ko -gt $toDt) { continue }
    $scanned++
    $items = Get-Items $e
    $entry = [ordered]@{ eventId = [string]$e.id; sportKey = $e.sportKey; league = $e.league; home = [string]$e.home_team; away = [string]$e.away_team; kickoff = (Iso $ko)
      markets = @($items | ForEach-Object { [ordered]@{ marketKey = $_.marketKey; line = $_.line; odds1x = $_.ox; p = [double[]]@((Get-Fair $_.op) | ForEach-Object { [math]::Round($_, 4) }) } }) }
    $matchList.Add($entry); $state.events[[string]$e.id] = $entry
    if ($items.Count -eq 0) { continue }
    $withBoth++
    foreach ($it in $items) {
      foreach ($p in @(Get-Picks $e $it $e.league $e.sportKey (Iso $ko))) {
        $lk = Get-LegKey $p
        if ($logLegs.ContainsKey($lk)) { foreach ($l in $logLegs[$lk]) { $l.closeFairOdd = $p.fairOdd; $l.closeOdd1x = $p.odd; $l.closeSeenAt = (Iso $nowUtc) } }
        if ($p.ev -ge $MinEv) { $allPicks.Add($p) }
      }
    }
  }
  $top = @($allPicks | Group-Object eventId | ForEach-Object { $_.Group | Sort-Object quality -Descending | Select-Object -First 1 } |
    Sort-Object quality -Descending | Select-Object -First 10)

  # Combine
  $script:cand = @($allPicks | Where-Object { $_.p -ge $LegMinProb } | Sort-Object p -Descending | Select-Object -First 30)
  $script:bestCombo = $null
  function Search-Combo([int]$start, [int[]]$chosen) {
    if ($chosen.Count -ge 2) {
      $odds = 1.0; $prob = 1.0; foreach ($i in $chosen) { $odds *= $script:cand[$i].odd; $prob *= $script:cand[$i].p }
      if ($odds -ge $ComboTarget) {
        $ev = $prob * $odds - 1
        if (-not $script:bestCombo -or $prob -gt $script:bestCombo.prob -or ($prob -eq $script:bestCombo.prob -and $ev -gt $script:bestCombo.ev)) {
          $script:bestCombo = @{ idx = $chosen; odds = $odds; prob = $prob; ev = $ev }
        }
        return
      }
    }
    if ($chosen.Count -ge $ComboMaxLegs) { return }
    for ($i = $start; $i -lt $script:cand.Count; $i++) {
      $id = $script:cand[$i].eventId
      if (@($chosen | Where-Object { $script:cand[$_].eventId -eq $id }).Count) { continue }
      Search-Combo ($i + 1) ([int[]]($chosen + $i))
    }
  }
  Search-Combo 0 ([int[]]@())

  $combo = $null; $notify = $false; $comboNote = ''
  if ($script:bestCombo) {
    $combo = New-Combo @($script:bestCombo.idx | ForEach-Object { $script:cand[$_] })
    $prev = $state.log | Where-Object { $_.signature -eq $combo.signature } | Select-Object -First 1
    if ($prev) { $combo.verified = $true; $combo.verifiedAt = $prev.at; $combo.notifiedAt = $prev.at }
    elseif (@($state.rejected | Where-Object { $_.sig -eq $combo.signature }).Count) {
      $comboNote = 'Le meilleur combiné repéré a été écarté récemment : ses cotes 1xBet avaient bougé lors de la vérification.'; $combo = $null
    } elseif (-not (Test-Credits)) {
      $comboNote = 'Un combiné a été repéré mais il ne reste plus assez de crédits API pour vérifier ses cotes : aucune alerte envoyée.'; $combo = $null
    } else {
      $fresh = @(); $ok = $true
      foreach ($l in $combo.legs) {
        $f = $null
        if ($TestFile) { $f = $l } else { try { $f = Confirm-Leg $l } catch { $f = $null } }
        if (-not $f) { $ok = $false; break }
        $fresh += $f
      }
      $c2 = if ($ok) { New-Combo $fresh } else { $null }
      if (-not $ok -or $c2.totalOdds -lt $ComboTarget) {
        $state.rejected += @{ sig = $combo.signature; at = (Iso $nowUtc) }
        $comboNote = 'Un combiné a été repéré mais les cotes 1xBet ont bougé à la vérification : aucune alerte envoyée.'; $combo = $null
      } else {
        $combo = $c2; $combo.verified = $true; $combo.verifiedAt = (Iso $nowUtc); $combo.notifiedAt = (Iso $nowUtc)
        $notify = $true
        $bk = Get-Bankroll
        $msg = "<b>Combiné 1xBet cote $(Odd $combo.totalOdds)</b> (cotes vérifiées à l'instant)`n"
        $msg += (($combo.legs | ForEach-Object { "• $(HtmlEnc $_.pickName) — $(HtmlEnc $_.home) – $(HtmlEnc $_.away) ($(KoLocal $_.kickoff)) @ $(Odd $_.odd)" }) -join "`n")
        $msg += "`nChance de passer : $(Pct $combo.prob) · valeur : $(Pct $combo.ev '+0.0;-0.0')"
        $msg += "`nMise conseillée : $(Pct $combo.stakePct '0.0') de la bankroll" + $(if ($bk) { " ≈ $(Eur ($bk * $combo.stakePct))" } else { '' })
        Send-Tg ($msg + (Get-PageLink))
        $state.log += [ordered]@{ at = (Iso $nowUtc); signature = $combo.signature; totalOdds = $combo.totalOdds; prob = $combo.prob; ev = $combo.ev
          stakePct = $combo.stakePct; target = $ComboTarget; status = 'en attente'
          legs = @($combo.legs | ForEach-Object { [ordered]@{ eventId = $_.eventId; sportKey = $_.sportKey; league = $_.league; home = $_.home; away = $_.away
            kickoff = $_.kickoff; market = $_.market; marketKey = $_.marketKey; line = $_.line; idx = $_.idx; pick = $_.pick; pickName = $_.pickName
            odd = $_.odd; p = $_.p; fairOdd = $_.fairOdd } }) }
      }
    }
  }

  # Resultats reels (alertes et paris de l'utilisateur)
  $allLegs = @(foreach ($n in $state.log) { $n.legs }) + @(foreach ($b in $state.bets) { $b.legs })
  $pending = @(foreach ($l in $allLegs) { if ($l -and -not $l.result -and $l.sportKey -and $l.eventId -and $l.kickoff -and (ToUtc $l.kickoff).AddHours(2.25) -lt $nowUtc) { $l } })
  foreach ($g in ($pending | Group-Object { $_.sportKey })) {
    $recent = @()
    foreach ($l in $g.Group) { if ((ToUtc $l.kickoff) -lt $nowUtc.AddDays(-3)) { $l.result = 'inconnu' } else { $recent += , $l } }
    if (-not $recent.Count -or $TestFile -or -not (Test-Credits)) { continue }
    try {
      $ids = @($recent | ForEach-Object { $_.eventId } | Sort-Object -Unique) -join ','
      $res = Invoke-Api "sports/$($g.Name)/scores" @{ daysFrom = 3; eventIds = $ids }
      foreach ($ev in $res.Data) {
        if (-not $ev.completed -or -not $ev.scores) { continue }
        $hg = ($ev.scores | Where-Object name -eq $ev.home_team | Select-Object -First 1).score
        $ag = ($ev.scores | Where-Object name -eq $ev.away_team | Select-Object -First 1).score
        if ($null -eq $hg -or $null -eq $ag) { continue }
        foreach ($l in $recent) { if ($l.eventId -eq [string]$ev.id) { Set-LegResult $l ([int]$hg) ([int]$ag) } }
      }
    } catch { Write-Output "Résultats indisponibles pour $($g.Name) : $($_.Exception.Message)" }
  }
  foreach ($n in $state.log) { $n.status = Get-Status $n.legs }
  foreach ($b in $state.bets) {
    if ((Update-BetStatus $b) -and $b.status -in 'gagné', 'perdu') {
      $pr = Get-BetProfit $b; $bk = Get-Bankroll
      Send-Tg ("<b>Pari n°$($b.n) $($b.status)</b> : " + $(if ($pr -ge 0) { '+' } else { '' }) + "$(Eur $pr)`n$(Format-Bet $b)" + $(if ($null -ne $bk) { "`nBankroll : $(Eur $bk)" } else { '' }))
    }
  }

  $settled = @($state.log | Where-Object { $_.status -in 'gagné', 'perdu' })
  $profit = 0.0; foreach ($n in $settled) { $profit += $(if ($n.status -eq 'gagné') { $n.totalOdds - 1 } else { -1 }) }
  $clvs = @(foreach ($n in $state.log) { foreach ($l in $n.legs) { if ($l.closeFairOdd) { $l.odd / $l.closeFairOdd - 1 } } })
  $stats = [ordered]@{ notified = @($state.log).Count; settled = $settled.Count; won = @($settled | Where-Object status -eq 'gagné').Count
    lost = @($settled | Where-Object status -eq 'perdu').Count; profitUnits = [math]::Round($profit, 3)
    roi = $(if ($settled.Count) { [math]::Round($profit / $settled.Count, 4) } else { $null })
    avgClv = $(if ($clvs.Count) { [math]::Round(($clvs | Measure-Object -Average).Average, 4) } else { $null }); clvLegs = $clvs.Count }

  $result = [ordered]@{
    status = 'ok'; message = ''; generatedAt = (Iso $nowUtc)
    creditsRemaining = $script:Remaining; creditsUsedToday = $state.usedToday; dailyBudget = $perDay
    minEv = $MinEv; comboTarget = $ComboTarget; legMinProb = $LegMinProb; windowHours = $WindowHours; markets = @('1N2', 'Plus/moins de buts', 'Handicap asiatique')
    leagues = @($leagueInfo); eventsScanned = $scanned; eventsWith1xbet = $withBoth; valueBets = $allPicks.Count
    top = $top; combo = $combo; comboNote = $comboNote; notify = $notify
    notifications = (Get-NotifLog); stats = $stats; matches = @($matchList | Sort-Object { $_.kickoff }); botUsername = $state.tg.botUsername
  }
  Save-Json $result $OutFile
  $hist = [ordered]@{}
  if (Test-Path $HistFile) { try { $hist = Get-Content $HistFile -Raw | ConvertFrom-Json -AsHashtable -DateKind String } catch { $hist = [ordered]@{} } }
  $hist[$today] = [ordered]@{ date = $today; updatedAt = (Iso $nowUtc); eventsScanned = $scanned; valueBets = $allPicks.Count; top = @($top | Select-Object -First 3); combo = $combo }
  $keep = [ordered]@{}; foreach ($k in (@($hist.Keys) | Sort-Object -Descending | Select-Object -First 30)) { $keep[$k] = $hist[$k] }
  Save-Json $keep $HistFile
  if ($script:WantTop) {
    $t = "<b>Meilleurs paris 1xBet du moment</b>`n" + ((@($top | Select-Object -First 5) | ForEach-Object { "• $(HtmlEnc $_.pickName) — $(HtmlEnc $_.home) – $(HtmlEnc $_.away) ($(KoLocal $_.kickoff)) @ $(Odd $_.odd), valeur $(Pct $_.ev '+0.0')" }) -join "`n")
    if ($combo) { $t += "`n`nCombiné : cote $(Odd $combo.totalOdds), chance $(Pct $combo.prob)" }
    Send-Tg ($t + (Get-PageLink))
  }
  Write-Output ("Analyse : {0} matchs, {1} value bets, combiné : {2}, alerte : {3}, crédits restants : {4}" -f $scanned, $allPicks.Count, ($(if ($combo) { $combo.totalOdds } else { 'aucun' })), $notify, $script:Remaining)
}

# ---------- programme principal ----------
$script:WantTop = $false
Invoke-Telegram
if ($TestFile -and $TestMessages) { foreach ($t in $TestMessages) { Write-Output "> $t"; Invoke-TgCommand $t } }

$hour = $nowLocal.Hour
$due = $ForceAnalysis -or $TestFile -or $script:WantTop -or `
  ($hour -ge $ActiveFromHour -and $hour -le $ActiveToHour -and (-not $state.lastAnalysis -or ($nowUtc - (ToUtc $state.lastAnalysis)).TotalMinutes -ge $AnalysisEveryMin))
if ($due) {
  if (-not $key -and -not $TestFile) {
    Save-Json ([ordered]@{ status = 'erreur'; message = 'Clé API manquante : ajoutez le secret ODDS_API_KEY dans les réglages du dépôt GitHub.'; generatedAt = (Iso $nowUtc)
      top = @(); combo = $null; leagues = @(); notifications = (Get-NotifLog); botUsername = $state.tg.botUsername }) $OutFile
    Write-Output 'ERREUR : clé API manquante'
  } else {
    try { Invoke-Analysis; $state.lastAnalysis = (Iso $nowUtc) }
    catch {
      $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      $msg = switch ($code) {
        401 { 'Clé API refusée par The Odds API : vérifiez le secret ODDS_API_KEY.' }
        429 { 'Quota de requêtes The Odds API épuisé pour ce mois.' }
        default { "Erreur pendant l'analyse : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" }
      }
      Save-Json ([ordered]@{ status = 'erreur'; message = $msg; generatedAt = (Iso $nowUtc); creditsRemaining = $script:Remaining
        top = @(); combo = $null; leagues = @(); notifications = (Get-NotifLog); botUsername = $state.tg.botUsername }) $OutFile
      Write-Output "ERREUR : $msg"
      $state.lastAnalysis = (Iso $nowUtc)
    }
  }
} else { Write-Output 'Pas d''analyse à ce passage (messages Telegram seulement).' }

foreach ($b in $state.bets) { Update-BetStatus $b | Out-Null }
Save-Json ([ordered]@{ bankroll0 = $state.bankroll0; botUsername = $state.tg.botUsername; bets = @($state.bets) }) $BetsFile
$state.remaining = $script:Remaining
Save-Json $state $StateFile
