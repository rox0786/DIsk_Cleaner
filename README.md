# Kali Disk Cache Cleaner

A Bash tool to audit and reclaim disk space on Kali Linux / Debian-based pentest VMs. Started as a small cache-cleaning script and grew into a two-phase tool after running into a `No space left on device` error mid-engagement, caused by security-tool caches (Burp Suite's bundled Chromium, ZAP sessions) silently eating tens of gigabytes.

## Why this exists

Security tooling VMs fill up fast in ways generic cleaners don't catch — Burp Suite's embedded browser, ZAP session data, wordlists, VM snapshots, and language-specific dev caches (`npm`, `cargo`, `go`, `pip`) all pile up outside the usual apt/journal/trash locations. This tool started as a simple APT/journal/log cleaner (`kalicleaner.sh`, still included) and was extended into a full **discovery + maintenance** tool to catch everything a pentest workflow tends to leave behind.

## What it does

Runs in two independent phases:

### Phase 1 — Discovery
Scans 25+ known cache/junk locations and reports size before touching anything:

| Category | Examples |
|---|---|
| Browser caches | Firefox, Chrome/Chromium, Brave |
| Security tool caches | Burp Suite bundled Chromium, ZAP sessions, Metasploit loot/logs, Wireshark history |
| Dev toolchain caches | npm, pip, pipx, cargo, rustup, go modules, conda, yarn |
| System-level junk | old kernel packages, rotated logs, core dumps, trash, snap/flatpak |
| VM/container leftovers | Docker images/build cache, VirtualBox snapshots, Vagrant boxes |

Risky items (old kernels, Docker data, VM snapshots) are flagged `CHECK` and are **skipped automatically** in bulk mode — never force-deleted.

Also runs a generic sweep for large files (>100M by default) and old-untouched files (180+ days) anywhere in your home directory, so anything not on the known-category list still surfaces in the report instead of hiding silently.

### Phase 2 — Maintenance
The original `kalicleaner.sh` logic, using proper system commands rather than raw `rm -rf`:

| Target | Action |
|---|---|
| APT cache | `apt clean`, `apt autoclean`, `apt autoremove -y` |
| systemd journal | Vacuums logs older than N days |
| `/var/log/*.log` | Deletes log files older than N days |

## How it works (for beginners)

If you're new to Bash, here's what the core commands inside the script actually do:

**Checking sizes**
```bash
du -sh /path/to/folder
```
`du` = "disk usage". `-s` means summary (just the total, not every file listed), `-h` means human-readable (shows `2.5G` or `340M` instead of raw bytes). This only reports size — it deletes nothing.

```bash
df -h
```
`df` = "disk free". Shows total, used, and available space on the whole disk/partition. The script runs this before and after cleanup so you can see exactly how much space was freed.

**System maintenance (Phase 2)**
```bash
sudo apt clean
sudo apt autoclean
sudo apt autoremove -y
```
- `apt clean` deletes downloaded `.deb` package files that are already installed
- `apt autoclean` deletes only the outdated `.deb` files (superseded by newer versions)
- `autoremove -y` removes packages that were only installed as dependencies and are no longer needed; `-y` auto-confirms every prompt

```bash
sudo journalctl --vacuum-time=7d
```
`journalctl` manages systemd's logs. `--vacuum-time=7d` means "keep only the last 7 days of logs, delete anything older."

## How to use the tool (step by step)

**Step 1 — Get the script and make it runnable**
```bash
git clone https://github.com/rox0786/Disk_cleaner
cd disk-cleaner
chmod +x disk-cleaner.sh
```

**Step 2 — Run a report-only scan first**
```bash
./disk-cleaner.sh
```
This is always safe to run — it only scans and reports sizes. Nothing gets deleted at this stage. Read through the output to see what's taking up space.

**Step 3 — Preview the large/old file sweep (included automatically)**
No extra command needed — this runs as part of Step 2. If you want to tune it, use `--min-size` and `--old-days`:
```bash
./disk-cleaner.sh --min-size 200M --old-days 90
```

**Step 4 — Clean up what was found, with confirmation**
```bash
./disk-cleaner.sh --clean
```
This re-runs the scan and asks `y/N` before deleting each item, so you stay in control the whole time.

**Step 5 — (Optional) Skip the prompts once you trust the results**
```bash
./disk-cleaner.sh --clean --yes
```
This deletes everything found, except items flagged `CHECK` (like old kernels, Docker data, VM snapshots) — those always require individual confirmation, no matter what.

**Step 6 — (Optional) Run system-level maintenance**
```bash
./disk-cleaner.sh --maintenance --dry-run
```
Preview what the APT/journal/log cleanup would do, without changing anything. Once you're comfortable with the output:
```bash
./disk-cleaner.sh --maintenance
```

**Step 7 — (Optional) Do everything in one pass**
```bash
./disk-cleaner.sh --clean --yes --maintenance
```
Runs the full discovery cleanup and the system maintenance phase together.

### All options

| Flag | Description |
|---|---|
| `--clean` | Discovery phase: prompt before deleting each found item |
| `--yes` | Combined with `--clean`, delete all non-`CHECK` items without prompting |
| `--maintenance` | Run Phase 2 (apt/journal/log cleanup) |
| `--dry-run` | Preview Phase 2 commands without running them |
| `--days N` | Log/journal retention for Phase 2 (default: 7) |
| `--min-size SIZE` | Large-file threshold for the discovery sweep (default: 100M) |
| `--old-days N` | "Old file" threshold for the discovery sweep (default: 180) |
| `--no-largefiles` | Skip the generic large/old file sweep (faster) |
| `--list` | Print known categories and exit |
| `--help` | Show usage |

## Requirements

- Kali Linux or any Debian/Ubuntu-based system
- `sudo` privileges (for APT, journal, and `/var/log` cleanup)
- Standard tools: `apt`, `journalctl`, `find`, `du`, `numfmt`

## Notes

- Nothing is deleted unless `--clean` (Phase 1) or `--maintenance` (Phase 2) is explicitly passed — plain runs are report-only.
- Items flagged `CHECK` (old kernels, Docker data, VM snapshots) require individual confirmation even in `--yes` mode.
- `kalicleaner.sh` is kept in the repo standalone for anyone who wants the lightweight, single-purpose version without the discovery phase.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome. If you add a new cleanup target, please gate it behind a flag or a `CHECK`-style tag rather than making it run unconditionally, so users keep full control over what gets deleted.
