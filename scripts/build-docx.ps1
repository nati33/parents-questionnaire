$ErrorActionPreference = "Stop"

# Build v5 .docx — apply all the user's requested changes from v4:
#  - Remove parent-age background questions (gil ha-hore)
#  - Q14: כן → לא
#  - Q73: rephrase to "חומרת מעשיו"
#  - Q75 (pipi) → "מרטיב/ה במיטה"
#  - Add 2 new Qs at end of ו׳ (risk evaluation + repeating dangerous)
#  - Add 1 new Q after Q91 (competitive emotion)
#  - Q93: remove "לעומת זאת"
#  - Q94: rephrase to "תחושות של חוסר ביטחון..."
#  - Q98: rephrase to "מתקשה להירדם... מלווה בתסכול..."
#  - Remove Q115 (duplicate compassion)
#  - Section יד׳: remove open Q1, change open Q2 and Q5 to checkbox lists
#  - Renumber all rating questions sequentially

$sourceFile = "שאלון הורים 5-10 - גרסה 4.docx"
$outFile = "שאלון הורים 5-10 - גרסה 5.docx"
$workZip = "_work5.zip"
$workDir = "_work5"

if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
if (Test-Path $workZip) { Remove-Item -Force $workZip }
Copy-Item -Path $sourceFile -Destination $workZip -Force
Expand-Archive -Path $workZip -DestinationPath $workDir

$docXmlPath = Join-Path $workDir "word\document.xml"
$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.Load($docXmlPath)
$nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$nsm.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
$wNs = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
$body = $xml.SelectSingleNode("//w:body", $nsm)

function Get-ParaText($p) {
    $ts = $p.SelectNodes(".//w:t", $nsm)
    $s = ""
    foreach ($t in $ts) { $s += $t.InnerText }
    return $s
}

function Get-QuestionNumber($tbl) {
    $firstP = $tbl.SelectSingleNode(".//w:p", $nsm)
    if ($firstP -eq $null) { return $null }
    $text = Get-ParaText $firstP
    if ($text -match "^(\d+)\.") { return [int]$matches[1] } else { return $null }
}

function Set-QuestionNumber($tbl, $newNum) {
    $firstP = $tbl.SelectSingleNode(".//w:p", $nsm)
    $ts = $firstP.SelectNodes(".//w:t", $nsm)
    if ($ts.Count -gt 0 -and $ts[0].InnerText -match "^\d+\.") {
        $ts[0].InnerText = ($ts[0].InnerText -replace "^\d+\.", "$newNum.")
    }
}

function Set-QuestionText($tbl, $newText) {
    $firstP = $tbl.SelectSingleNode(".//w:p", $nsm)
    $runs = $firstP.SelectNodes(".//w:r", $nsm)
    if ($runs.Count -lt 2) { return }
    # Keep first run ("NN. "), set second run to new text, remove rest
    $secondT = $runs[1].SelectSingleNode(".//w:t", $nsm)
    if ($secondT) { $secondT.InnerText = $newText }
    for ($i = $runs.Count - 1; $i -ge 2; $i--) {
        $firstP.RemoveChild($runs[$i]) | Out-Null
    }
}

# ----- STEP 0: Split any merged rating tables -----
$tablesToSplit = @()
$inOpen = $false
foreach ($c in $body.ChildNodes) {
    if ($c.LocalName -eq "p" -and (Get-ParaText $c) -match "^חלק יד׳") { $inOpen = $true }
    if ($inOpen) { continue }
    if ($c.LocalName -eq "tbl") {
        $rows = @($c.SelectNodes("./w:tr", $nsm))
        if ($rows.Count -gt 2) {
            $qPCount = 0
            foreach ($r in $rows) {
                foreach ($p in $r.SelectNodes(".//w:p", $nsm)) {
                    if ((Get-ParaText $p) -match "^\d+\. ") { $qPCount++ }
                }
            }
            if ($qPCount -gt 1) { $tablesToSplit += $c }
        }
    }
}
foreach ($tbl in $tablesToSplit) {
    $rows = @($tbl.SelectNodes("./w:tr", $nsm))
    $tblPr = $tbl.SelectSingleNode("./w:tblPr", $nsm)
    $tblGrid = $tbl.SelectSingleNode("./w:tblGrid", $nsm)
    $parent = $tbl.ParentNode
    for ($i = 0; $i -lt $rows.Count; $i += 2) {
        $newTbl = $xml.CreateElement("w", "tbl", $wNs)
        if ($tblPr) { $newTbl.AppendChild($tblPr.CloneNode($true)) | Out-Null }
        if ($tblGrid) { $newTbl.AppendChild($tblGrid.CloneNode($true)) | Out-Null }
        $newTbl.AppendChild($rows[$i].CloneNode($true)) | Out-Null
        if ($i + 1 -lt $rows.Count) { $newTbl.AppendChild($rows[$i + 1].CloneNode($true)) | Out-Null }
        $parent.InsertBefore($newTbl, $tbl) | Out-Null
    }
    $parent.RemoveChild($tbl) | Out-Null
}
Write-Output ("Split " + $tablesToSplit.Count + " merged tables.")

