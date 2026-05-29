<#
  e2e-data-test.ps1
  -----------------
  End-to-end verification of the "save data for registered customers + their
  questionnaire status" capability, run directly against the live Supabase
  project via its REST API (GoTrue auth + PostgREST) using curl.exe.

  No Node/npm required. Mirrors exactly the HTTP calls the app's supabase-js
  SDK makes under the hood (signup -> profile trigger -> submissions +
  question_timings insert under RLS).

  This file is intentionally ASCII-only so Windows PowerShell 5.1 parses it
  regardless of file encoding. The one Hebrew string used to test unicode
  round-tripping through the jsonb column is built at runtime from code points.

  SECRETS ARE NEVER HARD-CODED. Provide them via environment variables:
    $env:SUPABASE_SERVICE_ROLE = '<service_role secret key>'   # required
    $env:SUPABASE_PUBLISHABLE  = '<publishable / anon key>'    # optional, has default
    $env:SUPABASE_URL          = 'https://<ref>.supabase.co'   # optional, has default

  Run:  powershell -ExecutionPolicy Bypass -File scripts\e2e-data-test.ps1
#>

$ErrorActionPreference = 'Stop'

# ---- Config (non-secret defaults; secret comes from env only) ----
$BASE = if ($env:SUPABASE_URL) { $env:SUPABASE_URL } else { 'https://njydqslqldphvrcnrrsq.supabase.co' }
$ANON = if ($env:SUPABASE_PUBLISHABLE) { $env:SUPABASE_PUBLISHABLE } else { 'sb_publishable_S5XbkycQhDrZZmOVKx9h3g_QDlzTEqw' }
$SERVICE = $env:SUPABASE_SERVICE_ROLE
if (-not $SERVICE) { Write-Error 'SUPABASE_SERVICE_ROLE env var is not set. Aborting.'; exit 2 }

# Hebrew string "חלק א" built from code points (keeps this source file ASCII)
$HEB_TITLE = [string]::Concat([char]0x05D7, [char]0x05DC, [char]0x05E7, [char]0x20, [char]0x05D0)

# ---- Test bookkeeping ----
$script:pass = 0
$script:fail = 0
$createdUserIds = New-Object System.Collections.Generic.List[string]

function Check($name, $condition, $detail) {
  if ($condition) { Write-Host ("  [PASS] {0}" -f $name) -ForegroundColor Green; $script:pass++ }
  else { Write-Host ("  [FAIL] {0}" -f $name) -ForegroundColor Red; if ($detail) { Write-Host ("         -> {0}" -f $detail) -ForegroundColor DarkYellow }; $script:fail++ }
}

# ---- HTTP helper built on curl.exe: returns Code / Text / Json ----
function Invoke-Http {
  param(
    [string]$Method,
    [string]$Url,
    [hashtable]$Headers,
    [object]$Body,
    [string[]]$ExtraHeaders
  )
  $tmp = $null
  $cargs = @('-s', '-X', $Method, '-w', "`n%{http_code}")
  foreach ($k in $Headers.Keys) { $cargs += '-H'; $cargs += ("{0}: {1}" -f $k, $Headers[$k]) }
  if ($ExtraHeaders) { foreach ($h in $ExtraHeaders) { $cargs += '-H'; $cargs += $h } }
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 25 -Compress
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    $cargs += '-H'; $cargs += 'Content-Type: application/json'
    $cargs += '--data-binary'; $cargs += ("@{0}" -f $tmp)
  }
  $cargs += $Url
  $out = & curl.exe @cargs
  if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  $outStr = ($out -join "`n")
  $idx = $outStr.LastIndexOf("`n")
  if ($idx -ge 0) { $code = [int]($outStr.Substring($idx + 1).Trim()); $bodyText = $outStr.Substring(0, $idx) }
  else { $code = 0; $bodyText = $outStr }
  $obj = $null
  if ($bodyText -and $bodyText.Trim()) { try { $obj = $bodyText | ConvertFrom-Json } catch { $obj = $null } }
  return [pscustomobject]@{ Code = $code; Text = $bodyText; Json = $obj }
}

