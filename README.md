# Audit-P4Ignore.ps1

A PowerShell utility that audits files tracked in a Perforce depot against the workspace's current `.p4ignore` rules. Identifies conflicting files and optionally removes them from version control while preserving local copies.

## Features

- **Workspace Detection:** Automatically detects and validates the Perforce workspace and its root directory.
- **Ignore Rule Support:** Supports `.p4ignore`, `p4ignore.txt`, custom filenames, and nested ignore files. Warns when both default filenames exist in the same directory.
- **Optimized Auditing:** Uses bulk metadata retrieval and batched ignore evaluations for efficient scanning of large depots.
- **CSV Reports:** Lists conflicting files, their paths, and the ignore rules responsible. Displays the first 20 conflicts in the console.
- **Interactive Cleanup:** Allows users to review the audit and type `DELETE` to approve removal from version control.
- **Changelist Management:** Creates a numbered pending changelist with an automatically generated description and deletion count.
- **Safe Operation:** Preserves local files, handles locked CSV reports, and never automatically submits changelists.

## Requirements

- Windows PowerShell 5.1 or newer
- Perforce CLI (`p4.exe`) available in PATH
- Access to the Perforce server
- Run PowerShell from the **root directory of the workspace**

## Usage

**If you're unsure which command to use, start with:**

```powershell
.\Audit-P4Ignore.ps1
```

The script guides you through workspace selection, audits tracked files, and generates a CSV report.

If conflicts are found, review the report and type `DELETE` when prompted to continue cleanup. Press Enter to exit without making changes.

### Additional Commands

```powershell
# Audit and approve cleanup into a new numbered changelist
.\Audit-P4Ignore.ps1 -MarkDelete -Changelist Default

# Use an existing numbered pending changelist
.\Audit-P4Ignore.ps1 -MarkDelete -Changelist 12345

# Adjust batch size (default: 100)
.\Audit-P4Ignore.ps1 -BatchSize 250
```

The `Default` option creates a **new numbered changelist**, rather than using Perforce's actual default changelist.

## Generated Reports

| File | Purpose |
|---|---|
| `P4IgnoreAudit.csv` | Identifies conflicting files and their matching ignore rules |
| `P4IgnoreAudit_Cleanup.csv` | Records the results of the cleanup operation |
| `P4IgnoreAdditionalFiles.csv` | Lists additional ignore files discovered in the workspace |

If a CSV is open or locked, the script generates a timestamped alternative instead of failing.

## Important Notes

- Files are only **opened for deletion** until the pending changelist is submitted through P4V.
- Local file copies are preserved.
- Previously submitted revisions remain available in Perforce history.
- Nested ignore files may extend or override workspace-level rules; review them before consolidating.
- If no conflicts are found, the script reports **AUDIT COMPLETE - NO CHANGES NEEDED**.
- Non-ASCII filenames may produce encoding warnings. The script attempts to handle these safely and stops cleanup if ignore evaluation cannot be completed.
  - Character encoding: On Windows, the script uses Windows-1252 to handle accented filenames when communicating with non-Unicode Perforce servers. Other server or client configurations may require a different encoding.

**After cleanup:** Review and submit the pending changelist in P4V, then rerun the audit to verify that no conflicts remain.
