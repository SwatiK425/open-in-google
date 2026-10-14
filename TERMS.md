# Terms of Service — Open in Google

Last updated: October 13, 2026

## What this is

Open in Google is a free, open-source Windows utility (MIT licensed) that adds right-click menu entries for opening Office and CSV files in Google Sheets, Docs, and Slides. It is provided as-is, without warranty of any kind.

## How it works

The app runs entirely on your PC. It uses Google's Drive API with the `drive.file` scope, which only permits access to files the app itself created. You supply your own Google Cloud OAuth credential; the app never sees or stores anyone else's.

## Your responsibilities

- You are responsible for your own Google account, your OAuth client credential, and activity under them.
- Files you upload count against your own Google Drive storage quota.
- If you stop using the app, run `Uninstall.ps1` to remove the right-click entries. Your Drive files remain until you delete them.

## No affiliation

This project is not affiliated with, endorsed by, or sponsored by Google or Microsoft. Google Workspace and Microsoft 365 are trademarks of their respective owners.

## Limitation of liability

To the maximum extent permitted by law, the developer is not liable for any loss of data, downtime, or damages arising from use of this software. Review the source code yourself; that is the point of open source.

## Changes

These terms may be updated. The current version will always be posted at this URL.

## Contact

Questions: https://github.com/SwatiK425/open-in-google/issues
