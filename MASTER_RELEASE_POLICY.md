# MASTER RELEASE / PRESERVATION POLICY

This repository is the master source for Pi Node Telegram Controller PRO.

## Preservation rules

- Do not remove existing files, commands, modules, configuration, knowledge files,
  diagnostics, schedulers, BAT launchers, executables, or workflows unless explicitly
  approved.
- Preserve the existing application name and repository URL:
  https://github.com/cannoi/pinode-telegram-controller
- Preserve the existing Windows download URL:
  https://github.com/cannoi/pinode-telegram-controller/archive/refs/heads/main.zip
- Preserve existing command-line installation behavior.
- New functionality must be additive and must not silently disable existing behavior.
- Before changing a file, verify which other files depend on it.
- Keep backups/releases when making significant upgrades.
- Validate PowerShell syntax and JSON/configuration syntax before release.
- Verify the main branch contains all runtime files required by Start_Controller.bat.
- Do not replace a working module with a simplified implementation merely to reduce
  code size or complexity.

## Release checklist

1. Inventory repository files.
2. Validate PowerShell syntax.
3. Validate JSON/config files.
4. Verify launcher files and paths.
5. Verify required modules and data files exist.
6. Verify GitHub Actions workflow.
7. Verify repository and download URLs remain unchanged.
8. Compare the release against the previous version and investigate unexpected deletions.
9. Publish only after the checks pass.