# ----- STEP 1: Remove parent age lines from section א׳ -----
# Background section has paragraphs like:
#   גיל ההורה הממלא/ת:  ______________________________________________
#   גיל ההורה השני/ה:  ______________________________________________
# We remove those two paragraphs.
$toRemove = @()
foreach ($p in $body.SelectNodes(".//w:p", $nsm)) {
    $t = Get-ParaText $p
    if ($t -match "^גיל ההורה הממלא" -or $t -match "^גיל ההורה השני") {
        $toRemove += $p
    }
}
foreach ($p in $toRemove) { $p.ParentNode.RemoveChild($p) | Out-Null }
Write-Output ("Removed " + $toRemove.Count + " parent-age paragraphs.")

# ----- STEP 2: Find templates needed for additions -----
# Need: rating question table template (use Q24 in v4 = a clean 2-row table)
$templateTbl = $null
foreach ($c in $body.ChildNodes) {
    if ($c.LocalName -eq "tbl") {
        $rows = @($c.SelectNodes("./w:tr", $nsm))
        if ($rows.Count -ne 2) { continue }
        $n = Get-QuestionNumber $c
        if ($n -eq 24 -and $templateTbl -eq $null) { $templateTbl = $c; break }
    }
}
if ($templateTbl -eq $null) { throw "Template (Q24) not found" }

function New-QuestionTable($num, $text) {
    $clone = $templateTbl.CloneNode($true)
    $firstP = $clone.SelectSingleNode(".//w:p", $nsm)
    $runs = $firstP.SelectNodes(".//w:r", $nsm)
    $firstT = $runs[0].SelectSingleNode(".//w:t", $nsm)
    $firstT.InnerText = "$num. "
    for ($i = $runs.Count - 1; $i -ge 1; $i--) {
        $firstP.RemoveChild($runs[$i]) | Out-Null
    }
    $newR = $xml.CreateElement("w", "r", $wNs)
    $newRPr = $xml.CreateElement("w", "rPr", $wNs)
    $rtl = $xml.CreateElement("w", "rtl", $wNs)
    $newRPr.AppendChild($rtl) | Out-Null
    $newR.AppendChild($newRPr) | Out-Null
    $newT = $xml.CreateElement("w", "t", $wNs)
    $newT.InnerText = $text
    $newR.AppendChild($newT) | Out-Null
    $firstP.AppendChild($newR) | Out-Null
    $pageBreaks = $clone.SelectNodes(".//w:lastRenderedPageBreak", $nsm)
    foreach ($pb in $pageBreaks) { $pb.ParentNode.RemoveChild($pb) | Out-Null }
    return $clone
}

# ----- STEP 3: Apply text modifications to specific questions BY ORIGINAL number -----
$textModifications = @{
    14 = "הילד/ה מתפרץ/ת בכעס עז כשאומרים לו/ה ״לא״"
    73 = "הילד/ה לא מבין/ה את חומרת מעשיו/ה, בקרות אירוע, מתוך חוסר הבנה של הסיטואציה"
    75 = "הילד/ה מרטיב/ה במיטה בלילה"
    93 = "בתחומי העניין שלו/ה, הילד/ה מגלה מסוגלות פיזית טובה (ריכוז, ישיבה ממושכת, שליטה גופנית)"
    94 = "תחושות של חוסר ביטחון לימודי מעסיקות את הילד/ה ומשפיעות על התמודדותו/ה עם משימות לימודיות"
    98 = "הילד/ה מתקשה להירדם (לרוב מעל 30 דקות), וההירדמות מלווה בתסכול, מצוקה או תלות באחר"
}

