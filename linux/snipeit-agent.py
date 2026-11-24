#!/usr/bin/env python3
"""Snipe-IT inventory sensor for Linux.

Collects hardware and software facts and writes them into the matching Snipe-IT
asset's custom fields (the same fields the Windows and macOS agents fill). The asset
is found by the DMI serial number, or by "AssetTag" in the config as a fallback.

Python 3.6+ standard library only. Runs as root from a systemd timer.

    sudo /opt/snipeit-agent/snipeit-agent.py --dry-run      # collect and show, change nothing
    sudo /opt/snipeit-agent/snipeit-agent.py                # collect and push

Options:
    --dry-run          show what would be sent; never writes to Snipe-IT
    --config PATH      default /etc/snipeit-agent/config.json
"""
import datetime
import glob
import html
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

AGENT_VERSION = "1.0.0"
DEFAULT_CONFIG = "/etc/snipeit-agent/config.json"
STATE_DIR = "/var/lib/snipeit-agent"
LOG_PATH = "/var/log/snipeit-agent.log"

FIELD_NAMES = {
    "HardwareModel": "Hardware Model",
    "Hostname": "Hostname",
    "CPU": "CPU",
    "RamGB": "RAM (GB)",
    "Storage": "Storage",
    "DiskFreeGB": "Disk Free C: (GB)",  # shared field name; holds free space on /
    "Volumes": "Volumes",
    "OS": "Operating System",
    "OSBuild": "OS Build",
    "IPAddress": "IP Address",
    "MACAddress": "MAC Address (Agent)",
    "LastUser": "Last Logged-in User",
    "SoftwareCount": "Software Count",
    "Software": "Installed Software",
    "LastInventory": "Last Inventory",
}
VOLATILE = {"DiskFreeGB", "Volumes", "IPAddress", "LastUser"}

# Tests replace commands and files through this JSON map: {"cmd:<prefix>": out, "file:<path>": text}
_FIXTURES = {}
if os.environ.get("SNIPEIT_AGENT_FIXTURES"):
    with open(os.environ["SNIPEIT_AGENT_FIXTURES"], encoding="utf-8") as _f:
        _FIXTURES = json.load(_f)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def log(msg, level="INFO"):
    line = "%s [%s] %s" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), level, msg)
    print(line, flush=True)
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 1024 * 1024:
            os.replace(LOG_PATH, LOG_PATH + ".old")
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def run(cmd):
    """Run a command (list) and return stdout, or '' if it fails or is missing."""
    key = " ".join(cmd)
    for prefix, out in _FIXTURES.items():
        if prefix.startswith("cmd:") and key.startswith(prefix[4:]):
            return out
    if _FIXTURES.get("strict"):
        return ""
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True, timeout=120).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def read(path):
    if "file:" + path in _FIXTURES:
        return _FIXTURES["file:" + path]
    if _FIXTURES.get("strict"):
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def gb(n, base=1e9):
    try:
        return str(int(round(float(n) / base)))
    except (TypeError, ValueError):
        return ""


def clean(s):
    return re.sub(r"\s+", " ", s or "").strip()


JUNK = re.compile(r"^(To be filled by O\.E\.M\.|Default string|System Product Name|System manufacturer|"
                  r"Not Specified|Not Applicable|None|N/A|0+|123456789|System Serial Number|Chassis Serial Number)?$", re.I)


# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------
def clean_manufacturer(name):
    n = clean(name)
    for rx, out in [(r"^Dell", "Dell"), (r"^LENOVO", "Lenovo"), (r"^(HP|Hewlett)", "HP"), (r"^ASUS", "ASUS"),
                    (r"^Acer", "Acer"), (r"^(TOSHIBA|Dynabook)", "Toshiba"), (r"^(Micro-Star|MSI)", "MSI"),
                    (r"^Gigabyte", "Gigabyte"), (r"^Intel", "Intel"), (r"^Microsoft", "Microsoft"),
                    (r"^Samsung", "Samsung"), (r"^Apple", "Apple"), (r"^(QEMU|innotek)", "Virtual")]:
        if re.match(rx, n, re.I):
            return out
    return re.sub(r",?\s+(Inc\.?|Corporation|Corp\.?|Co\.,? ?Ltd\.?|Ltd\.?|Technology).*$", "", n).strip()


def get_serial():
    for p in ("/sys/class/dmi/id/product_serial", "/sys/class/dmi/id/chassis_serial", "/sys/class/dmi/id/board_serial"):
        s = clean(read(p))
        if s and not JUNK.match(s):
            return s
    return None


