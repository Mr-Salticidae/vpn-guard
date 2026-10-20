# lint-ps1.ps1 - static checks for every .ps1 in the repo, run on real Windows PowerShell 5.1 in CI.
#
# 1. Parse errors (Parser::ParseFile).
# 2. Smart quotes used as string delimiters. PowerShell accepts U+201C/U+201D/U+201E (and
#    U+2018/U+2019/U+201A/U+201B for single quotes) as quote characters. A fullwidth quote
#    pair written INSIDE a "..." string therefore closes the string early; the rest of the
#    line becomes bare tokens and fails only at RUN time ("DoH is not recognized" on
#    vpn-leak-audit.ps1, 2026-10-20). ParseFile reports nothing, so we look at tokens:
#    a string token whose first or last character is a smart quote means PowerShell used it
#    as a delimiter. Smart quotes inside comments or in the middle of a string are harmless.
#
# This file is pure ASCII on purpose: PS 5.1 reads BOM-less files as the ANSI code page.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\lint-ps1.ps1 [file ...]
param([string[]]$Files)

$root = Split-Path -Parent $PSScriptRoot
if (-not $Files -or $Files.Count -eq 0) {
    $Files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' |
               Where-Object { $_.FullName -notmatch '[\\/]chrome-[^\\/]*-profile[\\/]' } |
               ForEach-Object { $_.FullName })
}
$smart = @([char]0x201C, [char]0x201D, [char]0x201E, [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B)
$fail = 0
foreach ($f in $Files) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
    foreach ($e in @($errs)) {
        Write-Host ("FAIL parse  {0}:{1}  {2}" -f $f, $e.Extent.StartLineNumber, $e.Message)
        $fail++
    }
    foreach ($t in @($tokens)) {
        $isString = ($t -is [System.Management.Automation.Language.StringToken])
        if (-not $isString -or $t.Text.Length -eq 0) { continue }
        $first = $t.Text[0]; $last = $t.Text[$t.Text.Length - 1]
        if ($smart -contains $first -or $smart -contains $last) {
            Write-Host ("FAIL quote  {0}:{1}  smart quote used as a string delimiter -- use corner brackets or ASCII quotes inside the string" -f $f, $t.Extent.StartLineNumber)
            $fail++
        }
    }
}
if ($fail -gt 0) { Write-Host ("lint-ps1: {0} problem(s) in {1} file(s)" -f $fail, $Files.Count); exit 1 }
Write-Host ("lint-ps1: OK ({0} files, PowerShell {1})" -f $Files.Count, $PSVersionTable.PSVersion)
exit 0