foreach ($c in $body.ChildNodes) {
    if ($c.LocalName -eq "tbl") {
        $n = Get-QuestionNumber $c
        if ($n -ne $null -and $textModifications.ContainsKey($n)) {
            Set-QuestionText $c $textModifications[$n]
        }
    }
}
Write-Output "Applied text modifications."

# ----- STEP 4: Define removals, insertions -----
$removeNumbers = @(115)
$insertionsAfter = @{
    74 = @(
        "הילד/ה מתקשה להעריך סכנות או השלכות אפשריות לפני פעולה",
        "הילד/ה חוזר/ת על פעולות מסוכנות למרות שהסבירו את הסכנה או איסור לבצע פעולות אלו"
    )
    91 = @(
        "הילד/ה מושפע/ת רגשית מהצלחה או כישלון בפעילויות תחרותיות (כגון ספורט, משחקים או תחביבים)"
    )
}

# ----- STEP 5: Walk body, renumber, remove, insert -----
$children = @($body.ChildNodes)
$newChildren = New-Object System.Collections.Generic.List[System.Xml.XmlNode]
$counter = 0
$reachedOpen = $false

for ($i = 0; $i -lt $children.Count; $i++) {
    $c = $children[$i]
    if ($c.LocalName -eq "p" -and (Get-ParaText $c) -match "^חלק יד׳") { $reachedOpen = $true }

    if (-not $reachedOpen -and $c.LocalName -eq "tbl") {
        $origNum = Get-QuestionNumber $c
        if ($origNum -ne $null) {
            if ($removeNumbers -contains $origNum) {
                continue  # skip removed questions
            }
            $counter++
            Set-QuestionNumber $c $counter
            $newChildren.Add($c) | Out-Null
            if ($insertionsAfter.ContainsKey($origNum)) {
                foreach ($txt in $insertionsAfter[$origNum]) {
                    $counter++
                    $newQ = New-QuestionTable $counter $txt
                    $newChildren.Add($newQ) | Out-Null
                }
            }
            continue
        }
    }
    $newChildren.Add($c) | Out-Null
}

while ($body.HasChildNodes) { $body.RemoveChild($body.FirstChild) | Out-Null }
foreach ($n in $newChildren) { $body.AppendChild($n) | Out-Null }
Write-Output ("Total rating questions: " + $counter)

# ----- STEP 6: Rebuild section יד׳ -----
# In v4, open section has:
#   "חלק יד׳" header + intro para + 6 open Qs (each = paragraph "N. ..." + answer table + separator)
#   Then closing "תודה רבה" + "...." paragraphs
#
# v5 changes for יד׳:
#   - REMOVE the "מה הילד הכי אוהב לעשות?" question (was open Q1)
#   - CHANGE the remaining open questions to:
#       Q1 = main difficulty (was open Q2) → as checkbox-style with 20 options
#       Q2 = school struggle reasons (was open Q3) — keep as open
#       Q3 = traumatic event (was open Q4) — keep as open
#       Q4 = what to gain (was open Q5) → as checkbox-style with 20 options
#       Q5 = anything else (was open Q6) — keep as open
#       Q6 = 1-3 changes (was open Q7) — keep as open

$children = @($body.ChildNodes)
$openHeaderIdx = -1
$instructionIdx = -1
$thanksIdx = -1
$dotsIdx = -1
$sectPrIdx = -1
for ($i = 0; $i -lt $children.Count; $i++) {
    $c = $children[$i]
    if ($c.LocalName -eq "p") {
        $t = Get-ParaText $c
        if ($openHeaderIdx -eq -1 -and $t -match "^חלק יד׳") { $openHeaderIdx = $i }
        elseif ($openHeaderIdx -ne -1 -and $instructionIdx -eq -1 -and $t -match "החלק הזה הוא מקום לשתף") { $instructionIdx = $i }
        elseif ($t -match "תודה רבה על המילוי") { $thanksIdx = $i }
        elseif ($t -eq "...." -or $t -eq " ....") { $dotsIdx = $i }
    }
    if ($c.LocalName -eq "sectPr") { $sectPrIdx = $i }
}
if ($openHeaderIdx -eq -1) { throw "Open section header not found" }

