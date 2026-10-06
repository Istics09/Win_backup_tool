# User Files Backup Script

A PowerShell script that copies a user's personal files to an external drive. It works on Windows 10 and Windows 11 regardless of the system language (tested with Hungarian, English and Slovak Windows).

## What it backs up

- Desktop
- Documents
- Pictures
- Videos
- Downloads
- OneDrive (all accounts, personal and business)

All files are included, hidden and system files too.

## Files

| File | Purpose |
|---|---|
| `Backup.ps1` | The backup script |
| `Run_Backup.bat` | Launcher that starts the script with `-ExecutionPolicy Bypass` |

Keep both files in the same folder, for example on a USB stick.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1, which is built into both
- No administrator rights needed; run it as the user whose files you want to back up

## Usage

1. Plug in the target drive.
2. Double-click `Run_Backup.bat`.
3. Enter the target drive letter when asked (for example `E`).
4. The script tests whether it can write to the drive. If the test fails, it asks for a drive letter again.
5. It lists the source folders it found, counts the files and checks free space.
6. Copying starts with a progress bar. The bar shows the current file, the file count, the copied size, the percentage and the estimated time left.
7. At the end it prints a summary and waits for Enter.

## Output

The backup goes into a new folder on the target drive:

```
E:\Backup_<COMPUTERNAME>_<USERNAME>_<yyyy-MM-dd_HH-mm>\
    OneDrive - <Company>\
    Desktop\
    Documents\
    Pictures\
    Videos\
    Downloads\
    backup_log.txt
```

Only the folders that exist and are not already covered by another source appear in the backup.

`backup_log.txt` contains:
- the source folders,
- the number of copied files and their total size,
- the duration,
- every file that failed, with the reason,
- folders that could not be read during the scan.

## How it works

### Language independent folder detection

The script never looks for folder names like "Desktop", "Asztal" or "Plocha". It asks Windows where the folders are:

| Folder | Source |
|---|---|
| Desktop, Documents, Pictures, Videos | .NET `[Environment]::GetFolderPath()` |
| Downloads | Known Folder GUID `{374DE290-123F-4565-9164-39C4925E467B}` in `HKCU\...\Explorer\User Shell Folders` |
| OneDrive | `%OneDrive%`, `%OneDriveCommercial%`, `%OneDriveConsumer%` and `HKCU\Software\Microsoft\OneDrive\Accounts\*\UserFolder` |

This also works when a folder has been moved to another location or drive.

### No duplicates with OneDrive folder backup

If OneDrive Known Folder Move is enabled, Desktop, Documents and Pictures live inside the OneDrive folder. OneDrive is added as a source first. Any folder that sits inside an existing source is skipped, so nothing is copied twice.

### Long paths

Paths longer than 248 characters get the `\\?\` prefix, so files with deep folder structures can still be copied.

## Notes and limitations

- **OneDrive "online-only" files.** Files that exist only in the cloud are downloaded during the copy. With a large OneDrive this can take a long time and temporarily uses space on the system drive.
- **Locked files.** Files that are open in another program (for example an Outlook `.pst` or an open KeePass database) may fail to copy. They are listed in the log. Close the programs before running the backup.
- **Existing files are overwritten.** This only matters if you run the script twice within the same minute, since each run creates a new timestamped folder.
- **Progress during large files.** The progress bar updates between files, so it pauses while a single large file (for example an ISO) is being copied.
- **Current user only.** The script backs up the profile of the user who runs it, not other users on the machine.

## Troubleshooting

| Problem | Solution |
|---|---|
| The window closes immediately | Start `Run_Backup.bat` from a command prompt to see the error message. |
| "Cannot write to X:\" | The drive is read-only, full, or BitLocker-locked. Unlock it or use another drive. |
| A folder is "not found, skipped" | That folder does not exist for this user. This is normal. |
| Many errors in the log for one folder | Check whether a program has those files open, or whether the user has access to them. |