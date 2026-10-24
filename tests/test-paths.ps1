$root = Split-Path $PSScriptRoot -Parent
. "$root/src/lib/Common.ps1"; . "$root/src/lib/PathScan.ps1"
$t = Join-Path ([IO.Path]::GetTempPath()) "pmtest"; Remove-Item $t -Recurse -Force -EA 0; New-Item -ItemType Directory $t | Out-Null
$app = New-Item -ItemType Directory "$t/App"
Set-Content "$app/a.ini" "LastDir=F:\Dropbox\Work`nBackup=S:\Backups\x.zip`nHome=C:\Users\brads\Documents`nOther=C:\Users\bradsmith\x`nurl=http://example.com/p:/x" -Encoding utf8
[IO.File]::WriteAllText("$app/b.json", '{"p":"F:\\Dropbox\\Notes","q":"file:///F:/Dropbox/Pics/a.png","u":"C:\\Users\\brads\\AppData"}')
$reg = "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_CURRENT_USER\Software\X]`r`n""Path""=""F:\\Dropbox\\X\\y.txt""`r`n""U""=""C:\\Users\\brads\\z""`r`n"
[IO.File]::WriteAllText("$app/c.reg", $reg, (New-Object Text.UnicodeEncoding $false,$true))
[IO.File]::WriteAllBytes("$app/d.dat", [byte[]](0,1,2,3) + [Text.Encoding]::ASCII.GetBytes("F:\Dropbox\bin") + [byte[]](0,0,9))
$r = Find-PMPathRefs $app 'brads'
"Roots: " + (($r.Roots.GetEnumerator() | Sort-Object Name | % { "$($_.Name)=$($_.Value)" }) -join ', ')
"User refs: $($r.User)   text files: $($r.Files.Count)   binary: $($r.Binary.Count)"
$tr = @(@{From='C:\Users\brads'; To='C:\Users\brad'}, @{From='F:\Dropbox'; To='C:\Users\brad\Dropbox'})
foreach ($f in $r.Files) { $n = Update-PMFilePaths $f.Path $f.Enc $tr; "{0}: {1} replaced ({2})" -f (Split-Path $f.Path -Leaf), $n, $f.Enc }
"--- a.ini"; Get-Content "$app/a.ini"
"--- b.json"; Get-Content "$app/b.json"
"--- c.reg (utf16 BOM kept: " + ([IO.File]::ReadAllBytes("$app/c.reg")[0..1] -join ',') + ")"; Get-Content "$app/c.reg"

"--- ANSI file + path ending at the folder + profile rewrite ---"
$ansi = "$app/ansi.ini"
[IO.File]::WriteAllBytes($ansi, [byte[]]([Text.Encoding]::ASCII.GetBytes("Dir=F:\Dropbox\M") + 0xFC + [Text.Encoding]::ASCII.GetBytes("ller`r`nRoot=""F:\Dropbox""`r`n")))
$r2 = Find-PMPathRefs $ansi 'C:\Users\brads'
"enc=" + (Get-PMTextEncoding ([IO.File]::ReadAllBytes($ansi))) + "  roots=" + (($r2.Roots.Keys | Sort-Object) -join ',') + " count=" + $r2.Roots['F:\Dropbox']
[void](Update-PMFilePaths $ansi $null @(@{From='F:\Dropbox'; To='D:\Box'}))
$b = [IO.File]::ReadAllBytes($ansi); "byte FC kept: " + ($b -contains 0xFC) + "   text: " + ([Text.Encoding]::GetEncoding(28591).GetString($b) -replace "`r`n",' | ')