# Find templates for open question paragraph + answer table + separator
$qParaTemplate = $null
$qTblTemplate = $null
$separatorTemplate = $null
for ($i = $openHeaderIdx + 1; $i -lt $children.Count; $i++) {
    $c = $children[$i]
    if ($c.LocalName -eq "p") {
        $t = Get-ParaText $c
        if ($qParaTemplate -eq $null -and $t -match "^\d+\. ") { $qParaTemplate = $c }
        elseif ($separatorTemplate -eq $null -and $t -eq "" -and $qParaTemplate -ne $null -and $qTblTemplate -ne $null) { $separatorTemplate = $c }
    }
    if ($c.LocalName -eq "tbl" -and $qTblTemplate -eq $null -and $qParaTemplate -ne $null) {
        $rows = @($c.SelectNodes("./w:tr", $nsm))
        if ($rows.Count -eq 4) { $qTblTemplate = $c }
    }
    if ($qParaTemplate -and $qTblTemplate -and $separatorTemplate) { break }
}
if (-not ($qParaTemplate -and $qTblTemplate -and $separatorTemplate)) { throw "Open Q templates not found" }

function New-OpenQParagraph([string]$num, [string]$text) {
    $clone = $qParaTemplate.CloneNode($true)
    $ts = $clone.SelectNodes(".//w:t", $nsm)
    if ($ts.Count -gt 0) {
        $ts[0].InnerText = "$num. $text"
        for ($i = 1; $i -lt $ts.Count; $i++) { $ts[$i].InnerText = "" }
    }
    return $clone
}
function New-AnswerTable() { return $qTblTemplate.CloneNode($true) }
function New-Separator() { return $separatorTemplate.CloneNode($true) }

function New-CheckboxParagraph([string]$num, [string]$text) {
    # Question header paragraph
    return (New-OpenQParagraph $num $text)
}
function New-OptionsParagraph([string[]]$options) {
    # Plain RTL paragraph listing options with ☐
    $p = $xml.CreateElement("w", "p", $wNs)
    $pPr = $xml.CreateElement("w", "pPr", $wNs)
    $bidi = $xml.CreateElement("w", "bidi", $wNs)
    $pPr.AppendChild($bidi) | Out-Null
    $jc = $xml.CreateElement("w", "jc", $wNs)
    $jc.SetAttribute("val", $wNs, "right") | Out-Null
    $pPr.AppendChild($jc) | Out-Null
    $p.AppendChild($pPr) | Out-Null

    $optionsText = ($options | ForEach-Object { "☐ $_" }) -join "    "
    $r = $xml.CreateElement("w", "r", $wNs)
    $rPr = $xml.CreateElement("w", "rPr", $wNs)
    $rtl = $xml.CreateElement("w", "rtl", $wNs)
    $rPr.AppendChild($rtl) | Out-Null
    $r.AppendChild($rPr) | Out-Null
    $t = $xml.CreateElement("w", "t", $wNs)
    $spaceAttr = $xml.CreateAttribute("xml", "space", "http://www.w3.org/XML/1998/namespace")
    $spaceAttr.Value = "preserve"
    $t.Attributes.Append($spaceAttr) | Out-Null
    $t.InnerText = $optionsText
    $r.AppendChild($t) | Out-Null
    $p.AppendChild($r) | Out-Null
    return $p
}

# Define the new יד׳ section content
$difficultyOptions = @(
    "חרדה / פחדים",
    "תוקפנות / אלימות",
    "קושי בוויסות רגשי (התפרצויות)",
    "קושי חברתי / חרם",
    "שימוש מוגזם במסכים / התמכרות",
    "הפרעות שינה",
    "קושי במסגרת החינוכית",
    "דימוי עצמי שלילי / חוסר ביטחון",
    "קושי בריכוז / תפקודי קשב",
    "קושי בתפקודים ניהוליים (ארגון, יזימה)",
    "התנהגות מתנגדת / חוצפה",
    "חוסר גמישות / נוקשות",
    "רגישות סנסורית",
    "תלונות גופניות (כאבי בטן/ראש)",
    "הרטבה / רגרסיה",
    "תלות יתר בהורה",
    "קושי בלימודים / השוואה",
    "דאגה ממראה / משקל",
    "דריכות / מתח כללי",
    "אחר"
)

$gainOptions = @(
    "הפחתה של התפרצויות זעם",
    "שיפור היכולת לבטא רגשות",
    "שיפור היחסים החברתיים",
    "חיזוק דימוי עצמי וביטחון",
    "שיפור תפקוד במסגרת החינוכית",
    "הפחתת חרדה / פחדים",
    "שיפור איכות השינה",
    "הפחתת זמן מסכים / איזון בשימוש",
    "שיפור היחסים בבית",
    "כלים להורות מותאמת",
    "שיפור התמודדות עם תסכול",
    "שיפור היכולת לקבל גבולות",
    "חיזוק העצמאות",
    "שיפור היחסים בין האחים",
    "הפחתת חרם / שיפור קשרים חברתיים",
    "שיפור היכולת לבקש עזרה",
    "חיבור לחוזקות ותחומי עניין",
    "כלים להתמודדות עם אירוע משמעותי / טראומה",
    "שיפור הוויסות העצמי הרגשי",
    "אחר"
)