function New-TestUser($label) {
  $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $email = ("e2e+{0}-{1}@example.com" -f $label, $ts)
  $pass = ("Pw_{0}!aB9" -f $ts)
  $body = @{
    email         = $email
    password      = $pass
    email_confirm = $true
    user_metadata = @{ full_name = ("E2E {0}" -f $label); child_name = ("child-{0}" -f $label); phone = '050-0000000' }
  }
  $h = @{ apikey = $SERVICE; Authorization = ("Bearer {0}" -f $SERVICE) }
  $r = Invoke-Http -Method POST -Url ("{0}/auth/v1/admin/users" -f $BASE) -Headers $h -Body $body
  if ($r.Code -ge 200 -and $r.Code -lt 300 -and $r.Json.id) {
    $createdUserIds.Add($r.Json.id) | Out-Null
    return [pscustomobject]@{ Id = $r.Json.id; Email = $email; Password = $pass }
  }
  throw ("admin createUser failed (HTTP {0}): {1}" -f $r.Code, $r.Text)
}

function Get-UserToken($email, $password) {
  $h = @{ apikey = $ANON }
  $body = @{ email = $email; password = $password }
  $r = Invoke-Http -Method POST -Url ("{0}/auth/v1/token?grant_type=password" -f $BASE) -Headers $h -Body $body
  if ($r.Json.access_token) { return $r.Json.access_token }
  throw ("login failed (HTTP {0}): {1}" -f $r.Code, $r.Text)
}

