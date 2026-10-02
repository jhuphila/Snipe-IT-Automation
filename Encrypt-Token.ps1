# Encrypt-Token.ps1
# Run once to generate snipeit-token.enc from the API token + passphrase
# Usage: .\Encrypt-Token.ps1

param(
    [string]$OutputPath = ".\snipeit-token.enc"
)

Add-Type -AssemblyName System.Security

function Encrypt-StringWithPassphrase {
    param(
        [Parameter(Mandatory)][string]$PlainText,
        [Parameter(Mandatory)][SecureString]$Passphrase
    )
    
    # Convert SecureString to plain text for key derivation
    $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
    $PassphraseText = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    
    # Generate random salt (16 bytes)
    $Salt = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Fill($Salt)
    
    # Derive key using PBKDF2 (RFC 2898)
    $KeyDerivation = New-Object Security.Cryptography.Rfc2898DeriveBytes(
        $PassphraseText, $Salt, 100000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $Key = $KeyDerivation.GetBytes(32)  # AES-256
    $IV = $KeyDerivation.GetBytes(16)
    
    # Clear passphrase from memory
    $PassphraseText = $null
    [GC]::Collect()
    
    # Encrypt with AES-256-CBC
    $Aes = [Security.Cryptography.Aes]::Create()
    $Aes.Key = $Key
    $Aes.IV = $IV
    $Aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $Aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    
    $Encryptor = $Aes.CreateEncryptor()
    $PlainBytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    $EncryptedBytes = $Encryptor.TransformFinalBlock($PlainBytes, 0, $PlainBytes.Length)
    
    $Aes.Dispose()
    
    # Return salt + encrypted data (salt needed for decryption)
    return $Salt + $EncryptedBytes
}

# Prompt for inputs
Write-Host "=== Snipe-IT Token Encryption ===" -ForegroundColor Cyan
Write-Host "This will create an encrypted token file for USB deployment." -ForegroundColor Gray
Write-Host ""

$Token = Read-Host -Prompt "Enter the Snipe-IT API token" -AsSecureString
$TokenBSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
$TokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($TokenBSTR)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($TokenBSTR)

if ([string]::IsNullOrWhiteSpace($TokenPlain)) {
    Write-Error "Token cannot be empty."
    exit 1
}

Write-Host ""
$Passphrase = Read-Host -Prompt "Enter passphrase (memorize this - share verbally only)" -AsSecureString
$PassphraseConfirm = Read-Host -Prompt "Confirm passphrase" -AsSecureString

# Verify passphrases match
$P1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase))
$P2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PassphraseConfirm))

if ($P1 -ne $P2) {
    Write-Error "Passphrases do not match."
    exit 1
}
if ($P1.Length -lt 8) {
    Write-Error "Passphrase must be at least 8 characters."
    exit 1
}
$P1 = $null; $P2 = $null
[GC]::Collect()

# Encrypt and save
$EncryptedData = Encrypt-StringWithPassphrase -PlainText $TokenPlain -Passphrase $Passphrase
[IO.File]::WriteAllBytes($OutputPath, $EncryptedData)

# Clear sensitive data
$TokenPlain = $null
[GC]::Collect()

Write-Host ""
Write-Host "Encrypted token saved to: $OutputPath" -ForegroundColor Green
Write-Host "Copy this file to the deployment USB." -ForegroundColor Yellow
Write-Host "DO NOT write down the passphrase - share it verbally with technicians." -ForegroundColor Red