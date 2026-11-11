
###############################################################################
# Audit-P4Ignore.ps1
#
# Optimized Perforce ignore audit and depot cleanup.
#
# Requirements:
#   PowerShell 5.1+
#   p4.exe available in PATH
#   Run from the Perforce workspace root
#
# Usage:
#   .\Audit-P4Ignore.ps1
#   .\Audit-P4Ignore.ps1 -MarkDelete -Changelist Default
#   .\Audit-P4Ignore.ps1 -MarkDelete -Changelist 12345
#
# Features:
#   - Interactive workspace selection
#   - Workspace and root validation
#   - Automatic P4IGNORE configuration detection
#   - Support for .p4ignore, p4ignore.txt and custom filenames
#   - Nested ignore file discovery
#   - Duplicate ignore file warnings
#   - Single bulk fstat metadata query
#   - Batched ignore evaluations
#   - Batched depot deletions
#   - Verification of deletion results
#   - CSV reports with file-lock fallback
#   - First 20 conflict preview
#   - Numbered pending changelist creation
#   - Automatic changelist description
#   - Local file preservation
#
# No changelist is automatically submitted.
###############################################################################

param(
    [switch]$MarkDelete,
    [string]$Changelist = "Default",
    [ValidateRange(1, 1000)]
    [int]$BatchSize = 100
)

$ErrorActionPreference = "Stop"

###############################################################################
# 1. CONFIGURATION
###############################################################################

# Replace this placeholder to use a fixed workspace.
# Otherwise the script prompts for the workspace name.

$env:P4CLIENT = "YourP4VWorkspace"

# Do not overwrite an existing P4IGNORE setting.

$WorkspaceRoot = [IO.Path]::GetFullPath(
    (Get-Location).ProviderPath
).TrimEnd('\', '/')

$CurrentFolderName = Split-Path $WorkspaceRoot -Leaf

$ReportFile = Join-Path $WorkspaceRoot "P4IgnoreAudit.csv"

$FinalReportFile = Join-Path `
    $WorkspaceRoot "P4IgnoreAudit_Cleanup.csv"

$AdditionalReportFile = Join-Path `
    $WorkspaceRoot "P4IgnoreAdditionalFiles.csv"

$ErrorReportFile = Join-Path `
    $WorkspaceRoot "P4IgnoreAuditErrors.txt"

$AuditColumns = @(
    "DepotPath",
    "LocalPath",
    "IgnoreSource",
    "IgnoreLine",
    "IgnoreRule",
    "Synced",
    "Status"
)

$PathComparer = [StringComparer]::OrdinalIgnoreCase

###############################################################################
# 2. GENERAL UTILITIES
###############################################################################

function Stop-WithError {
    param([string]$Message)

    Write-Host ""
    Write-Host "============================================"
    Write-Host " ERROR - PROCESSING STOPPED" -ForegroundColor Red
    Write-Host "============================================"
    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow

    throw "Audit-P4Ignore stopped."
}

function Invoke-P4 {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $oldPreference = $ErrorActionPreference
    $hasNative = Test-Path `
        Variable:\PSNativeCommandUseErrorActionPreference

    if ($hasNative) {
        $oldNative = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = "Continue"

        if ($hasNative) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        $output = @(
            & p4 @Arguments 2>&1 |
                ForEach-Object { $_.ToString() }
        )

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference

        if ($hasNative) {
            $PSNativeCommandUseErrorActionPreference = $oldNative
        }
    }

    return [pscustomobject]@{
        ExitCode = $code
        Output   = $output
        Text     = ($output -join "`n")
    }
}

function Get-P4Tag {
    param(
        [string[]]$Lines,
        [string]$Tag
    )

    $prefix = "... $Tag "

    foreach ($line in $Lines) {
        if ($line.StartsWith($prefix)) {
            return $line.Substring($prefix.Length)
        }
    }

    return $null
}

