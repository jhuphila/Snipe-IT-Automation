# Updating the encrypted API token or passphrase

The passphrase is **not stored in the script**. Only an AES-encrypted blob lives in `$EncryptedTokenBase64` in `snipe-it_auto.ps1`.

1. Run `.\Encrypt-Token.ps1`.
2. Enter the current Snipe-IT API token, then the **new** passphrase twice (minimum 8 characters).
3. Copy the printed Base64 string (also copied to the clipboard when available).
4. In `snipe-it_auto.ps1`, replace the value of `$EncryptedTokenBase64` with that string. Nothing else in the script needs to change.
5. Commit/push the script. Share the new passphrase **verbally** with technicians; do not put it in git, the script, or this doc.

At runtime, technicians enter the passphrase when the script starts (press Enter with nothing typed to cancel). For local development, `.\snipe-it_auto.ps1 -UseLocalEnv` still reads the token from `.env`.