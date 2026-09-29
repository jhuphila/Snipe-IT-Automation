# Snipe-IT Auto-Registration for Windows

PowerShell script to automatically register Windows assets into Snipe-IT for **Drexel SCIS Commons** post-deployment.

## What It Does

- Detects system info via WMI (hostname, serial, model, manufacturer, chassis type)
- Collects hardware specs (RAM, CPU, SSD/HDD, GPU, UUID)
- Creates or updates the asset in Snipe-IT with a "Loaner Equipment" status
- Auto-creates categories, manufacturers, and models if they don't exist
- Only sends custom fields that exist in the model's fieldset

## Prerequisites

- PowerShell 5.1+
- Network access to `https://snipe-it.cci.drexel.edu`
- A `.env` file in the script directory containing your API token:
  ```
  snipe-it_api_key=YOUR_API_TOKEN_HERE
  ```

## Usage

```powershell
.\snipe-it_auto.ps1
```

The script will:
1. Display detected system info and hardware specs
2. Prompt for confirmation before creating new models
3. Prompt for final confirmation before creating/updating the asset
4. Output a direct link to the asset in Snipe-IT

## Notes

- **Testing version** — API token loaded from local `.env` file (not for USB deployment)
- Assets are left **unassigned** (no automatic checkout)
- Chassis detection determines Laptop vs Desktop category
- Manufacturer names are normalized (e.g., "Hewlett-Packard" → "HP")
