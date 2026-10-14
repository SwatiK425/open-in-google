# Privacy Policy — Open in Google

Last updated: October 13, 2026

Open in Google is a small open-source Windows utility. It has no server, no account system, no analytics, and no telemetry. Everything described below happens on your own PC.

## What the app accesses

- The Google Drive files it creates itself, and nothing else. It uses Google's `drive.file` OAuth scope, which does not grant access to the rest of your Drive.
- The local file you right-click on, in order to upload it.

## What the app does with your data

- Uploads the file you chose to the OpenInGoogle folder in your Google Drive, converts it to a Google-native format (Sheets, Docs, or Slides), and opens it in your browser.
- Stores your Google sign-in tokens encrypted with Windows DPAPI in `%LOCALAPPDATA%\OpenInGoogle\` on your PC. They are never sent anywhere except to Google's own API servers to perform the upload.
- Remembers which local files map to which Drive files (`filemap.json`) so reopening a file updates it instead of duplicating it. This file stays on your PC.

## What the app never does

- No data is sent to the developer or any third party. There is no server to send it to.
- No analytics, tracking, or telemetry of any kind.
- Your tokens never leave your machine except inside encrypted API calls to Google.

## Changes

If this policy changes, the updated version will be posted at this URL.

## Contact

For questions about this policy or the app, open an issue at:
https://github.com/SwatiK425/open-in-google/issues