function Remove-TestUser($id) {
  $h = @{ apikey = $SERVICE; Authorization = ("Bearer {0}" -f $SERVICE) }
  Invoke-Http -Method DELETE -Url ("{0}/auth/v1/admin/users/{1}" -f $BASE, $id) -Headers $h | Out-Null
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " E2E: registered-customer data + questionnaire status (live DB)" -ForegroundColor Cyan
Write-Host ("  Project: {0}" -f $BASE) -ForegroundColor DarkCyan
Write-Host "==================================================================" -ForegroundColor Cyan

try {
  # ============================================================
  # 1) Registration -> profile auto-created by trigger
  # ============================================================
  Write-Host "`n[1] Registration creates auth user + profile (trigger handle_new_user)"
  $u1 = New-TestUser 'main'
  Write-Host ("  created user: {0}  ({1})" -f $u1.Email, $u1.Id) -ForegroundColor DarkGray
  $hSvc = @{ apikey = $SERVICE; Authorization = ("Bearer {0}" -f $SERVICE) }
  $prof = Invoke-Http -Method GET -Url ("{0}/rest/v1/profiles?id=eq.{1}&select=*" -f $BASE, $u1.Id) -Headers $hSvc
  $p = if ($prof.Json) { @($prof.Json)[0] } else { $null }
  Check 'profile row exists for new user'        ($null -ne $p) $prof.Text
  Check 'profile.full_name from signup metadata' ($p -and $p.full_name -eq 'E2E main') ("got '{0}'" -f $p.full_name)
  Check 'profile.child_name from metadata'       ($p -and $p.child_name -eq 'child-main') ("got '{0}'" -f $p.child_name)
  Check 'profile.is_admin defaults false'        ($p -and $p.is_admin -eq $false) ("got '{0}'" -f $p.is_admin)

  # ============================================================
  # 2) Log in as the normal user (RLS context from here on)
  # ============================================================
  Write-Host "`n[2] User login (publishable key, JWT under RLS)"
  $tok1 = Get-UserToken $u1.Email $u1.Password
  Check 'obtained user access_token' ([bool]$tok1) ''
  $hUser1 = @{ apikey = $ANON; Authorization = ("Bearer {0}" -f $tok1) }

  # ============================================================
  # 3) Submission insert (mirrors buildSubmissionBundle/insertBundle)
  # ============================================================
  Write-Host "`n[3] Submission insert -> submissions + question_timings"
  $idem = [guid]::NewGuid().ToString()
  $answersPayload = @{
    submittedAt = ([DateTimeOffset]::UtcNow.ToString('o'))
    appVersion  = 'v6'
    user        = @{ name = 'E2E main'; email = $u1.Email; phone = '050-0000000' }
    summary     = @{ answered = 3; total = 124; durationMinutes = 7 }
    sections    = @(
      @{ title = $HEB_TITLE; items = @(
          @{ type = 'frequency'; number = '1'; question = 'q1'; answer = 3 },
          @{ type = 'agreement'; number = '2'; question = 'q2'; answer = 2 }
        ) },
      @{ title = 'section-b'; items = @(
          @{ type = 'radio_single'; number = '3'; question = 'q3'; answer = 'yes' }
        ) }
    )
  }
  $subBody = @{
    user_id          = $u1.Id
    app_version      = 'v6'
    answers_count    = 3
    questions_total  = 124
    duration_minutes = 7
    answers          = $answersPayload
    idempotency_key  = $idem
  }
  $sub = Invoke-Http -Method POST -Url ("{0}/rest/v1/submissions?select=id" -f $BASE) -Headers $hUser1 -Body $subBody -ExtraHeaders @('Prefer: return=representation')
  $sid = if ($sub.Json) { @($sub.Json)[0].id } else { $null }
  Check 'submission inserted (own user_id, RLS insert allowed)' ($null -ne $sid) ("HTTP {0}: {1}" -f $sub.Code, $sub.Text)

  $timingRows = @(
    @{ submission_id = $sid; user_id = $u1.Id; qid = 'v6:1'; flat_id = 's0_q0'; number = '1'; dwell_ms = 4200; revisit_count = 0; answer_changes = 1; first_seen_at = ([DateTimeOffset]::UtcNow.AddMinutes(-7).ToString('o')); answered_at = ([DateTimeOffset]::UtcNow.AddMinutes(-6).ToString('o')) },
    @{ submission_id = $sid; user_id = $u1.Id; qid = 'v6:2'; flat_id = 's0_q1'; number = '2'; dwell_ms = 3100; revisit_count = 1; answer_changes = 2; first_seen_at = ([DateTimeOffset]::UtcNow.AddMinutes(-6).ToString('o')); answered_at = ([DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')) },
    @{ submission_id = $sid; user_id = $u1.Id; qid = 'v6:3'; flat_id = 's1_q0'; number = '3'; dwell_ms = 5300; revisit_count = 0; answer_changes = 1; first_seen_at = ([DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')); answered_at = ([DateTimeOffset]::UtcNow.AddMinutes(-4).ToString('o')) }
  )
  $tim = Invoke-Http -Method POST -Url ("{0}/rest/v1/question_timings" -f $BASE) -Headers $hUser1 -Body $timingRows -ExtraHeaders @('Prefer: return=minimal')
  Check 'question_timings bulk insert accepted' ($tim.Code -ge 200 -and $tim.Code -lt 300) ("HTTP {0}: {1}" -f $tim.Code, $tim.Text)

  # ============================================================
  # 4) Read-back under the user's own JWT
  # ============================================================
  Write-Host "`n[4] Read-back verifies persisted data"
  $back = Invoke-Http -Method GET -Url ("{0}/rest/v1/submissions?id=eq.{1}&select=id,answers_count,questions_total,duration_minutes,app_version,answers" -f $BASE, $sid) -Headers $hUser1
  $b = if ($back.Json) { @($back.Json)[0] } else { $null }
  Check 'submission readable by owner'   ($null -ne $b) $back.Text
  Check 'answers_count round-trips (3)'  ($b -and $b.answers_count -eq 3) ("got '{0}'" -f $b.answers_count)
  Check 'questions_total round-trips'    ($b -and $b.questions_total -eq 124) ("got '{0}'" -f $b.questions_total)
  Check 'duration_minutes round-trips'   ($b -and $b.duration_minutes -eq 7) ("got '{0}'" -f $b.duration_minutes)
  Check 'answers jsonb preserved (summary.answered=3)' ($b -and $b.answers.summary.answered -eq 3) 'jsonb payload mismatch'
  Check 'answers jsonb preserved (Hebrew unicode round-trip)' ($b -and $b.answers.sections[0].title -eq $HEB_TITLE) 'jsonb unicode mismatch'

  $timBack = Invoke-Http -Method GET -Url ("{0}/rest/v1/question_timings?submission_id=eq.{1}&select=qid,dwell_ms,revisit_count,answer_changes" -f $BASE, $sid) -Headers $hUser1
  $tcount = if ($timBack.Json) { @($timBack.Json).Count } else { 0 }
  Check 'question_timings: 3 rows persisted' ($tcount -eq 3) ("got {0}" -f $tcount)

  # ============================================================
  # 5) Idempotency: duplicate idempotency_key is rejected (23505)
  # ============================================================
  Write-Host "`n[5] Idempotency guard (duplicate idempotency_key)"
  $dup = Invoke-Http -Method POST -Url ("{0}/rest/v1/submissions" -f $BASE) -Headers $hUser1 -Body $subBody -ExtraHeaders @('Prefer: return=minimal')
  $is23505 = ($dup.Code -eq 409) -or ($dup.Text -match '23505')
  Check 'duplicate submission rejected (409 / 23505)' $is23505 ("HTTP {0}: {1}" -f $dup.Code, $dup.Text)
  $afterDup = Invoke-Http -Method GET -Url ("{0}/rest/v1/submissions?user_id=eq.{1}&select=id" -f $BASE, $u1.Id) -Headers $hUser1
  $afterCount = if ($afterDup.Json) { @($afterDup.Json).Count } else { 0 }
  Check 'still exactly 1 submission after duplicate attempt' ($afterCount -eq 1) ("got {0}" -f $afterCount)

  # ============================================================
  # 6) RLS isolation: a second user cannot see user1's data
  # ============================================================
  Write-Host "`n[6] RLS isolation (second registered user)"
  $u2 = New-TestUser 'other'
  $tok2 = Get-UserToken $u2.Email $u2.Password
  $hUser2 = @{ apikey = $ANON; Authorization = ("Bearer {0}" -f $tok2) }
  $cross = Invoke-Http -Method GET -Url ("{0}/rest/v1/submissions?id=eq.{1}&select=id" -f $BASE, $sid) -Headers $hUser2
  $crossCount = if ($cross.Json) { @($cross.Json).Count } else { 0 }
  Check "user2 cannot read user1's submission (RLS)" ($crossCount -eq 0) ("got {0} rows; HTTP {1}" -f $crossCount, $cross.Code)
  $allForU2 = Invoke-Http -Method GET -Url ("{0}/rest/v1/submissions?select=id" -f $BASE) -Headers $hUser2
  $u2all = if ($allForU2.Json) { @($allForU2.Json).Count } else { 0 }
  Check 'user2 sees 0 submissions total (own none)' ($u2all -eq 0) ("got {0}" -f $u2all)

  # ============================================================
  # 7) Live draft: partial answers saved server-side (the gap, now CLOSED)
  # ============================================================
  Write-Host "`n[7] Live draft upsert (partial answers visible before submit)"
  $draftBody = @{
    user_id         = $u1.Id
    status          = 'in_progress'
    answers         = @{ summary = @{ answered = 2; total = 124 }; sections = @( @{ title = $HEB_TITLE; items = @( @{ number = '1'; question = 'q1'; answer = 3 }, @{ number = '2'; question = 'q2'; answer = 2 } ) } ) }
    answered_count  = 2
    current_index   = 5
    last_qid        = 'v6:2'
    total_questions = 124
    app_version     = 'v6'
  }
  $dput = Invoke-Http -Method POST -Url ("{0}/rest/v1/submission_drafts?on_conflict=user_id" -f $BASE) -Headers $hUser1 -Body $draftBody -ExtraHeaders @('Prefer: resolution=merge-duplicates,return=minimal')
  Check 'draft upserted by owner (in_progress)' ($dput.Code -ge 200 -and $dput.Code -lt 300) ("HTTP {0}: {1}" -f $dput.Code, $dput.Text)
  $dRead = Invoke-Http -Method GET -Url ("{0}/rest/v1/submission_drafts?user_id=eq.{1}&select=status,answered_count,last_qid,answers" -f $BASE, $u1.Id) -Headers $hUser1
  $dr = if ($dRead.Json) { @($dRead.Json)[0] } else { $null }
  Check 'draft status = in_progress'                 ($dr -and $dr.status -eq 'in_progress') ("got '{0}'" -f $dr.status)
  Check 'draft answered_count = 2'                   ($dr -and $dr.answered_count -eq 2) ("got '{0}'" -f $dr.answered_count)
  Check 'draft last_qid = v6:2'                       ($dr -and $dr.last_qid -eq 'v6:2') ("got '{0}'" -f $dr.last_qid)
  Check 'partial answers jsonb persisted (Hebrew)'   ($dr -and $dr.answers.sections[0].title -eq $HEB_TITLE) 'jsonb mismatch'

  # ============================================================
  # 8) Re-upsert updates in place (one row per user)
  # ============================================================
  Write-Host "`n[8] Draft re-upsert updates in place"
  $draftBody.answered_count = 5; $draftBody.current_index = 12; $draftBody.last_qid = 'v6:5'
  $draftBody.answers.summary.answered = 5
  $reup = Invoke-Http -Method POST -Url ("{0}/rest/v1/submission_drafts?on_conflict=user_id" -f $BASE) -Headers $hUser1 -Body $draftBody -ExtraHeaders @('Prefer: resolution=merge-duplicates,return=minimal')
  Check 're-upsert accepted' ($reup.Code -ge 200 -and $reup.Code -lt 300) ("HTTP {0}: {1}" -f $reup.Code, $reup.Text)
  $dCount = Invoke-Http -Method GET -Url ("{0}/rest/v1/submission_drafts?user_id=eq.{1}&select=answered_count" -f $BASE, $u1.Id) -Headers $hUser1
  $dcArr = @(); if ($dCount.Json) { $dcArr = @($dCount.Json) }
  $dcN = $dcArr.Count
  Check 'still exactly 1 draft row (PK on user_id)'  ($dcN -eq 1) ("got {0}; HTTP {1}; body {2}" -f $dcN, $dCount.Code, $dCount.Text)
  $dcAnswered = if ($dcN -ge 1) { $dcArr[0].answered_count } else { $null }
  Check 'draft answered_count updated to 5'          ($dcAnswered -eq 5) ("got '{0}'" -f $dcAnswered)

  # ============================================================
  # 9) RLS: non-admin user cannot see another user's draft
  # ============================================================
  Write-Host "`n[9] RLS: non-admin user2 cannot read user1 draft"
  $d_u2 = Invoke-Http -Method GET -Url ("{0}/rest/v1/submission_drafts?user_id=eq.{1}&select=user_id" -f $BASE, $u1.Id) -Headers $hUser2
  $d_u2c = if ($d_u2.Json) { @($d_u2.Json).Count } else { 0 }
  Check 'non-admin cannot read another draft (RLS)'  ($d_u2c -eq 0) ("got {0} rows" -f $d_u2c)

  # ============================================================
  # 10) Admin transparency: promote user2 -> sees user1 draft + ALL answers
  # ============================================================
  Write-Host "`n[10] Admin transparency (full live-answer visibility)"
  Invoke-Http -Method PATCH -Url ("{0}/rest/v1/profiles?id=eq.{1}" -f $BASE, $u2.Id) -Headers $hSvc -Body @{ is_admin = $true } -ExtraHeaders @('Prefer: return=minimal') | Out-Null
  $d_admin = Invoke-Http -Method GET -Url ("{0}/rest/v1/submission_drafts?user_id=eq.{1}&select=answers,answered_count,status" -f $BASE, $u1.Id) -Headers $hUser2
  $da = if ($d_admin.Json) { @($d_admin.Json)[0] } else { $null }
  Check 'admin sees the other user draft'            ($null -ne $da) ("HTTP {0}: {1}" -f $d_admin.Code, $d_admin.Text)
  Check 'admin reads full partial answers (Hebrew)'  ($da -and $da.answers.sections[0].title -eq $HEB_TITLE) 'admin cannot read answers'

  # ============================================================
  # 11) Admin funnel RPCs (is_admin gated)
  # ============================================================
  Write-Host "`n[11] Admin funnel RPCs"
  $rpcAdmin = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/admin_funnel_overview" -f $BASE) -Headers $hUser2 -Body @{}
  $fa = if ($rpcAdmin.Json) { @($rpcAdmin.Json)[0] } else { $null }
  Check 'admin_funnel_overview returns a row for admin' ($null -ne $fa) ("HTTP {0}: {1}" -f $rpcAdmin.Code, $rpcAdmin.Text)
  Check 'funnel.started >= 1'                         ($fa -and [int]$fa.started -ge 1) ("got '{0}'" -f $fa.started)
  $rpcNon = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/admin_funnel_overview" -f $BASE) -Headers $hUser1 -Body @{}
  $fnCount = if ($rpcNon.Json) { @($rpcNon.Json).Count } else { 0 }
  Check 'non-admin gets empty funnel (is_admin guard)' ($fnCount -eq 0) ("got {0} rows" -f $fnCount)

  # ============================================================
  # 12) Trigger: a new submission flips the draft to 'submitted'
  # ============================================================
  Write-Host "`n[12] Submit trigger flips draft -> submitted"
  $sub2 = $subBody.Clone()
  $sub2.idempotency_key = [guid]::NewGuid().ToString()
  $s2 = Invoke-Http -Method POST -Url ("{0}/rest/v1/submissions?select=id" -f $BASE) -Headers $hUser1 -Body $sub2 -ExtraHeaders @('Prefer: return=representation')
  Check 'second submission inserted' (($s2.Json) -and @($s2.Json)[0].id) ("HTTP {0}: {1}" -f $s2.Code, $s2.Text)
  $dFinal = Invoke-Http -Method GET -Url ("{0}/rest/v1/submission_drafts?user_id=eq.{1}&select=status" -f $BASE, $u1.Id) -Headers $hUser1
  $df = if ($dFinal.Json) { @($dFinal.Json)[0] } else { $null }
  Check 'trigger flipped draft status to submitted'  ($df -and $df.status -eq 'submitted') ("got '{0}'" -f $df.status)

  # ============================================================
  # 14) admin_set_admin RPC (u2 is admin from section 10)
  # ============================================================
  Write-Host "`n[14] admin_set_admin RPC (promote / demote / guards)"
  $setOn = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/admin_set_admin" -f $BASE) -Headers $hUser2 -Body @{ target = $u1.Id; make_admin = $true }
  Check 'admin promotes user1 (HTTP 2xx)' ($setOn.Code -ge 200 -and $setOn.Code -lt 300) ("HTTP {0}: {1}" -f $setOn.Code, $setOn.Text)
  $chk1 = Invoke-Http -Method GET -Url ("{0}/rest/v1/profiles?id=eq.{1}&select=is_admin" -f $BASE, $u1.Id) -Headers $hSvc
  Check 'user1 is_admin = true after promote' (($chk1.Json) -and @($chk1.Json)[0].is_admin -eq $true) $chk1.Text
  $setOff = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/admin_set_admin" -f $BASE) -Headers $hUser2 -Body @{ target = $u1.Id; make_admin = $false }
  $chk2 = Invoke-Http -Method GET -Url ("{0}/rest/v1/profiles?id=eq.{1}&select=is_admin" -f $BASE, $u1.Id) -Headers $hSvc
  Check 'user1 is_admin = false after demote' (($chk2.Json) -and @($chk2.Json)[0].is_admin -eq $false) $chk2.Text
  $setNoauth = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/admin_set_admin" -f $BASE) -Headers $hUser1 -Body @{ target = $u2.Id; make_admin = $false }
  Check 'non-admin cannot call admin_set_admin' ($setNoauth.Code -ge 400) ("HTTP {0}: {1}" -f $setNoauth.Code, $setNoauth.Text)
  $setSelf = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/admin_set_admin" -f $BASE) -Headers $hUser2 -Body @{ target = $u2.Id; make_admin = $false }
  Check 'self-demotion blocked' (($setSelf.Code -ge 400) -or ($setSelf.Text -match 'own admin role')) ("HTTP {0}: {1}" -f $setSelf.Code, $setSelf.Text)

  # ============================================================
  # 15) users_overview (admin sees all + status; non-admin sees self only)
  # ============================================================
  Write-Host "`n[15] users_overview"
  $uoAdmin = Invoke-Http -Method GET -Url ("{0}/rest/v1/users_overview?select=id,is_admin,draft_status,submissions_count" -f $BASE) -Headers $hUser2
  $uoA = @(); if ($uoAdmin.Json) { $uoA = @($uoAdmin.Json) }
  Check 'admin sees >= 2 users in overview' ($uoA.Count -ge 2) ("got {0}" -f $uoA.Count)
  $u1row = $uoA | Where-Object { $_.id -eq $u1.Id } | Select-Object -First 1
  Check 'overview exposes submissions_count for user1' ($u1row -and [int]$u1row.submissions_count -ge 1) ("got '{0}'" -f $(if($u1row){$u1row.submissions_count}))
  $uoUser = Invoke-Http -Method GET -Url ("{0}/rest/v1/users_overview?select=id" -f $BASE) -Headers $hUser1
  $uoU = @(); if ($uoUser.Json) { $uoU = @($uoUser.Json) }
  Check 'non-admin sees only self in overview' ($uoU.Count -eq 1 -and $uoU[0].id -eq $u1.Id) ("got {0} rows" -f $uoU.Count)

  # ============================================================
  # 16) Audit log (log_admin_access + RLS)
  # ============================================================
  Write-Host "`n[16] Audit log"
  $logc = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/log_admin_access" -f $BASE) -Headers $hUser2 -Body @{ action = 'view_submission'; target_user = $u1.Id; target_submission = $sid; meta = @{} }
  Check 'admin can log_admin_access (HTTP 2xx)' ($logc.Code -ge 200 -and $logc.Code -lt 300) ("HTTP {0}: {1}" -f $logc.Code, $logc.Text)
  $logRead = Invoke-Http -Method GET -Url ("{0}/rest/v1/admin_access_log?select=action,target_user_id&order=created_at.desc" -f $BASE) -Headers $hUser2
  $logRows = if ($logRead.Json) { @($logRead.Json) } else { @() }
  Check 'admin reads audit log (has view + set_admin rows)' ($logRows.Count -ge 2 -and ($logRows.action -contains 'view_submission') -and ($logRows.action -contains 'set_admin')) ("rows={0}" -f $logRows.Count)
  $logNoauth = Invoke-Http -Method POST -Url ("{0}/rest/v1/rpc/log_admin_access" -f $BASE) -Headers $hUser1 -Body @{ action = 'view_submission'; target_user = $u1.Id; target_submission = $sid; meta = @{} }
  Check 'non-admin cannot log_admin_access' ($logNoauth.Code -ge 400) ("HTTP {0}: {1}" -f $logNoauth.Code, $logNoauth.Text)
  $logReadU1 = Invoke-Http -Method GET -Url ("{0}/rest/v1/admin_access_log?select=id" -f $BASE) -Headers $hUser1
  $logU1 = if ($logReadU1.Json) { @($logReadU1.Json).Count } else { 0 }
  Check 'non-admin cannot read audit log (RLS)' ($logU1 -eq 0) ("got {0} rows" -f $logU1)

  # ============================================================
  # 17) submissions_with_user is RLS-safe (security_invoker)
  # ============================================================
  Write-Host "`n[17] submissions_with_user RLS (security_invoker fix)"
  $swuAdmin = Invoke-Http -Method GET -Url ("{0}/rest/v1/submissions_with_user?user_id=eq.{1}&select=id,parent_email" -f $BASE, $u1.Id) -Headers $hUser2
  $swuA = if ($swuAdmin.Json) { @($swuAdmin.Json) } else { @() }
  Check 'admin sees user1 submission via view' ($swuA.Count -ge 1) ("got {0}; HTTP {1}" -f $swuA.Count, $swuAdmin.Code)
  # Demote u2 (service_role) -> now a non-admin that owns no submissions -> must see 0 via the view
  Invoke-Http -Method PATCH -Url ("{0}/rest/v1/profiles?id=eq.{1}" -f $BASE, $u2.Id) -Headers $hSvc -Body @{ is_admin = $false } -ExtraHeaders @('Prefer: return=minimal') | Out-Null
  $swuNon = Invoke-Http -Method GET -Url ("{0}/rest/v1/submissions_with_user?select=id" -f $BASE) -Headers $hUser2
  $swuN = if ($swuNon.Json) { @($swuNon.Json).Count } else { 0 }
  Check 'demoted non-admin sees 0 submissions via view (RLS applies)' ($swuN -eq 0) ("got {0} rows" -f $swuN)

  # ============================================================
  # 18) Google-style signup: trigger name fallback + child_name completion
  # ============================================================
  Write-Host "`n[18] OAuth-style signup (name fallback) + complete-profile update"
  $ts3 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $email3 = ("e2e+oauth-{0}@example.com" -f $ts3); $pass3 = ("Pw_{0}!aB9" -f $ts3)
  # Simulate Google: metadata has 'name' (not 'full_name'), no child_name
  $cre = Invoke-Http -Method POST -Url ("{0}/auth/v1/admin/users" -f $BASE) -Headers $hSvc -Body @{ email = $email3; password = $pass3; email_confirm = $true; user_metadata = @{ name = 'OAuth Tester' } }
  $uid3 = if ($cre.Json) { $cre.Json.id } else { $null }
  Check 'oauth-style user created' ($null -ne $uid3) ("HTTP {0}: {1}" -f $cre.Code, $cre.Text)
  if ($uid3) { $createdUserIds.Add($uid3) | Out-Null }
  $p3 = Invoke-Http -Method GET -Url ("{0}/rest/v1/profiles?id=eq.{1}&select=full_name,child_name" -f $BASE, $uid3) -Headers $hSvc
  $p3r = if ($p3.Json) { @($p3.Json)[0] } else { $null }
  Check 'trigger name-fallback: full_name = metadata.name' ($p3r -and $p3r.full_name -eq 'OAuth Tester') ("got '{0}'" -f $(if($p3r){$p3r.full_name}))
  Check 'oauth signup has empty child_name' ($p3r -and $p3r.child_name -eq '') ("got '{0}'" -f $(if($p3r){$p3r.child_name}))
  # Complete-profile flow: user updates own child_name under RLS
  $tok3 = Get-UserToken $email3 $pass3
  $hUser3 = @{ apikey = $ANON; Authorization = ("Bearer {0}" -f $tok3) }
  $cpUpd = Invoke-Http -Method PATCH -Url ("{0}/rest/v1/profiles?id=eq.{1}" -f $BASE, $uid3) -Headers $hUser3 -Body @{ child_name = 'Dana'; phone = '050-1112222' } -ExtraHeaders @('Prefer: return=representation')
  Check 'user updates own child_name (RLS)' ($cpUpd.Code -ge 200 -and $cpUpd.Code -lt 300) ("HTTP {0}: {1}" -f $cpUpd.Code, $cpUpd.Text)
  $p3b = Invoke-Http -Method GET -Url ("{0}/rest/v1/profiles?id=eq.{1}&select=child_name" -f $BASE, $uid3) -Headers $hUser3
  $p3br = if ($p3b.Json) { @($p3b.Json)[0] } else { $null }
  Check 'child_name persisted = Dana' ($p3br -and $p3br.child_name -eq 'Dana') ("got '{0}'" -f $(if($p3br){$p3br.child_name}))
}
catch {
  Write-Host ("`n[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
  $script:fail++
}
finally {
  # ============================================================
  # 13) Cleanup: hard-delete test users (cascades to profiles/submissions/timings/drafts)
  # ============================================================
  Write-Host "`n[13] Cleanup (delete test users; cascade removes their data)"
  foreach ($id in $createdUserIds) {
    try { Remove-TestUser $id; Write-Host ("  deleted user {0}" -f $id) -ForegroundColor DarkGray }
    catch { Write-Host ("  cleanup failed for {0}: {1}" -f $id, $_.Exception.Message) -ForegroundColor Red }
  }
  if ($createdUserIds.Count -gt 0) {
    $check = Invoke-Http -Method GET -Url ("{0}/rest/v1/profiles?id=eq.{1}&select=id" -f $BASE, $createdUserIds[0]) -Headers @{ apikey = $SERVICE; Authorization = ("Bearer {0}" -f $SERVICE) }
    $left = if ($check.Json) { @($check.Json).Count } else { 0 }
    Check 'cleanup verified (profile gone)' ($left -eq 0) ("rows left: {0}" -f $left)
  }
}

Write-Host "`n==================================================================" -ForegroundColor Cyan
$resultColor = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
Write-Host (" RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $resultColor
Write-Host "==================================================================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