# Rebuild: keep header + instruction, then build 6 new items
$newChildren = New-Object System.Collections.Generic.List[System.Xml.XmlNode]
for ($i = 0; $i -le $openHeaderIdx; $i++) { $newChildren.Add($children[$i]) | Out-Null }
if ($instructionIdx -ne -1) { $newChildren.Add($children[$instructionIdx]) | Out-Null }

# Q1: checkbox (main difficulty)
$newChildren.Add((New-CheckboxParagraph "1" "מה הקושי המרכזי שמעסיק אתכם כיום בקשר לילד/ה? (סמנו כמה שרלוונטי)")) | Out-Null
$newChildren.Add((New-OptionsParagraph $difficultyOptions)) | Out-Null
$newChildren.Add((New-Separator)) | Out-Null

# Q2: open (school struggle)
$newChildren.Add((New-OpenQParagraph "2" "אם יש מאבק יומיומי על היציאה למסגרת — כיצד אתם מסבירים לעצמכם את הסיבות העיקריות? (התנהגותי / רגשי / קושי בתפקודים ניהוליים / לוגיסטי / משהו אחר — תארו)")) | Out-Null
$newChildren.Add((New-AnswerTable)) | Out-Null
$newChildren.Add((New-Separator)) | Out-Null

# Q3: open (traumatic event)
$newChildren.Add((New-OpenQParagraph "3" "האם יש אירוע טראומתי, תקופה או שינוי משמעותי שכדאי שנדע עליו?")) | Out-Null
$newChildren.Add((New-AnswerTable)) | Out-Null
$newChildren.Add((New-Separator)) | Out-Null

# Q4: checkbox (what to gain)
$newChildren.Add((New-CheckboxParagraph "4" "מה הייתם רוצים שאתם ו/או הילד/ה ירוויח/תרוויח מהתהליך הזה? (סמנו כמה שרלוונטי)")) | Out-Null
$newChildren.Add((New-OptionsParagraph $gainOptions)) | Out-Null
$newChildren.Add((New-Separator)) | Out-Null

# Q5: open (anything else)
$newChildren.Add((New-OpenQParagraph "5" "משהו נוסף שלא נשאל כאן ושאתם מרגישים שחשוב שנדע?")) | Out-Null
$newChildren.Add((New-AnswerTable)) | Out-Null
$newChildren.Add((New-Separator)) | Out-Null

# Q6: open (1-3 changes)
$newChildren.Add((New-OpenQParagraph "6" "אם הייתם צריכים להגדיר 1–3 שינויים מרכזיים שאתם רוצים שיקרו בסיום התהליך — מה הם?")) | Out-Null
$newChildren.Add((New-AnswerTable)) | Out-Null
$newChildren.Add((New-Separator)) | Out-Null

# Closing thanks
if ($thanksIdx -ne -1) { $newChildren.Add($children[$thanksIdx]) | Out-Null }
if ($dotsIdx -ne -1) { $newChildren.Add($children[$dotsIdx]) | Out-Null }
if ($sectPrIdx -ne -1) { $newChildren.Add($children[$sectPrIdx]) | Out-Null }

while ($body.HasChildNodes) { $body.RemoveChild($body.FirstChild) | Out-Null }
foreach ($n in $newChildren) { $body.AppendChild($n) | Out-Null }

$xml.Save($docXmlPath)

# Repackage
if (Test-Path $outFile) { Remove-Item -Force $outFile }
$zipOut = "_out5.zip"
if (Test-Path $zipOut) { Remove-Item -Force $zipOut }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$absWorkDir = (Resolve-Path $workDir).Path
$absZip = (Join-Path (Get-Location).Path $zipOut)
[System.IO.Compression.ZipFile]::CreateFromDirectory($absWorkDir, $absZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Move-Item -Path $zipOut -Destination $outFile -Force
Write-Output "Wrote: $outFile"

Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
Remove-Item -Force $workZip -ErrorAction SilentlyContinue