def get_hardware_model():
    d = "/sys/class/dmi/id/"
    mfr, model = clean(read(d + "sys_vendor")), clean(read(d + "product_name"))
    if re.match(r"^LENOVO", mfr, re.I):  # Lenovo: product_name is the machine type, version is the marketing name
        v = clean(read(d + "product_version"))
        if v and not JUNK.match(v):
            model = v
    if JUNK.match(mfr) or JUNK.match(model):
        mfr, model = clean(read(d + "board_vendor")), clean(read(d + "board_name"))
    mfr = clean_manufacturer(mfr)
    if model.lower().startswith(mfr.lower() + " "):
        model = model[len(mfr) + 1:]
    return clean(mfr + " " + model)


def get_cpu():
    m = re.search(r"^model name\s*:\s*(.+)$", read("/proc/cpuinfo"), re.M)
    if m:
        return clean(m.group(1))
    m = re.search(r"^Model name:\s*(.+)$", run(["lscpu"]), re.M)  # ARM
    return clean(m.group(1)) if m else ""


def get_ram_gb():
    total = 0
    for line in run(["dmidecode", "-t", "17"]).splitlines():
        m = re.match(r"\s*Size:\s*(\d+)\s*(MB|GB)", line)
        if m:
            total += int(m.group(1)) * (1024 if m.group(2) == "GB" else 1)
    if total:
        return str(int(round(total / 1024.0)))
    m = re.search(r"^MemTotal:\s*(\d+)\s*kB", read("/proc/meminfo"), re.M)
    if not m:
        return ""
    gib = int(m.group(1)) / 1048576.0
    # The kernel reserves some memory; round up to the next whole GB.
    return str(int(-(-gib // 1)))


def parse_storage(lsblk_json):
    parts = []
    for dev in json.loads(lsblk_json or "{}").get("blockdevices", []):
        if dev.get("type") != "disk" or (dev.get("tran") or "") == "usb":
            continue
        if re.match(r"^(loop|ram|zram|sr|fd)", dev.get("name", "")):
            continue
        tran = (dev.get("tran") or "").lower()
        rota = str(dev.get("rota")).lower() in ("1", "true")
        media = "NVMe SSD" if tran == "nvme" or dev.get("name", "").startswith("nvme") else ("HDD" if rota else "SSD")
        model = clean(dev.get("model") or dev.get("name"))
        parts.append("%s %s GB (%s)" % (media, gb(dev.get("size")), model))
    return "; ".join(parts)


def parse_df(df_out):
    """df -B1 --output=target,size,avail,fstype -> (volumes text, free GB on /)."""
    vols, root_free = [], ""
    for line in df_out.splitlines()[1:]:
        f = line.split()
        if len(f) < 4:
            continue
        target, size, avail, fstype = f[0], f[1], f[2], f[3]
        if fstype in ("tmpfs", "devtmpfs", "squashfs", "overlay", "efivarfs", "vfat", "iso9660") or target.startswith(("/snap", "/boot", "/run", "/sys", "/proc", "/dev")):
            continue
        vols.append("%s %s GB free of %s GB" % (target, gb(avail), gb(size)))
        if target == "/":
            root_free = gb(avail)
    return "; ".join(vols), root_free


def get_os():
    rel = {}
    for line in read("/etc/os-release").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            rel[k] = v.strip().strip('"')
    return rel.get("PRETTY_NAME") or rel.get("NAME", "Linux"), run(["uname", "-r"]).strip()


def get_network():
    out = run(["ip", "-o", "route", "get", "1.1.1.1"])
    dev = re.search(r"\bdev\s+(\S+)", out)
    src = re.search(r"\bsrc\s+(\S+)", out)
    if not dev:
        return "", ""
    mac = read("/sys/class/net/%s/address" % dev.group(1)).upper()
    return (src.group(1) if src else ""), mac


def get_last_user():
    for line in run(["who"]).splitlines():
        f = line.split()
        if f and (len(f) < 2 or f[1].startswith(("tty", ":", "seat")) or "(:" in line):
            return f[0]
    for line in run(["loginctl", "list-sessions", "--no-legend"]).splitlines():
        f = line.split()
        if len(f) >= 3 and f[2] not in ("gdm", "lightdm", "sddm"):
            return f[2]
    out = run(["last", "-n", "1", "-w"]).split()
    return out[0] if out and out[0] not in ("wtmp", "reboot") else ""


def package_version(path):
    out = run(["dpkg", "-S", path])
    if out and ":" in out:
        pkg = out.split(":", 1)[0].split(",")[0].strip()
        ver = run(["dpkg-query", "-W", "-f=${Version}", pkg]).strip()
        if ver:
            return ver
    ver = run(["rpm", "-qf", "--qf", "%{VERSION}", path]).strip()
    return ver if ver and "not owned" not in ver else ""


def get_software(excludes):
    """Desktop applications (what users see in their app menu), plus snaps and flatpaks.
    Falls back to manually installed packages on machines without a desktop."""
    apps = {}
    dirs = ["/usr/share/applications", "/usr/local/share/applications",
            "/var/lib/flatpak/exports/share/applications", "/var/lib/snapd/desktop/applications"]
    for d in dirs:
        for path in sorted(glob.glob(os.path.join(d, "*.desktop"))):
            text = read(path)
            sect = text.split("[Desktop Entry]", 1)[-1].split("\n[", 1)[0]
            def val(k):
                m = re.search(r"^%s=(.*)$" % k, sect, re.M)
                return m.group(1).strip() if m else ""
            if val("Type") not in ("", "Application") or val("NoDisplay").lower() == "true" or val("Hidden").lower() == "true":
                continue
            name = clean(val("Name"))
            if not name or "snapd" in d or "flatpak" in d:
                continue  # snaps/flatpaks listed with versions below
            apps.setdefault(name.lower(), (name, package_version(path)))
    for line in run(["snap", "list"]).splitlines()[1:]:
        f = line.split()
        if len(f) >= 2 and not re.match(r"^(core\d*|snapd|bare|gnome-\d|gtk-common-themes|kf5-|mesa-)", f[0]):
            apps.setdefault(f[0].lower(), (f[0] + " (snap)", f[1]))
    for line in run(["flatpak", "list", "--app", "--columns=name,version"]).splitlines():
        f = line.split("\t")
        if f and f[0].strip():
            apps.setdefault(f[0].strip().lower(), (f[0].strip(), f[1].strip() if len(f) > 1 else ""))
    if not apps:
        for pkg in run(["apt-mark", "showmanual"]).split():
            apps[pkg] = (pkg, run(["dpkg-query", "-W", "-f=${Version}", pkg]).strip())
    result = []
    for name, ver in apps.values():
        if any(re.search(rx, name) for rx in excludes):
            continue
        result.append((name, ver))
    return sorted(result, key=lambda a: (a[0].lower(), a[1]))


def collect(cfg):
    inv = {"Serial": get_serial(), "HardwareModel": get_hardware_model()}
    inv["Hostname"] = socket.gethostname().split(".")[0]
    inv["CPU"] = get_cpu()
    inv["RamGB"] = get_ram_gb()
    inv["Storage"] = parse_storage(run(["lsblk", "-J", "-b", "-d", "-o", "NAME,SIZE,ROTA,TRAN,MODEL,TYPE"]))
    inv["Volumes"], inv["DiskFreeGB"] = parse_df(run(["df", "-B1", "--output=target,size,avail,fstype"]))
    inv["OS"], inv["OSBuild"] = get_os()
    inv["IPAddress"], inv["MACAddress"] = get_network()
    inv["LastUser"] = get_last_user()
    apps = get_software(cfg.get("SoftwareExclude") or [])
    inv["SoftwareCount"] = str(len(apps))
    text = "\n".join("%s (%s)" % (n, v) if v else n for n, v in apps)
    limit = int(cfg.get("MaxSoftwareChars") or 60000)
    inv["Software"] = text if len(text) <= limit else text[:limit] + "\n... (truncated)"
    return inv


# ---------------------------------------------------------------------------
# Snipe-IT
# ---------------------------------------------------------------------------
class SnipeError(Exception):
    def __init__(self, msg, status=None):
        super().__init__(msg)
        self.status = status


def api(cfg, method, path, body=None):
    url = cfg["SnipeUrl"] + "/api/v1/" + path.lstrip("/")
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + cfg["ApiToken"], "Accept": "application/json",
        "Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            status, text = r.status, r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode("utf-8", "replace")
    if status == 401:
        raise SnipeError("401 Unauthorized: the API token is wrong or revoked", 401)
    if status == 403:
        raise SnipeError("403 Forbidden: the agent user needs Assets View and Edit", 403)
    try:
        result = json.loads(text)
    except ValueError:
        raise SnipeError("%s %s returned HTTP %s and no JSON (check SnipeUrl)" % (method, path, status), status)
    if isinstance(result, dict) and result.get("status") == "error":
        raise SnipeError("Snipe-IT error on %s %s: %s" % (method, path, json.dumps(result.get("messages"))), status)
    if status >= 400:
        raise SnipeError("%s %s returned HTTP %s" % (method, path, status), status)
    return result


def find_asset(cfg, serial, tag):
    if serial:
        try:
            rows = api(cfg, "GET", "hardware/byserial/" + urllib.parse.quote(serial, safe="")).get("rows") or []
            if len(rows) == 1:
                return rows[0]
            if len(rows) > 1:
                raise SnipeError("Serial '%s' matches %d assets (tags: %s). Fix the duplicate serials, then rerun."
                                 % (serial, len(rows), ", ".join(str(r.get("asset_tag")) for r in rows)))
        except SnipeError as e:
            if "matches" in str(e) or not (e.status == 404 or re.search(r"not found|does not exist", str(e), re.I)):
                raise
    if tag:
        rows = api(cfg, "GET", "hardware?limit=50&search=" + urllib.parse.quote(tag, safe="")).get("rows") or []
        match = [r for r in rows if r.get("asset_tag") == tag]
        if len(match) == 1:
            return match[0]
    return None


def normalize(v):
    return html.unescape(v or "").replace("\r\n", "\n").strip()


def build_payload(asset, inv, field_names, heartbeat_days, now):
    existing = {name: (f.get("field"), f.get("value")) for name, f in (asset.get("custom_fields") or {}).items()}
    stable, volatile, missing = [], [], []
    for key, fname in field_names.items():
        if key == "LastInventory":
            continue
        if fname not in existing:
            missing.append(fname)
            continue
        val = "" if inv.get(key) is None else str(inv.get(key))
        if normalize(existing[fname][1]) != normalize(val):
            (volatile if key in VOLATILE else stable).append((fname, existing[fname][0], val))
    last = field_names["LastInventory"]
    due = False
    if last in existing:
        try:
            prev = datetime.datetime.strptime(normalize(existing[last][1]), "%Y-%m-%d %H:%M")
            due = (now - prev).total_seconds() / 86400.0 >= heartbeat_days
        except ValueError:
            due = True
    payload, changed = {}, []
    if stable or due:
        for fname, col, val in stable + volatile:
            payload[col] = val
            changed.append(fname)
        if last in existing:
            payload[existing[last][0]] = now.strftime("%Y-%m-%d %H:%M")
    pending = [] if (stable or due) else [v[0] for v in volatile]
    return payload, changed, pending, missing


def main(argv):
    dry = "--dry-run" in argv
    cfg_path = argv[argv.index("--config") + 1] if "--config" in argv else DEFAULT_CONFIG
    cfg = {}
    if os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as f:
            cfg = json.load(f)
    cfg["SnipeUrl"] = str(cfg.get("SnipeUrl") or "").rstrip("/")
    cfg["ApiToken"] = str(cfg.get("ApiToken") or "")
    names = dict(FIELD_NAMES)
    names.update(cfg.get("FieldNames") or {})
    try:
        log("Snipe-IT agent %s (Linux) starting%s" % (AGENT_VERSION, " (dry run)" if dry else ""))
        inv = collect(cfg)
        log("Collected: serial=%s, model=%s, RAM=%s GB, apps=%s" % (inv["Serial"], inv["HardwareModel"], inv["RamGB"], inv["SoftwareCount"]))
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(os.path.join(STATE_DIR, "inventory.json"), "w", encoding="utf-8") as f:
                json.dump({k: v for k, v in inv.items() if k != "Software"}, f, indent=2)
        except OSError:
            pass
        if dry:
            for k, v in inv.items():
                if k != "Software":
                    print("  %s: %s" % (k, v))
            print("Installed software (%s):\n%s\n" % (inv["SoftwareCount"], inv["Software"]))
        if not cfg["SnipeUrl"] or not cfg["ApiToken"]:
            if dry:
                log("Dry run without API settings: collection only.")
                return 0
            raise SnipeError("SnipeUrl and ApiToken must be set in " + cfg_path)
        asset = find_asset(cfg, inv["Serial"], cfg.get("AssetTag"))
        if not asset:
            log("No Snipe-IT asset found for serial '%s'%s. Add the serial to the asset in Snipe-IT."
                % (inv["Serial"], " or tag '%s'" % cfg["AssetTag"] if cfg.get("AssetTag") else ""), "WARN")
            return 2
        log("Matched asset id=%s tag=%s name=%s" % (asset.get("id"), asset.get("asset_tag"), asset.get("name") or ""))
        payload, changed, pending, missing = build_payload(asset, inv, names, float(cfg.get("HeartbeatDays") or 7),
                                                           datetime.datetime.now())
        if missing:
            log("These fields are not in this asset model's fieldset, so they were skipped: %s. Run Setup-SnipeITFields.ps1 for model '%s'."
                % (", ".join(missing), (asset.get("model") or {}).get("name", "?")), "WARN")
        if not payload:
            log("No significant changes and heartbeat not due. Nothing sent%s." % (" (pending: %s)" % ", ".join(pending) if pending else ""))
            return 0
        if dry:
            log("Dry run: would update asset %s fields: %s" % (asset.get("asset_tag"), ", ".join(changed + [names["LastInventory"]])))
            return 0
        api(cfg, "PATCH", "hardware/%s" % asset["id"], payload)
        log("Updated asset %s: %s" % (asset.get("asset_tag"), ", ".join(changed) if changed else "heartbeat only"))
        return 0
    except Exception as e:  # noqa: BLE001 - log everything, exit non-zero
        log(str(e), "ERROR")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