function Normalize-Path {
    param([string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-WithinRoot {
    param([string]$Path)

    try {
        $full = Normalize-Path $Path

        return (
            $full.Equals(
                $WorkspaceRoot,
                [StringComparison]::OrdinalIgnoreCase
            ) -or
            $full.StartsWith(
                $WorkspaceRoot + '\',
                [StringComparison]::OrdinalIgnoreCase
            )
        )
    }
    catch {
        return $false
    }
}

function Get-RelativeWorkspacePath {
    param([string]$Path)

    return $Path.Substring(
        $WorkspaceRoot.Length
    ).TrimStart('\', '/')
}

###############################################################################
# 3. SAFE CSV REPORTING
###############################################################################

function Export-SafeCsv {
    param(
        [object[]]$Data,
        [string[]]$Columns,
        [string]$Path
    )

    if ($Data.Count -gt 0) {
        $content = @(
            $Data |
                Select-Object -Property $Columns |
                ConvertTo-Csv -NoTypeInformation
        )
    }
    else {
        $content = @(
            '"' + ($Columns -join '","') + '"'
        )
    }

    try {
        $content |
            Set-Content `
                -LiteralPath $Path `
                -Encoding UTF8 `
                -ErrorAction Stop

        return $Path
    }
    catch [System.IO.IOException] {

        $directory = Split-Path $Path -Parent
        $name = [IO.Path]::GetFileNameWithoutExtension($Path)
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss_fffffff"

        $alternate = Join-Path $directory (
            "${name}_${stamp}.csv"
        )

        $content |
            Set-Content `
                -LiteralPath $alternate `
                -Encoding UTF8 `
                -ErrorAction Stop

        Write-Warning "Report was locked. Created an alternate CSV."
        Write-Host $alternate -ForegroundColor Cyan

        return $alternate
    }
}

###############################################################################
# 4. P4IGNORE CONFIGURATION
###############################################################################

function Get-P4IgnoreConfiguration {

    if (-not [string]::IsNullOrWhiteSpace($env:P4IGNORE)) {
        return $env:P4IGNORE.Trim()
    }

    $result = Invoke-P4 -Arguments @(
        "set", "P4IGNORE"
    )

    if ($result.ExitCode -eq 0) {

        foreach ($line in $result.Output) {

            if ($line -match '^P4IGNORE=(.*?)(?:\s+\([^)]*\))?$') {
                return $Matches[1].Trim()
            }
        }
    }

    return ""
}

function Get-IgnoreEntries {
    param([string]$Configuration)

    if ([string]::IsNullOrWhiteSpace($Configuration)) {

        # Modern Perforce defaults.
        return @(".p4ignore", "p4ignore.txt")
    }

    return @(
        $Configuration -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" }
    )
}

###############################################################################
# 5. BATCH HELPERS
###############################################################################

function Split-IntoBatches {
    param(
        [object[]]$Items,
        [int]$MaxItems,
        [int]$MaxCharacters = 12000
    )

    $current = [System.Collections.Generic.List[object]]::new()
    $characters = 0

    foreach ($item in $Items) {

        $length = ([string]$item).Length + 3

        if (
            $current.Count -gt 0 -and
            (
                $current.Count -ge $MaxItems -or
                ($characters + $length) -gt $MaxCharacters
            )
        ) {
            Write-Output -NoEnumerate $current.ToArray()
            $current.Clear()
            $characters = 0
        }

        $current.Add($item)
        $characters += $length
    }

    if ($current.Count -gt 0) {
        Write-Output -NoEnumerate $current.ToArray()
    }
}


###############################################################################
# 6. BULK DEPOT METADATA
###############################################################################

function Get-P4DepotMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$ClientName
    )

    $records = [System.Collections.Generic.List[object]]::new()

    $current = $null
    $processed = 0

    # Use temporary files instead of piping a potentially
    # large native-command output directly into PowerShell.

    $tempDirectory = [IO.Path]::GetTempPath()
    $uniqueId = [guid]::NewGuid().ToString("N")

    $stdoutFile = Join-Path $tempDirectory (
        "P4IgnoreFstat_${uniqueId}_stdout.txt"
    )

    $stderrFile = Join-Path $tempDirectory (
        "P4IgnoreFstat_${uniqueId}_stderr.txt"
    )

    ###########################################################################
    # 6.1 FIND PERFORCE EXECUTABLE
    ###########################################################################

    $p4Command = Get-Command p4.exe -ErrorAction Stop
    $p4Executable = $p4Command.Source

    ###########################################################################
    # 6.2 PREPARE BULK FSTAT QUERY
    ###########################################################################

    $arguments = @(
        "-ztag",
        "fstat",
        "-Rc",
        "-T",
        "depotFile,clientFile,haveRev,headAction,action",
        "//$ClientName/..."
    )

    Write-Host ""
    Write-Host "Starting bulk Perforce metadata query..."
    Write-Host "Workspace: $ClientName"

    ###########################################################################
    # 6.3 EXECUTE PERFORCE AS A SEPARATE PROCESS
    ###########################################################################

    try {

        $process = Start-Process `
            -FilePath $p4Executable `
            -ArgumentList $arguments `
            -WorkingDirectory $WorkspaceRoot `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -ErrorAction Stop

        if ($process.ExitCode -ne 0) {

            $errorText = ""

            if (Test-Path -LiteralPath $stderrFile) {
                $errorText = Get-Content `
                    -LiteralPath $stderrFile `
                    -Raw
            }

            throw @"
Bulk Perforce metadata query failed.

Exit code: $($process.ExitCode)

Perforce error:
$errorText
"@
        }

        if (-not (Test-Path -LiteralPath $stdoutFile)) {
            throw "Perforce did not create its metadata output file."
        }

        #######################################################################
        # 6.4 READ OUTPUT WITHOUT LOADING THE ENTIRE FILE INTO MEMORY
        #######################################################################

        Write-Host "Metadata query completed."
        Write-Host "Processing returned records..."

        $reader = [IO.StreamReader]::new($stdoutFile)

        try {

            while ($null -ne ($line = $reader.ReadLine())) {

                ###############################################################
                # Start a new depot file record
                ###############################################################

                if ($line -match '^\.\.\. depotFile (.*)$') {

                    # Finish the previous record.
                    if ($null -ne $current) {

                        if (
                            -not [string]::IsNullOrWhiteSpace(
                                $current.DepotPath
                            ) -and

                            -not [string]::IsNullOrWhiteSpace(
                                $current.LocalPath
                            ) -and

                            -not [string]::IsNullOrWhiteSpace(
                                $current.HeadAction
                            ) -and

                            $current.HeadAction -notin @(
                                "delete",
                                "move/delete",
                                "purge",
                                "archive"
                            ) -and

                            (Test-WithinRoot $current.LocalPath)
                        ) {
                            $records.Add($current)
                        }
                    }

                    # Initialize next record.
                    $current = [pscustomobject]@{
                        DepotPath  = $Matches[1]
                        LocalPath  = ""
                        Synced     = $false
                        HeadAction = ""
                        OpenAction = ""
                    }

                    $processed++

                    if ($processed % 10000 -eq 0) {
                        Write-Host "Metadata records processed: $processed"
                    }

                    continue
                }

                ###############################################################
                # Read fields belonging to the current record
                ###############################################################

                if ($null -eq $current) {
                    continue
                }

                if ($line -match '^\.\.\. clientFile (.*)$') {

                    $current.LocalPath = $Matches[1]

                }
                elseif ($line -match '^\.\.\. haveRev (\d+)$') {

                    $current.Synced = (
                        [int]$Matches[1] -gt 0
                    )

                }
                elseif ($line -match '^\.\.\. headAction (.*)$') {

                    $current.HeadAction = $Matches[1]

                }
                elseif ($line -match '^\.\.\. action (.*)$') {

                    $current.OpenAction = $Matches[1]

                }
            }

            ###############################################################
            # Finish final record
            ###############################################################

            if ($null -ne $current) {

                if (
                    -not [string]::IsNullOrWhiteSpace(
                        $current.DepotPath
                    ) -and

                    -not [string]::IsNullOrWhiteSpace(
                        $current.LocalPath
                    ) -and

                    -not [string]::IsNullOrWhiteSpace(
                        $current.HeadAction
                    ) -and

                    $current.HeadAction -notin @(
                        "delete",
                        "move/delete",
                        "purge",
                        "archive"
                    ) -and

                    (Test-WithinRoot $current.LocalPath)
                ) {
                    $records.Add($current)
                }
            }
        }
        finally {
            $reader.Dispose()
        }

        #######################################################################
        # 6.5 FINAL VALIDATION
        #######################################################################

        Write-Host ""
        Write-Host "============================================"
        Write-Host " BULK METADATA SUMMARY"
        Write-Host "============================================"
        Write-Host ""

        Write-Host "Records returned: $processed"
        Write-Host "Active mapped files: $($records.Count)"

        if ($records.Count -eq 0) {
            throw "No valid active depot files were returned."
        }

        # Return the records consumed by Section 7.
        return $records.ToArray()

    }
    catch {

        throw "Metadata query failed: $($_.Exception.Message)"

    }
    finally {

        #######################################################################
        # 6.6 CLEAN UP TEMPORARY FILES
        #######################################################################

        if (Test-Path -LiteralPath $stdoutFile) {
            Remove-Item `
                -LiteralPath $stdoutFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $stderrFile) {
            Remove-Item `
                -LiteralPath $stderrFile `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

###############################################################################
# END SECTION 6
###############################################################################



###############################################################################
# 7. BATCHED IGNORE EVALUATION
###############################################################################

function Get-BatchIgnoreMatches {
    param(
        [Parameter(Mandatory)]
        [object[]]$Files,

        [ValidateRange(1, 1000)]
        [int]$MaxBatchSize = 100
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $fallbackCount = 0
    $unicodeMismatchCount = 0

    ###########################################################################
    # 7.1 PATH NORMALIZATION
    ###########################################################################

    function Normalize-IgnorePath {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw "Empty ignore-result path."
        }

        $clean = $Path.Trim().Trim('"').Replace('/', '\')

        return [IO.Path]::GetFullPath($clean).TrimEnd('\')
    }

    function Get-AsciiPathSignature {
        param([string]$Path)

        # Normalize all non-ASCII characters to '?'.
        # Used ONLY to identify probable encoding mismatches.
        # It must not be used as a general path lookup key.

        return [regex]::Replace(
            (Normalize-IgnorePath $Path),
            '[^\x00-\x7F]',
            '?'
        )
    }

    ###########################################################################
    # 7.2 PARSE ONE BATCH OF PERFORCE OUTPUT
    ###########################################################################

    function Parse-IgnoreResults {
        param(
            [string[]]$OutputLines,
            [object[]]$InputFiles
        )

        $decisions = [System.Collections.Generic.List[object]]::new()

        foreach ($raw in $OutputLines) {

            $line = [string]$raw

            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            # Perforce may return either:
            #
            # path not ignored
            #
            # path ignored by C:\path\.p4ignore:48:**/Saved/
            #
            # OR:
            #
            # path ignored by
            #   C:\path\.p4ignore:48:**/Saved/

            $match = [regex]::Match(
                $line,
                '^(.*?) (not ignored|ignored)(?: by(?: (.*))?)?\s*$',
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($match.Success) {

                $path = Normalize-IgnorePath $match.Groups[1].Value

                $ignored = (
                    $match.Groups[2].Value -ieq "ignored"
                )

                $detail = $match.Groups[3].Value.Trim()

                $entry = [pscustomobject]@{
                    Path    = $path
                    Ignored = $ignored
                    Source  = ""
                    Line    = ""
                    Rule    = ""
                }

                if ($ignored -and $detail) {

                    if ($detail -match '^(.+):(\d+):(.*)$') {
                        $entry.Source = $Matches[1]
                        $entry.Line = $Matches[2]
                        $entry.Rule = $Matches[3]
                    }
                    else {
                        throw "Invalid inline ignore rule: $line"
                    }
                }

                $decisions.Add($entry)
                continue
            }

            # Continuation line containing source:line:rule.

            if ($line.Trim() -match '^(.+):(\d+):(.*)$') {

                if ($decisions.Count -eq 0) {
                    throw "Ignore rule without a preceding file."
                }

                $last = $decisions[$decisions.Count - 1]

                if (-not $last.Ignored) {
                    # A negation rule may explain a non-ignored result.
                    # It does not create a deletion candidate.
                    continue
                }

                if ($last.Source) {
                    throw "Duplicate rule details for $($last.Path)"
                }

                $last.Source = $Matches[1]
                $last.Line = $Matches[2]
                $last.Rule = $Matches[3]

                continue
            }

            throw "Unrecognized Perforce output: $line"
        }

        #######################################################################
        # Validate result count
        #######################################################################

        if ($decisions.Count -ne $InputFiles.Count) {

            throw (
                "Expected $($InputFiles.Count) ignore decisions, " +
                "received $($decisions.Count)."
            )
        }

        #######################################################################
        # Validate returned paths against input paths
        #######################################################################

        $matched = [System.Collections.Generic.List[object]]::new()

        # Identify ambiguous ASCII signatures.
        # A Unicode mismatch is accepted only when its
        # signature uniquely identifies the input in this batch.

        $signatureCounts = @{}

        foreach ($file in $InputFiles) {
            $signature = Get-AsciiPathSignature $file.LocalPath

            if (-not $signatureCounts.ContainsKey($signature)) {
                $signatureCounts[$signature] = 0
            }

            $signatureCounts[$signature]++
        }

        for ($i = 0; $i -lt $InputFiles.Count; $i++) {

            $file = $InputFiles[$i]
            $decision = $decisions[$i]

            $expected = Normalize-IgnorePath $file.LocalPath
            $returned = $decision.Path

            $exactMatch = $expected.Equals(
                $returned,
                [StringComparison]::OrdinalIgnoreCase
            )

            if (-not $exactMatch) {

                $expectedSignature = Get-AsciiPathSignature $expected
                $returnedSignature = Get-AsciiPathSignature $returned

                $signatureMatch = $expectedSignature.Equals(
                    $returnedSignature,
                    [StringComparison]::OrdinalIgnoreCase
                )

                if (
                    -not $signatureMatch -or
                    $signatureCounts[$expectedSignature] -ne 1
                ) {

                    throw @"
Ignore-result path mismatch.

Expected:
$expected

Returned:
$returned

Result index: $i

The paths could not be safely associated.
"@
                }

                # The path differs only in non-ASCII characters.
                # Perforce's returned decision is associated with
                # the uniquely matching original input path.

                $script:IgnoreUnicodeWarnings++

                if ($script:IgnoreUnicodeWarnings -le 5) {
                    Write-Warning (
                        "Possible filename encoding mismatch: " +
                        $expected
                    )
                }
            }

            if (-not $decision.Ignored) {
                continue
            }

            # Require rule details before marking a file ignored.

            if (
                [string]::IsNullOrWhiteSpace($decision.Source) -or
                [string]::IsNullOrWhiteSpace($decision.Line)
            ) {
                throw "Missing ignore-rule information for $expected"
            }

            $matched.Add(
                [pscustomobject]@{
                    DepotPath    = $file.DepotPath
                    LocalPath    = $file.LocalPath
                    IgnoreSource = $decision.Source
                    IgnoreLine   = $decision.Line
                    IgnoreRule   = $decision.Rule
                    Synced       = $file.Synced
                    OpenAction   = $file.OpenAction
                }
            )
        }

        return $matched.ToArray()
    }

    ###########################################################################
    # 7.3 BUILD BATCHES
    ###########################################################################

    $script:IgnoreUnicodeWarnings = 0

    $batches = [System.Collections.Generic.List[object]]::new()
    $currentBatch = [System.Collections.Generic.List[object]]::new()
    $characters = 0

    $maxCharacters = 12000

    foreach ($file in $Files) {

        if ([string]::IsNullOrWhiteSpace($file.LocalPath)) {
            $errors.Add("Metadata record has no local path.")
            continue
        }

        $length = $file.LocalPath.Length + 3

        if (
            $currentBatch.Count -gt 0 -and
            (
                $currentBatch.Count -ge $MaxBatchSize -or
                ($characters + $length) -gt $maxCharacters
            )
        ) {

            $batches.Add($currentBatch.ToArray())
            $currentBatch.Clear()
            $characters = 0
        }

        $currentBatch.Add($file)
        $characters += $length
    }

    if ($currentBatch.Count -gt 0) {
        $batches.Add($currentBatch.ToArray())
    }

    if ($errors.Count -gt 0) {
        throw ($errors -join "`n")
    }

    Write-Host ""
    Write-Host "Ignore evaluation batches: $($batches.Count)"
    Write-Host ""

    ###########################################################################
    # 7.4 PROCESS BATCHES
    ###########################################################################

    $batchIndex = 0

    foreach ($batchObject in $batches) {

        $batchIndex++

        $batch = @($batchObject)

        Write-Progress `
            -Activity "Evaluating P4IGNORE rules" `
            -Status "Batch $batchIndex of $($batches.Count)" `
            -PercentComplete ([int](
                100 * $batchIndex / $batches.Count
            ))

        $paths = @(
            $batch | ForEach-Object { [string]$_.LocalPath }
        )

        $output = Invoke-P4 -Arguments (
            @("ignores", "-i", "-v") + $paths
        )

        $batchSucceeded = $false

        if ($output.ExitCode -eq 0) {

            try {
                $batchMatches = @(
                    Parse-IgnoreResults `
                        -OutputLines $output.Output `
                        -InputFiles $batch
                )

                foreach ($item in $batchMatches) {
                    $results.Add($item)
                }

                $batchSucceeded = $true
            }
            catch {
                Write-Warning (
                    "Batch $batchIndex parsing failed: " +
                    $_.Exception.Message
                )
            }
        }
        else {
            Write-Warning (
                "Batch $batchIndex failed: " + $output.Text
            )
        }

        if ($batchSucceeded) {
            continue
        }

        #######################################################################
        # 7.5 INDIVIDUAL FALLBACK
        #######################################################################

        $fallbackCount++

        Write-Host ""
        Write-Host "Retrying batch $batchIndex individually..." `
            -ForegroundColor Yellow

        foreach ($file in $batch) {

            $single = Invoke-P4 -Arguments @(
                "ignores",
                "-i",
                "-v",
                [string]$file.LocalPath
            )

            if ($single.ExitCode -ne 0) {

                $errors.Add(
                    "Perforce failed: $($file.LocalPath) - " +
                    $single.Text
                )

                continue
            }

            try {

                $singleMatches = @(
                    Parse-IgnoreResults `
                        -OutputLines $single.Output `
                        -InputFiles @($file)
                )

                foreach ($item in $singleMatches) {
                    $results.Add($item)
                }
            }
            catch {

                $errors.Add(
                    "Parsing failed for $($file.LocalPath): " +
                    $_.Exception.Message
                )
            }
        }
    }

    Write-Progress `
        -Activity "Evaluating P4IGNORE rules" `
        -Completed

    ###########################################################################
    # 7.6 FINAL VALIDATION
    ###########################################################################

    Write-Host ""
    Write-Host "============================================"
    Write-Host " IGNORE EVALUATION SUMMARY"
    Write-Host "============================================"
    Write-Host ""

    Write-Host "Files checked:        $($Files.Count)"
    Write-Host "Batches processed:    $($batches.Count)"
    Write-Host "Fallback batches:     $fallbackCount"
    Write-Host "Ignored files:        $($results.Count)"
    Write-Host "Encoding mismatches:  $script:IgnoreUnicodeWarnings"
    Write-Host "Errors:               $($errors.Count)"

    if ($errors.Count -gt 0) {

        foreach ($errorMessage in $errors) {
            Write-Host $errorMessage -ForegroundColor Yellow
        }

        throw @"
Ignore evaluation was incomplete.

$($errors.Count) file(s) could not be evaluated.

No cleanup was performed.
"@
    }

    return $results.ToArray()
}

###############################################################################
# END SECTION 7
###############################################################################



###############################################################################
# 8. CHANGE SPECIFICATION FUNCTIONS
###############################################################################

function Set-P4SpecDescription {
    param(
        [string]$Spec,
        [string]$Description
    )

    $pattern = '(?ms)^Description:[ \t]*\r?\n.*?(?=^[A-Za-z][A-Za-z0-9]*:|\z)'

    if ($Spec -notmatch $pattern) {
        throw "Changelist has no Description field."
    }

    $replacement = "Description:`n`t$Description`n`n"

    return [regex]::Replace(
        $Spec,
        $pattern,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $replacement
        }
    )
}

function Submit-P4ChangeSpec {
    param([string]$Spec)

    $oldPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $output = @(
            ($Spec -split '\r?\n') |
                & p4 change -i 2>&1 |
                ForEach-Object { $_.ToString() }
        )

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    if ($code -ne 0) {
        throw "Changelist update failed: $($output -join ' ')"
    }

    return ($output -join "`n")
}

function New-AuditChangelist {
    param([string]$Description)

    $result = Invoke-P4 -Arguments @("change", "-o")

    if ($result.ExitCode -ne 0) {
        throw "Could not retrieve new changelist form."
    }

    $spec = Set-P4SpecDescription `
        -Spec $result.Text `
        -Description $Description

    # Prevent default changelist files from moving.

    $spec = [regex]::Replace(
        $spec,
        '(?ms)^Files:[ \t]*\r?\n.*?(?=^[A-Za-z][A-Za-z0-9]*:|\z)',
        ''
    )

    $output = Submit-P4ChangeSpec -Spec $spec

    if ($output -match 'Change\s+(\d+)\s+created') {
        return $Matches[1]
    }

    throw "Unable to determine new changelist number: $output"
}

function Update-AuditChangelist {
    param(
        [string]$ChangeId,
        [string]$Description,
        [bool]$ReplaceDescription
    )

    $result = Invoke-P4 -Arguments @(
        "change", "-o", $ChangeId
    )

    if ($result.ExitCode -ne 0) {
        throw "Unable to read changelist $ChangeId."
    }

    $finalDescription = $Description

    if (-not $ReplaceDescription) {

        $pattern = '(?ms)^Description:[ \t]*\r?\n(.*?)(?=^[A-Za-z][A-Za-z0-9]*:|\z)'
        $match = [regex]::Match($result.Text, $pattern)

        if ($match.Success) {

            $existing = (
                ($match.Groups[1].Value -split '\r?\n' |
                    ForEach-Object { $_.TrimStart("`t") }) -join "`n"
            ).Trim()

            if ($existing) {
                $finalDescription = "$existing`n`n$Description"
            }
        }
    }

    $spec = Set-P4SpecDescription `
        -Spec $result.Text `
        -Description $finalDescription

    $null = Submit-P4ChangeSpec -Spec $spec
}

###############################################################################
# 9. BATCHED DEPOT DELETION
###############################################################################

function Invoke-BatchDelete {
    param(
        [object[]]$Files,
        [string]$ChangeId,
        [int]$MaxBatchSize
    )

    $batches = @(
        Split-IntoBatches `
            -Items @($Files | ForEach-Object { $_.DepotPath }) `
            -MaxItems $MaxBatchSize
    )

    $batchErrors = [System.Collections.Generic.List[string]]::new()

    $index = 0

    foreach ($batch in $batches) {

        $index++

        $tempFile = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("P4IgnoreDelete_" + [guid]::NewGuid().ToString("N") + ".txt")

        try {

            # Use a response file instead of placing every
            # depot path on the process command line.

            @($batch) |
                Set-Content `
                    -LiteralPath $tempFile `
                    -Encoding Default

            $result = Invoke-P4 -Arguments @(
                "-x", $tempFile,
                "delete",
                "-k",
                "-c", $ChangeId
            )

            if ($result.ExitCode -ne 0) {

                $batchErrors.Add(
                    "Batch $index failed: $($result.Text)"
                )
            }
        }
        finally {
            Remove-Item `
                -LiteralPath $tempFile `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Write-Progress `
            -Activity "Opening files for delete" `
            -Status "Batch $index of $($batches.Count)" `
            -PercentComplete ([int](
                100 * $index / $batches.Count
            ))
    }

    Write-Progress -Activity "Opening files for delete" -Completed

    return $batchErrors.ToArray()
}

###############################################################################
# 10. VERIFY OPENED DELETIONS
###############################################################################

function Get-OpenedDeletionPaths {
    param([string]$ChangeId)

    $result = Invoke-P4 -Arguments @(
        "-ztag", "opened", "-c", $ChangeId
    )

    if ($result.ExitCode -ne 0) {
        throw "Unable to verify changelist contents: $($result.Text)"
    }

    $paths = [System.Collections.Generic.HashSet[string]]::new(
        $PathComparer
    )

    $currentDepot = ""
    $currentAction = ""

    foreach ($line in $result.Output) {

        if ($line -match '^\.\.\. depotFile (.*)$') {

            if (
                $currentDepot -and
                $currentAction -eq "delete"
            ) {
                [void]$paths.Add($currentDepot)
            }

            $currentDepot = $Matches[1]
            $currentAction = ""
        }
        elseif ($line -match '^\.\.\. action (.*)$') {
            $currentAction = $Matches[1]
        }
    }

    if ($currentDepot -and $currentAction -eq "delete") {
        [void]$paths.Add($currentDepot)
    }

    return $paths
}

###############################################################################
# 11. STARTUP AND WORKSPACE SELECTION
###############################################################################

Write-Host ""
Write-Host "============================================"
Write-Host " PERFORCE IGNORE DEPOT AUDIT"
Write-Host "============================================"
Write-Host ""
Write-Host "Current directory: $WorkspaceRoot"
Write-Host ""

if (-not (Get-Command p4 -ErrorAction SilentlyContinue)) {
    Stop-WithError "p4.exe was not found in PATH."
}

$WorkspaceName = $env:P4CLIENT.Trim()

if ($WorkspaceName -eq "YourP4VWorkspace") {

    Write-Host "Suggested workspace: $CurrentFolderName"
    Write-Host ""

    $answer = Read-Host (
        "Is '$CurrentFolderName' your workspace name? (Y/N)"
    )

    switch ($answer.Trim().ToUpperInvariant()) {

        { $_ -in @("Y", "YES") } {
            $WorkspaceName = $CurrentFolderName
        }

        { $_ -in @("N", "NO") } {
            $WorkspaceName = (
                Read-Host "Enter workspace name"
            ).Trim()
        }

        default {
            Stop-WithError "Please answer Y or N."
        }
    }
}

if (
    [string]::IsNullOrWhiteSpace($WorkspaceName) -or
    $WorkspaceName -eq "YourP4VWorkspace"
) {
    Stop-WithError "A valid workspace name is required."
}

$env:P4CLIENT = $WorkspaceName

###############################################################################
# 12. VALIDATE WORKSPACE AND ROOT
###############################################################################

Write-Host ""
Write-Host "Validating workspace: $WorkspaceName"

$info = Invoke-P4 -Arguments @("-ztag", "info")

if ($info.ExitCode -ne 0) {
    Stop-WithError "Cannot connect to Perforce: $($info.Text)"
}

$clients = Invoke-P4 -Arguments @(
    "-ztag", "clients", "-e", $WorkspaceName
)

if ($clients.ExitCode -ne 0) {
    Stop-WithError "Cannot list Perforce workspaces."
}

$clientNames = @(
    $clients.Output |
        Where-Object { $_ -match '^\.\.\. client ' } |
        ForEach-Object { $_ -replace '^\.\.\. client ', '' }
)

if ($WorkspaceName -cnotin $clientNames) {
    Stop-WithError "Workspace '$WorkspaceName' was not found."
}

$activeClient = Get-P4Tag $info.Output "clientName"
$detectedRoot = Get-P4Tag $info.Output "clientRoot"

if ($activeClient -cne $WorkspaceName) {
    Stop-WithError "Active workspace does not match selection."
}

if (
    [string]::IsNullOrWhiteSpace($detectedRoot) -or
    $detectedRoot -eq "null"
) {
    Stop-WithError "Invalid Perforce workspace root."
}

$detectedRoot = Normalize-Path $detectedRoot

if (-not $detectedRoot.Equals(
    $WorkspaceRoot,
    [StringComparison]::OrdinalIgnoreCase
)) {
    Stop-WithError @"
This script must run from the workspace root.

Current directory:
$WorkspaceRoot

Expected directory:
$detectedRoot

Move the script into the workspace root and open
PowerShell in that directory before running it.
"@
}

Write-Host "Workspace validated." -ForegroundColor Green

###############################################################################
# 13. DETECT P4IGNORE CONFIGURATION
###############################################################################

Write-Host ""
Write-Host "Checking P4IGNORE configuration..."

$IgnoreConfiguration = Get-P4IgnoreConfiguration

$IgnoreEntries = @(
    Get-IgnoreEntries $IgnoreConfiguration
)

if ([string]::IsNullOrWhiteSpace($IgnoreConfiguration)) {
    Write-Host "Using Perforce default ignore filenames."
}
else {
    Write-Host "P4IGNORE: $IgnoreConfiguration"
}

# Determine active root ignore files.

$RootIgnoreFiles = @()

foreach ($entry in $IgnoreEntries) {

    $expanded = [Environment]::ExpandEnvironmentVariables($entry)

    if ([IO.Path]::IsPathRooted($expanded)) {
        $candidate = Normalize-Path $expanded
    }
    else {
        $candidate = Normalize-Path (
            Join-Path $WorkspaceRoot $expanded
        )
    }

    if (
        (Test-Path -LiteralPath $candidate -PathType Leaf) -and
        (Split-Path $candidate -Parent).Equals(
            $WorkspaceRoot,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $RootIgnoreFiles += $candidate
    }
}

if ($RootIgnoreFiles.Count -eq 0) {
    Stop-WithError @"
No configured ignore file was found in the workspace root.

P4IGNORE:
$($IgnoreEntries -join ';')

Place the appropriate ignore file in the workspace root.
"@
}

$check = Invoke-P4 -Arguments @("ignores", "-v")

if ($check.ExitCode -ne 0) {
    Stop-WithError "Perforce could not evaluate ignore rules."
}

###############################################################################
# 14. OPTIMIZED IGNORE FILE DISCOVERY
###############################################################################

Write-Host ""
Write-Host "Discovering workspace ignore files..."

$names = [System.Collections.Generic.HashSet[string]]::new(
    $PathComparer
)

[void]$names.Add(".p4ignore")
[void]$names.Add("p4ignore.txt")

foreach ($entry in $IgnoreEntries) {

    if (-not [IO.Path]::IsPathRooted($entry)) {
        [void]$names.Add((Split-Path $entry -Leaf))
    }
}

$foundFiles = [System.Collections.Generic.List[object]]::new()
$discoveryErrors = [System.Collections.Generic.List[string]]::new()

# Enumerate directories, not all files.
# Check only the filenames of interest.

$directories = [System.Collections.Generic.Stack[string]]::new()
$directories.Push($WorkspaceRoot)

while ($directories.Count -gt 0) {

    $directory = $directories.Pop()

    foreach ($filename in $names) {

        $candidate = Join-Path $directory $filename

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {

            $full = Normalize-Path $candidate

            $foundFiles.Add(
                [pscustomobject]@{
                    Directory = $directory
                    Name = $filename
                    FullPath = $full
                    RelativePath = Get-RelativeWorkspacePath $full
                }
            )
        }
    }

    try {

        $children = @(
            Get-ChildItem `
                -LiteralPath $directory `
                -Directory `
                -Force `
                -ErrorAction Stop
        )

        foreach ($child in $children) {

            # Avoid traversing symbolic links or junctions.
            if (
                ($child.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0
            ) {
                continue
            }

            $directories.Push($child.FullName)
        }
    }
    catch {
        $discoveryErrors.Add(
            "$directory : $($_.Exception.Message)"
        )
    }
}

$additionalIgnoreFiles = @(
    $foundFiles |
        Where-Object {
            $_.FullPath -notin $RootIgnoreFiles
        } |
        Sort-Object RelativePath
)

$duplicateIgnoreDirectories = @(
    $foundFiles |
        Group-Object Directory |
        Where-Object {

            $groupNames = @($_.Group | ForEach-Object { $_.Name })

            (
                ".p4ignore" -in $groupNames -and
                "p4ignore.txt" -in $groupNames
            )
        } |
        ForEach-Object { $_.Name }
)

Write-Host "Ignore files discovered: $($foundFiles.Count)"
Write-Host "Additional files: $($additionalIgnoreFiles.Count)"

if ($additionalIgnoreFiles.Count -gt 0) {

    Write-Host ""
    Write-Host "Additional ignore files:"

    foreach ($file in $additionalIgnoreFiles) {
        Write-Host "  $($file.RelativePath)" -ForegroundColor Cyan
    }

    $AdditionalReportFile = Export-SafeCsv `
        -Data @($additionalIgnoreFiles) `
        -Columns @("RelativePath", "FullPath") `
        -Path $AdditionalReportFile
}

if ($duplicateIgnoreDirectories.Count -gt 0) {

    Write-Host ""
    Write-Warning "Directories containing BOTH default ignore filenames:"

    foreach ($directory in $duplicateIgnoreDirectories) {

        $relative = Get-RelativeWorkspacePath $directory

        if (-not $relative) {
            $relative = "(Workspace Root)"
        }

        Write-Host "  $relative" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Review these files for overlapping or conflicting rules."
    Write-Host "Neither file will be deleted automatically."
}

if ($discoveryErrors.Count -gt 0) {
    Write-Warning "Some directories could not be searched."
}

###############################################################################
# 15. VALIDATE CLEANUP CONFIGURATION
###############################################################################

$UseNewChangelist = $false
$TargetChangelist = $Changelist

if ($MarkDelete) {

    if ($Changelist -ieq "Default") {

        $UseNewChangelist = $true

    }
    elseif (
        $Changelist -match '^\d+$' -and
        [long]$Changelist -gt 0
    ) {

        $changeInfo = Invoke-P4 -Arguments @(
            "-ztag", "change", "-o", $Changelist
        )

        if ($changeInfo.ExitCode -ne 0) {
            Stop-WithError "Changelist $Changelist was not found."
        }

        $status = Get-P4Tag $changeInfo.Output "Status"
        $client = Get-P4Tag $changeInfo.Output "Client"

        if ($status -ne "pending" -or
            $client -cne $WorkspaceName) {
            Stop-WithError "Invalid pending changelist."
        }
    }
    else {
        Stop-WithError "Use Default or a positive changelist number."
    }
}

###############################################################################
# 16. BULK DEPOT METADATA QUERY
###############################################################################

Write-Host ""
Write-Host "============================================"
Write-Host " BULK DEPOT AUDIT"
Write-Host "============================================"
Write-Host ""
Write-Host "Retrieving depot metadata..."

try {
    $depotFiles = @(
        Get-P4DepotMetadata -ClientName $WorkspaceName
    )
}
catch {
    Stop-WithError "Metadata query failed: $_"
}

Write-Host "Active mapped depot files: $($depotFiles.Count)"

if ($depotFiles.Count -eq 0) {
    Stop-WithError "No active mapped depot files were found."
}

###############################################################################
# 17. BATCHED IGNORE AUDIT
###############################################################################

Write-Host ""
Write-Host "Evaluating ignore rules in batches of $BatchSize..."

try {
    $ignoreMatches = @(
        Get-BatchIgnoreMatches `
            -Files $depotFiles `
            -MaxBatchSize $BatchSize
    )
}
catch {
    Stop-WithError "Ignore audit failed: $_"
}

$matches = [System.Collections.Generic.List[object]]::new()

foreach ($file in $ignoreMatches) {

    $status = "Candidate"

    if (-not $file.Synced) {
        $status = "Candidate - not synced"
    }
    elseif ($file.OpenAction) {
        $status = "Candidate - already open"
    }

    $matches.Add(
        [pscustomobject]@{
            DepotPath = $file.DepotPath
            LocalPath = $file.LocalPath
            IgnoreSource = $file.IgnoreSource
            IgnoreLine = $file.IgnoreLine
            IgnoreRule = $file.IgnoreRule
            Synced = $file.Synced
            Status = $status
            OpenAction = $file.OpenAction
        }
    )
}

###############################################################################
# 18. EXPORT AUDIT REPORT
###############################################################################

$ReportFile = Export-SafeCsv `
    -Data @($matches.ToArray()) `
    -Columns $AuditColumns `
    -Path $ReportFile

Write-Host ""
Write-Host "============================================"
Write-Host " AUDIT SUMMARY"
Write-Host "============================================"
Write-Host ""
Write-Host "Workspace:          $WorkspaceName"
Write-Host "Files scanned:      $($depotFiles.Count)"
Write-Host "Conflicting files:  $($matches.Count)"
Write-Host "Nested ignore files: $($additionalIgnoreFiles.Count)"
Write-Host ""
Write-Host "Report: $ReportFile" -ForegroundColor Cyan

###############################################################################
# 19. DISPLAY FIRST 20 CONFLICTS
###############################################################################

Write-Host ""
Write-Host "============================================"
Write-Host " FIRST 20 IGNORE CONFLICTS"
Write-Host "============================================"
Write-Host ""

if ($matches.Count -gt 0) {

    $preview = @($matches | Select-Object -First 20)

    $number = 0

    foreach ($item in $preview) {

        $number++

        Write-Host "$number. $($item.DepotPath)"
        Write-Host "   Rule: $($item.IgnoreRule)"
        Write-Host "   Source: $($item.IgnoreSource)"
        Write-Host ""
    }

    Write-Host "Showing $($preview.Count) of $($matches.Count) conflicts."
}
else {
    Write-Host "No conflicting files found." -ForegroundColor Green
}


###############################################################################
# 20. AUDIT RESULTS AND INTERACTIVE CLEANUP APPROVAL
###############################################################################

# Tracks whether cleanup has already been approved.
# Prevents asking for confirmation twice.

$CleanupApproved = $false

if (-not $MarkDelete) {

    Write-Host ""
    Write-Host "============================================"
    Write-Host " AUDIT RESULTS"
    Write-Host "============================================"
    Write-Host ""

    if ($matches.Count -eq 0) {

        Write-Host "AUDIT COMPLETE - NO CHANGES NEEDED" `
            -ForegroundColor Green

        Write-Host ""
        Write-Host "All scanned depot files comply with the"
        Write-Host "current effective P4IGNORE rules."
        Write-Host ""
        Write-Host "The process is complete. No changes were needed." `
            -ForegroundColor Green

        return
    }

    Write-Host "Conflicting files found: $($matches.Count)" `
        -ForegroundColor Yellow

    Write-Host ""
    Write-Host "Please review the generated CSV report:"
    Write-Host $ReportFile -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Verify that all listed files should be removed"
    Write-Host "from Perforce source control."
    Write-Host ""
    Write-Host "Local copies will be preserved."
    Write-Host "No changelist will be submitted automatically."
    Write-Host ""

    $confirmation = Read-Host (
        "If all changes are approved, type DELETE to continue"
    )

    if ($confirmation.Trim() -cne "DELETE") {

        Write-Host ""
        Write-Host "============================================"
        Write-Host " CLEANUP NOT STARTED"
        Write-Host "============================================"
        Write-Host ""

        Write-Host "The audit is complete." `
            -ForegroundColor Green

        Write-Host "No files were opened for deletion."
        Write-Host "No changelist was created."
        Write-Host ""

        Write-Host "You can review the CSV at any time:"
        Write-Host $ReportFile -ForegroundColor Cyan

        Write-Host ""
        Write-Host "To run cleanup later, use:"
        Write-Host ""

        Write-Host '.\Audit-P4Ignore.ps1 -MarkDelete -Changelist Default' `
            -ForegroundColor Cyan

        Write-Host ""
        Write-Host "This creates a new numbered pending changelist."
        Write-Host ""
        Write-Host "Alternatively, to use an existing pending changelist:"
        Write-Host ""

        Write-Host '.\Audit-P4Ignore.ps1 -MarkDelete -Changelist 12345' `
            -ForegroundColor Cyan

        Write-Host ""
        Write-Host "Replace 12345 with your actual changelist number."
        Write-Host ""
        Write-Host "Cleanup will perform a fresh audit when run later."

        return
    }

    # User approved cleanup during the current audit.
    # No additional depot scan is necessary.

    $CleanupApproved = $true
    $MarkDelete = $true

    # Interactive cleanup always creates a dedicated
    # numbered pending changelist.

    $UseNewChangelist = $true
    $TargetChangelist = "Default"

    Write-Host ""
    Write-Host "Cleanup approved." -ForegroundColor Green
    Write-Host "Continuing with the current audit results."
    Write-Host "No additional depot scan required."
}


###############################################################################
# 21. CLEANUP PRECHECK
###############################################################################

if ($discoveryErrors.Count -gt 0) {
    Stop-WithError "Ignore discovery was incomplete. Cleanup disabled."
}

if ($matches.Count -eq 0) {

    Write-Host ""
    Write-Host "AUDIT COMPLETE - NO CHANGES NEEDED" `
        -ForegroundColor Green

    Write-Host "The process is complete. No changes were needed." `
        -ForegroundColor Green

    return
}

$eligible = @(
    $matches | Where-Object {
        $_.Synced -and
        [string]::IsNullOrEmpty($_.OpenAction)
    }
)

Write-Host ""
Write-Host "============================================"
Write-Host " CLEANUP PREVIEW"
Write-Host "============================================"
Write-Host ""

Write-Host "Total conflicts:     $($matches.Count)"
Write-Host "Eligible deletions:  $($eligible.Count)"
Write-Host "Skipped candidates:  $($matches.Count - $eligible.Count)"
Write-Host ""

if ($eligible.Count -eq 0) {

    Write-Host "No eligible files need deletion."
    Write-Host "No changelist was created by this operation."

    return
}

Write-Host "CSV report:"
Write-Host $ReportFile -ForegroundColor Cyan

Write-Host ""
Write-Host "Local files will be retained."
Write-Host "No changelist will be automatically submitted."
Write-Host ""

# Users launching with -MarkDelete still need to
# explicitly approve cleanup.
#
# Users who approved in Section 20 are not asked again.

if (-not $CleanupApproved) {

    Write-Host "Review the CSV report before continuing."
    Write-Host ""

    $confirmation = Read-Host (
        "Type DELETE to approve cleanup"
    )

    if ($confirmation.Trim() -cne "DELETE") {

        Write-Host ""
        Write-Host "Cleanup cancelled." `
            -ForegroundColor Yellow

        Write-Host "No files were opened for deletion."
        Write-Host ""

        Write-Host "To try again, run:"
        Write-Host ""

        if ($UseNewChangelist) {
            Write-Host '.\Audit-P4Ignore.ps1 -MarkDelete -Changelist Default' `
                -ForegroundColor Cyan
        }
        else {
            Write-Host ".\Audit-P4Ignore.ps1 -MarkDelete -Changelist $TargetChangelist" `
                -ForegroundColor Cyan
        }

        return
    }

    $CleanupApproved = $true
}

Write-Host ""
Write-Host "Approval confirmed." -ForegroundColor Green
Write-Host "Preparing pending changelist..."


###############################################################################
# 22. CREATE CHANGE IF REQUIRED
###############################################################################

if ($UseNewChangelist) {

    try {
        $TargetChangelist = New-AuditChangelist `
            -Description "P4IGNORE audit cleanup pending."
    }
    catch {
        Stop-WithError "Unable to create changelist: $_"
    }

    Write-Host ""
    Write-Host "Created changelist $TargetChangelist" `
        -ForegroundColor Green
}

###############################################################################
# 23. BATCH DELETE
###############################################################################

Write-Host ""
Write-Host "Opening eligible files for deletion..."

$batchErrors = @()

try {
    $batchErrors = @(
        Invoke-BatchDelete `
            -Files $eligible `
            -ChangeId ([string]$TargetChangelist) `
            -MaxBatchSize $BatchSize
    )
}
catch {
    $batchErrors += "Batch deletion exception: $_"
}

###############################################################################
# 24. VERIFY ACTUAL CHANGELIST CONTENTS
###############################################################################

Write-Host ""
Write-Host "Verifying opened deletion files..."

$verified = $null
$verificationFailed = $false

try {
    $verified = Get-OpenedDeletionPaths `
        -ChangeId ([string]$TargetChangelist)
}
catch {
    $verificationFailed = $true
    Write-Warning "Deletion verification failed: $_"
}

$openedCount = 0
$failedCount = 0

foreach ($item in $matches) {

    if ($item.Status -ne "Candidate") {
        continue
    }

    if ($verificationFailed) {
        $item.Status = "Unknown - verification failed"
        $failedCount++
        continue
    }

    if ($verified.Contains($item.DepotPath)) {

        $item.Status = "Opened for delete"
        $openedCount++
    }
    else {

        $item.Status = "Failed to open for delete"
        $failedCount++
    }
}

###############################################################################
# 25. UPDATE CHANGE DESCRIPTION
###############################################################################

$description = "Audit-P4Ignore.ps1 opened $openedCount files for deletion because they conflict with the current P4IGNORE rules."

if ($failedCount -gt 0) {
    $description += " $failedCount files were not successfully verified."
}

if (-not $verificationFailed -and $openedCount -gt 0) {

    try {
        Update-AuditChangelist `
            -ChangeId ([string]$TargetChangelist) `
            -Description $description `
            -ReplaceDescription $UseNewChangelist

        Write-Host "Changelist description updated." `
            -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not update changelist description: $_"
    }
}

###############################################################################
# 26. EXPORT FINAL CLEANUP REPORT
###############################################################################

$FinalReportFile = Export-SafeCsv `
    -Data @($matches.ToArray()) `
    -Columns $AuditColumns `
    -Path $FinalReportFile

if ($batchErrors.Count -gt 0) {

    $batchErrors |
        Set-Content `
            -LiteralPath $ErrorReportFile `
            -Encoding UTF8
}

###############################################################################
# 27. FINAL RESULTS
###############################################################################

Write-Host ""
Write-Host "============================================"
Write-Host " FINAL CLEANUP RESULTS"
Write-Host "============================================"
Write-Host ""

$matches |
    Group-Object Status |
    Select-Object Name, Count |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Changelist: $TargetChangelist"
Write-Host "Files opened for deletion: $openedCount"
Write-Host "Failed or unverified: $failedCount"
Write-Host ""

Write-Host "Changelist description:"
Write-Host $description -ForegroundColor Cyan

Write-Host ""
Write-Host "Reports:"
Write-Host "Audit:   $ReportFile"
Write-Host "Cleanup: $FinalReportFile"

if ($additionalIgnoreFiles.Count -gt 0) {
    Write-Host "Additional ignore files: $AdditionalReportFile"
}

if ($batchErrors.Count -gt 0) {
    Write-Host "Errors: $ErrorReportFile" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Review the pending changelist in P4V."
Write-Host "Local files have been retained."
Write-Host "No changelist was submitted." `
    -ForegroundColor Green

###############################################################################
# END
###############################################################################
