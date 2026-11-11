# Audit-P4Ignore.ps1

A PowerShell utility that identifies files already tracked in a Perforce depot that conflict with the workspace's current `P4IGNORE` rules. Optionally removes those files from version control while preserving local copies.

### Features

- Automatically detects and validates the Perforce workspace.
- Supports `.p4ignore`, `p4ignore.txt`, custom ignore filenames, and nested ignore files.
- Audits tracked depot files using optimized, batched Perforce commands.
- Generates a CSV report containing conflicting files and their matching ignore rules.
- Displays the first 20 conflicts and prompts for cleanup approval.
- Creates a pending changelist with an automatically generated description.
- Preserves local files and never automatically submits a changelist.

### Usage

- Place the script in the root of the workspace you are wanting to audit.
- Open a PowerShell window from the root of your workspace or cd there.
- Enter one of the below commands:

**If you're unsure which command to use, just start with:**

```powershell
.\Audit-P4Ignore.ps1
```

The script will scan the workspace, generate a CSV report, and guide you through the next steps. Review the CSV and type `DELETE` when prompted to approve cleanup, or press Enter to exit without making changes.

**Additional commands:**

```powershell
# Audit and request cleanup into a new numbered changelist
.\Audit-P4Ignore.ps1 -MarkDelete -Changelist Default

# Use an existing numbered pending changelist
.\Audit-P4Ignore.ps1 -MarkDelete -Changelist 12345

# Change the audit batch size (default: 100)
.\Audit-P4Ignore.ps1 -BatchSize 250
```

### Reports

- `P4IgnoreAudit.csv` — Files conflicting with the current ignore rules.
- `P4IgnoreAudit_Cleanup.csv` — Results after cleanup.
- `P4IgnoreAdditionalFiles.csv` — Additional ignore files discovered in the workspace.

If a report is locked by another application, a timestamped CSV is created instead.

### Requirements

- Windows PowerShell 5.1 or newer
- Perforce CLI (`p4.exe`)
- Run PowerShell from the **root of the Perforce workspace**

**Important:** Cleanup only opens files for deletion in a pending changelist. Review and submit the changelist through P4V to complete the removal from the depot. Previously submitted file revisions remain in Perforce history.
