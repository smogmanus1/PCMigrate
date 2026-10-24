# Writing compatibility rules

All of PCMigrate's hardware knowledge lives in [`rules/compat-rules.json`](../rules/compat-rules.json). You can edit it with any text editor; the launcher's **Hardware rules** button opens it. Rules are evaluated on the **new** PC.

## What a rule matches

Every app, settings folder and registry key has a set of *candidate names*:

- **Apps to install:** the winget ID (`AMD.RyzenMaster`) and the app name.
- **Install by hand:** the program name and publisher.
- **Settings:** the folder or vendor name (`logioptionsplus`, `Martin Prikryl`), plus the names and publishers of the programs it was matched to.

`match` patterns use `*` wildcards and are case-insensitive. `except` patterns exclude names.

## Rule types

```json
{
  "id": "nvidia",
  "match": ["NVIDIA*", "Nvidia.*"],
  "except": ["Nvidia.GeForceNow*"],
  "requires": { "gpu": "NVIDIA" },
  "reason": "NVIDIA software - this PC has no NVIDIA graphics."
}
```

| `action` | Effect |
|---|---|
| *(none)* with `requires` | If the requirement fails, the item becomes **Wrong hardware**, or **Device not found** with `"soft": true` (for things that may be plugged in later) |
| `"skip"` | Always **Not recommended** (identity settings, adware, drivers) |
| `"optional"` | Always **Optional**, unticked (e.g. a second antivirus) |
| `"note"` | Adds the `note` text; doesn't change the status |

`appliesTo` limits a rule to `"install"`, `"checklist"` and/or `"settings"`. Example: Tailscale should be *installed* but its *settings* must never be copied.

When several rules hit, the strongest wins: **skip > hardware > device not found > optional**. Notes always accumulate.

## Requirements

Values are **regular expressions** tested against this PC:

| Key | Tested against |
|---|---|
| `gpu` | Graphics adapter names |
| `cpu` | Processor name + vendor (`AMD`, `Intel`, `ARM`) |
| `manufacturer` | System maker, motherboard maker and model |
| `model` | System model |
| `chassis` | `laptop` or `desktop` (unknown never blocks) |
| `device` | Every present device as `Manufacturer \| Name \| VID_xxxx` - USB vendor IDs are reliable: Logitech `VID_046D`, CyberPower `VID_0764`, Garmin `VID_091E` |
| `printer` | Installed printer names and drivers |
| `arch` | `AMD64`, `ARM64` |
| `os` | Windows edition and build |

Alternatives: `{ "anyOf": [ { "printer": "Brother" }, { "device": "Brother" } ] }`.

## Other sections

- **`aliases`**: settings folder or registry vendor name → program name patterns, for names that don't look like the program (`"Martin Prikryl": ["WinSCP*"]`).
- **`shared`**: settings that belong to Windows or many apps; selected by default.
- **`alternatives`**: apps the old PC installed by hand that winget can install (`{ "match": ["Mozilla Firefox*"], "winget": "Mozilla.Firefox" }`). Please verify the ID exists (`winget show --id <ID>`).
- **`suggest`**: tools to offer when the new PC matches `when` (same keys as `requires`).

## Testing a rule

Run **Preview only** from the launcher. It writes the HTML report without changing anything, so you can see how every item was classified and why.
