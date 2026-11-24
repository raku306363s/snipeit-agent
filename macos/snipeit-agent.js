// Snipe-IT inventory sensor for macOS.
//
// Collects hardware and software facts and writes them into the matching Snipe-IT
// asset's custom fields (the same fields the Windows agent fills). The asset is found
// by the Mac's hardware serial number, or by "AssetTag" in config.json as a fallback.
//
// Written in JavaScript for Automation (JXA), which every Mac has built in, so nothing
// needs to be installed. Run it with:
//
//   sudo osascript -l JavaScript snipeit-agent.js --dry-run     # collect and show, change nothing
//   sudo osascript -l JavaScript snipeit-agent.js               # collect and push
//
// Options:
//   --dry-run          show what would be sent; never writes to Snipe-IT
//   --config <path>    config.json (default: /Library/Application Support/SnipeITAgent/config.json)
//   --jitter <sec>     sleep a random 0..sec seconds first (used by the launchd job)
//
// The same file runs under Node.js for testing (node snipeit-agent.js ...), with the
// macOS commands replaced through SNIPEIT_AGENT_FIXTURES.

var AGENT_VERSION = '1.0.0';
var DEFAULT_DIR = '/Library/Application Support/SnipeITAgent';

var FIELD_NAMES = {
  HardwareModel: 'Hardware Model',
  Hostname: 'Hostname',
  CPU: 'CPU',
  RamGB: 'RAM (GB)',
  Storage: 'Storage',
  DiskFreeGB: 'Disk Free C: (GB)', // same field as Windows; holds free space of the startup disk
  Volumes: 'Volumes',
  OS: 'Operating System',
  OSBuild: 'OS Build',
  IPAddress: 'IP Address',
  MACAddress: 'MAC Address (Agent)',
  LastUser: 'Last Logged-in User',
  SoftwareCount: 'Software Count',
  Software: 'Installed Software',
  LastInventory: 'Last Inventory'
};
// Fast-changing values: sent only with a real change or with the heartbeat.
var VOLATILE = ['DiskFreeGB', 'Volumes', 'IPAddress', 'LastUser'];

// ---------------------------------------------------------------------------
// Platform layer: JXA on a Mac, Node.js in tests
// ---------------------------------------------------------------------------
var IS_JXA = (typeof ObjC !== 'undefined');
var platform;

if (IS_JXA) {
  ObjC.import('Foundation');
  ObjC.import('stdlib');
  var _app = Application.currentApplication();
  _app.includeStandardAdditions = true;
  platform = {
    sh: function (cmd) {
      try {
        return _app.doShellScript(cmd, { alteringLineEndings: false });
      } catch (e) {
        throw new Error('Command failed: ' + cmd.split(' ')[0] + ': ' + e.message);
      }
    },
    readFile: function (path) {
      var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
      if (s.isNil()) throw new Error('Cannot read ' + path);
      return ObjC.unwrap(s);
    },
    writeFile: function (path, text) {
      $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
    },
    exists: function (path) {
      return $.NSFileManager.defaultManager.fileExistsAtPath(path);
    },
    log: function (line) { console.log(line); },
    exit: function (code) { $.exit(code); }
  };
} else {
  var cp = require('child_process');
  var fs = require('fs');
  var fixtures = process.env.SNIPEIT_AGENT_FIXTURES ? JSON.parse(fs.readFileSync(process.env.SNIPEIT_AGENT_FIXTURES, 'utf8')) : {};
  platform = {
    sh: function (cmd) {
      for (var prefix in fixtures) {
        if (cmd.indexOf(prefix) === 0) return fixtures[prefix];
      }
      return cp.execSync(cmd, { encoding: 'utf8', shell: '/bin/sh', stdio: ['ignore', 'pipe', 'pipe'] }).replace(/\n$/, '');
    },
    readFile: function (path) { return fs.readFileSync(path, 'utf8'); },
    writeFile: function (path, text) { fs.writeFileSync(path, text, { mode: 384 }); },
    exists: function (path) { return fs.existsSync(path); },
    log: function (line) { console.log(line); },
    exit: function (code) { process.exit(code); }
  };
}

function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function trySh(cmd, fallback) {
  try { return platform.sh(cmd).trim(); } catch (e) { return fallback === undefined ? '' : fallback; }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
var LOG_PATH = null;
function pad(n) { return (n < 10 ? '0' : '') + n; }
function stamp(d) {
  d = d || new Date();
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}
function log(msg, level) {
  var d = new Date();
  var line = stamp(d) + ':' + pad(d.getSeconds()) + ' [' + (level || 'INFO') + '] ' + msg;
  platform.log(line);
  if (LOG_PATH) {
    try {
      platform.sh('f=' + q(LOG_PATH) + '; [ -f "$f" ] && [ $(wc -c < "$f") -gt 1048576 ] && mv -f "$f" "$f.old"; printf "%s\\n" ' + q(line) + ' >> "$f"');
    } catch (e) { }
  }
}

// ---------------------------------------------------------------------------
// Parsers (pure functions, unit-tested under Node)
// ---------------------------------------------------------------------------
function gb(bytes) { return Math.round(Number(bytes) / 1e9); } // Apple reports storage in decimal GB

function usableSerial(s) {
  if (!s) return false;
  return !/^(Not Available|Not Specified|To be filled by O\.E\.M\.|System Serial#|0+)$/i.test(s.trim());
}

function parseSerial(ioregOut) {
  var m = /"IOPlatformSerialNumber"\s*=\s*"([^"]*)"/.exec(ioregOut || '');
  return m && usableSerial(m[1]) ? m[1].trim() : null;
}

// system_profiler SPStorageDataType -json
function parseStorage(json) {
  var data = JSON.parse(json).SPStorageDataType || [];
  var root = null;
  for (var i = 0; i < data.length; i++) {
    if (data[i].mount_point === '/') root = data[i];
  }
  if (!root) {
    for (var j = 0; j < data.length; j++) {
      if (data[j].mount_point === '/System/Volumes/Data') root = data[j];
    }
  }
  var drives = {};
  var storage = [];
  var volumes = [];
  data.forEach(function (v) {
    var pd = v.physical_drive || {};
    if (pd.is_internal_disk === 'no') return; // external / USB
    var key = pd.device_name || v.bsd_name;
    if (pd.device_name && !drives[key]) {
      drives[key] = true;
      var media = (pd.medium_type || '').toUpperCase() === 'SSD' ? 'SSD' : (pd.medium_type ? String(pd.medium_type).toUpperCase() : 'Disk');
      if (/nvme|apple fabric/i.test(pd.protocol || '')) media = 'NVMe SSD';
      // APFS volumes share one container; its size is the drive capacity users recognise.
      storage.push(media + ' ' + gb(v.size_in_bytes) + ' GB (' + String(pd.device_name).replace(/\s+/g, ' ').trim() + ')');
    }
    if (v.mount_point && (v.mount_point === '/' || v.mount_point.indexOf('/Volumes/') === 0)) {
      volumes.push((v._name || v.mount_point) + ' ' + gb(v.free_space_in_bytes) + ' GB free of ' + gb(v.size_in_bytes) + ' GB');
    }
  });
  return {
    storage: storage.join('; '),
    volumes: volumes.join('; '),
    diskFree: root ? String(gb(root.free_space_in_bytes)) : ''
  };
}

// system_profiler SPApplicationsDataType -json
function parseApps(json, excludes) {
  var items = JSON.parse(json).SPApplicationsDataType || [];
  var seen = {};
  var apps = [];
  items.forEach(function (a) {
    var path = a.path || '';
    // Only real installs: /Applications (and subfolders) or ~/Applications, not apps bundled inside other apps.
    if (!/^\/Applications\//.test(path) && !/^\/Users\/[^/]+\/Applications\//.test(path)) return;
    if (/\.app\/.+/.test(path)) return;
    var name = String(a._name || '').replace(/\s+/g, ' ').trim();
    if (!name) return;
    for (var i = 0; i < excludes.length; i++) {
      if (new RegExp(excludes[i]).test(name)) return;
    }
    var version = String(a.version || '').trim();
    var id = (name + '|' + version).toLowerCase();
    if (seen[id]) return;
    seen[id] = true;
    apps.push({ name: name, version: version });
  });
  apps.sort(function (x, y) {
    var a = x.name.toLowerCase(), b = y.name.toLowerCase();
    return a < b ? -1 : a > b ? 1 : (x.version < y.version ? -1 : x.version > y.version ? 1 : 0);
  });
  return apps;
}

function formatApps(apps, maxChars) {
  var text = apps.map(function (a) { return a.version ? a.name + ' (' + a.version + ')' : a.name; }).join('\n');
  if (text.length > maxChars) text = text.substring(0, maxChars) + '\n... (truncated)';
  return text;
}

// system_profiler SPHardwareDataType -json -> "Apple MacBook Pro M1 Pro", "Apple Mac mini M4",
// or for Intel Macs "Apple MacBook Pro (MacBookPro16,1)".
function parseHardwareModel(json) {
  var hw = (JSON.parse(json).SPHardwareDataType || [])[0] || {};
  var name = String(hw.machine_name || 'Mac').trim();
  var chip = String(hw.chip_type || '').replace(/^Apple\s+/, '').trim();
  if (chip) return 'Apple ' + name + ' ' + chip;
  return 'Apple ' + name + (hw.machine_model ? ' (' + hw.machine_model + ')' : '');
}

function htmlDecode(s) {
  return String(s)
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'").replace(/&#x27;/g, "'").replace(/&amp;/g, '&');
}
function normalize(v) {
  if (v === null || v === undefined) return '';
  return htmlDecode(v).replace(/\r\n/g, '\n').trim();
}

function parseStamp(s) {
  var m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$/.exec(normalize(s));
  if (!m) return null;
  return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
}

// Decide what to send. Returns { payload, changed, pendingVolatile, missing }.
function buildPayload(asset, inv, fieldNames, heartbeatDays, now) {
  var existing = {};
  var cf = asset.custom_fields || {};
  Object.keys(cf).forEach(function (name) {
    existing[name] = { column: cf[name].field, value: cf[name].value };
  });

  var stable = [], volatile = [], missing = [];
  Object.keys(fieldNames).forEach(function (key) {
    if (key === 'LastInventory') return;
    var fname = fieldNames[key];
    if (!existing[fname]) { missing.push(fname); return; }
    var val = inv[key] === undefined || inv[key] === null ? '' : String(inv[key]);
    if (normalize(existing[fname].value) !== normalize(val)) {
      (VOLATILE.indexOf(key) >= 0 ? volatile : stable).push({ name: fname, column: existing[fname].column, value: val });
    }
  });

  var lastName = fieldNames.LastInventory;
  var heartbeatDue = false;
  if (existing[lastName]) {
    var prev = parseStamp(existing[lastName].value);
    heartbeatDue = !prev || ((now - prev) / 86400000) >= heartbeatDays;
  }

  var payload = {}, changed = [];
  if (stable.length > 0 || heartbeatDue) {
    stable.concat(volatile).forEach(function (c) { payload[c.column] = c.value; changed.push(c.name); });
    if (existing[lastName]) payload[existing[lastName].column] = stamp(now);
  }
  return {
    payload: payload,
    changed: changed,
    pendingVolatile: (stable.length > 0 || heartbeatDue) ? [] : volatile.map(function (c) { return c.name; }),
    missing: missing
  };
}

// ---------------------------------------------------------------------------
// Collection (macOS commands)
// ---------------------------------------------------------------------------
function collect(cfg) {
  var inv = {};
  inv.Serial = parseSerial(trySh('/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice'));
  inv.Hostname = trySh('/usr/sbin/scutil --get ComputerName') || trySh('/bin/hostname -s');
  inv.Model = trySh('/usr/sbin/sysctl -n hw.model');
  try {
    inv.HardwareModel = parseHardwareModel(platform.sh('/usr/sbin/system_profiler -json SPHardwareDataType'));
  } catch (e) {
    inv.HardwareModel = inv.Model ? 'Apple ' + inv.Model : '';
  }
  inv.CPU = trySh('/usr/sbin/sysctl -n machdep.cpu.brand_string').replace(/\s+/g, ' ');
  var mem = trySh('/usr/sbin/sysctl -n hw.memsize');
  inv.RamGB = mem ? String(Math.round(Number(mem) / 1073741824)) : '';

  try {
    var st = parseStorage(platform.sh('/usr/sbin/system_profiler -json SPStorageDataType'));
    inv.Storage = st.storage; inv.Volumes = st.volumes; inv.DiskFreeGB = st.diskFree;
  } catch (e) {
    log('Storage collection failed: ' + e.message, 'WARN');
    inv.Storage = ''; inv.Volumes = ''; inv.DiskFreeGB = '';
  }

  inv.OS = (trySh('/usr/bin/sw_vers -productName') + ' ' + trySh('/usr/bin/sw_vers -productVersion')).trim();
  inv.OSBuild = trySh('/usr/bin/sw_vers -buildVersion');

  var iface = '';
  var route = trySh('/sbin/route -n get default');
  var m = /interface:\s*(\S+)/.exec(route);
  if (m) iface = m[1];
  inv.IPAddress = iface ? trySh('/usr/sbin/ipconfig getifaddr ' + q(iface)) : '';
  var ether = iface ? /ether\s+([0-9a-f:]{17})/i.exec(trySh('/sbin/ifconfig ' + q(iface))) : null;
  inv.MACAddress = ether ? ether[1].toUpperCase() : '';

  var user = trySh('/usr/bin/stat -f %Su /dev/console');
  if (!user || user === 'root' || user === '_mbsetupuser') {
    user = trySh('/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow lastUserName');
  }
  inv.LastUser = user;

  var apps = [];
  try {
    apps = parseApps(platform.sh('/usr/sbin/system_profiler -json SPApplicationsDataType'), cfg.SoftwareExclude);
  } catch (e) {
    log('Software collection failed: ' + e.message, 'WARN');
  }
  inv.SoftwareCount = String(apps.length);
  inv.Software = formatApps(apps, cfg.MaxSoftwareChars);
  return inv;
}

// ---------------------------------------------------------------------------
// Snipe-IT API (curl; the token goes through a root-only curl config file, never argv)
// ---------------------------------------------------------------------------
function makeApi(cfg, workDir) {
  var curlCfg = workDir + '/.curl-auth';
  var bodyFile = workDir + '/.request-body.json';
  platform.writeFile(curlCfg, 'header = "Authorization: Bearer ' + cfg.ApiToken + '"\nheader = "Accept: application/json"\n');
  trySh('/bin/chmod 600 ' + q(curlCfg));

  function call(method, path, body) {
    var url = cfg.SnipeUrl + '/api/v1/' + path.replace(/^\//, '');
    var cmd = '/usr/bin/curl -sS --max-time 60 -K ' + q(curlCfg) + ' -X ' + method + ' -w "\\n%{http_code}"';
    if (body !== undefined) {
      platform.writeFile(bodyFile, JSON.stringify(body));
      cmd += ' -H "Content-Type: application/json; charset=utf-8" --data-binary @' + q(bodyFile);
    }
    cmd += ' ' + q(url);
    var out = platform.sh(cmd);
    var nl = out.lastIndexOf('\n');
    var status = parseInt(out.substring(nl + 1), 10);
    var text = out.substring(0, nl);
    var result;
    try { result = JSON.parse(text); } catch (e) {
      throw new Error(method + ' ' + path + ' returned HTTP ' + status + ' and no JSON (check SnipeUrl): ' + text.substring(0, 200));
    }
    if (status === 401) throw new Error('401 Unauthorized: the API token is wrong or revoked');
    if (status === 403) throw new Error('403 Forbidden: the agent user needs Assets View and Edit');
    if (result && result.status === 'error') {
      var err = new Error('Snipe-IT error on ' + method + ' ' + path + ': ' + JSON.stringify(result.messages));
      err.status = status; err.snipeMessage = JSON.stringify(result.messages);
      throw err;
    }
    if (status >= 400) {
      var e2 = new Error(method + ' ' + path + ' returned HTTP ' + status);
      e2.status = status;
      throw e2;
    }
    return result;
  }

  function cleanup() {
    trySh('/bin/rm -f ' + q(curlCfg) + ' ' + q(bodyFile));
  }

  function findAsset(serial, assetTag) {
    if (serial) {
      try {
        var r = call('GET', 'hardware/byserial/' + encodeURIComponent(serial));
        var rows = r.rows || [];
        if (rows.length === 1) return rows[0];
        if (rows.length > 1) {
          throw new Error("Serial '" + serial + "' matches " + rows.length + ' assets (tags: ' +
            rows.map(function (x) { return x.asset_tag; }).join(', ') + '). Fix the duplicate serials, then rerun.');
        }
      } catch (e) {
        if (/matches \d+ assets/.test(e.message)) throw e;
        if (!(e.status === 404 || /not found|does not exist/i.test(e.message))) throw e;
      }
    }
    if (assetTag) {
      var s = call('GET', 'hardware?limit=50&search=' + encodeURIComponent(assetTag));
      var match = (s.rows || []).filter(function (x) { return x.asset_tag === assetTag; });
      if (match.length === 1) return match[0];
    }
    return null;
  }

  return { call: call, findAsset: findAsset, cleanup: cleanup };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main(argv) {
  var dryRun = false, configPath = DEFAULT_DIR + '/config.json', jitter = 0;
  for (var i = 0; i < argv.length; i++) {
    if (argv[i] === '--dry-run') dryRun = true;
    else if (argv[i] === '--config') configPath = argv[++i];
    else if (argv[i] === '--jitter') jitter = parseInt(argv[++i], 10) || 0;
  }
  var workDir = configPath.replace(/\/[^/]*$/, '') || '.';
  LOG_PATH = workDir + '/agent.log';

  var cfg = {};
  if (platform.exists(configPath)) cfg = JSON.parse(platform.readFile(configPath));
  cfg.SnipeUrl = String(cfg.SnipeUrl || '').replace(/\/+$/, '');
  cfg.ApiToken = String(cfg.ApiToken || '');
  cfg.HeartbeatDays = Number(cfg.HeartbeatDays || 7);
  cfg.MaxSoftwareChars = Number(cfg.MaxSoftwareChars || 60000);
  cfg.SoftwareExclude = cfg.SoftwareExclude || [];
  var fieldNames = {};
  Object.keys(FIELD_NAMES).forEach(function (k) { fieldNames[k] = FIELD_NAMES[k]; });
  if (cfg.FieldNames) Object.keys(cfg.FieldNames).forEach(function (k) { fieldNames[k] = cfg.FieldNames[k]; });

  if (jitter > 0) trySh('/bin/sleep ' + Math.floor(Math.random() * jitter));

  var api = null;
  try {
    log('Snipe-IT agent ' + AGENT_VERSION + ' (macOS) starting' + (dryRun ? ' (dry run)' : ''));
    var inv = collect(cfg);
    log('Collected: serial=' + inv.Serial + ', model=' + inv.HardwareModel + ', RAM=' + inv.RamGB + ' GB, apps=' + inv.SoftwareCount);
    try {
      var copy = {};
      Object.keys(inv).forEach(function (k) { if (k !== 'Software') copy[k] = inv[k]; });
      platform.writeFile(workDir + '/inventory.json', JSON.stringify(copy, null, 2));
    } catch (e) { }

    if (dryRun) {
      Object.keys(inv).forEach(function (k) { if (k !== 'Software') platform.log('  ' + k + ': ' + inv[k]); });
      platform.log('Installed software (' + inv.SoftwareCount + '):\n' + inv.Software + '\n');
    }
    if (!cfg.SnipeUrl || !cfg.ApiToken) {
      if (dryRun) { log('Dry run without API settings: collection only.'); return 0; }
      throw new Error('SnipeUrl and ApiToken must be set in ' + configPath);
    }

    api = makeApi(cfg, workDir);
    var asset = api.findAsset(inv.Serial, cfg.AssetTag);
    if (!asset) {
      log("No Snipe-IT asset found for serial '" + inv.Serial + "'" + (cfg.AssetTag ? " or tag '" + cfg.AssetTag + "'" : '') +
        '. Add the serial to the asset in Snipe-IT.', 'WARN');
      return 2;
    }
    log('Matched asset id=' + asset.id + ' tag=' + asset.asset_tag + ' name=' + (asset.name || ''));

    var plan = buildPayload(asset, inv, fieldNames, cfg.HeartbeatDays, new Date());
    if (plan.missing.length) {
      log("These fields are not in this asset model's fieldset, so they were skipped: " + plan.missing.join(', ') +
        ". Run Setup-SnipeITFields.ps1 for model '" + (asset.model ? asset.model.name : '?') + "'.", 'WARN');
    }
    var keys = Object.keys(plan.payload);
    if (keys.length === 0) {
      log('No significant changes and heartbeat not due. Nothing sent' +
        (plan.pendingVolatile.length ? ' (pending: ' + plan.pendingVolatile.join(', ') + ')' : '') + '.');
      return 0;
    }
    if (dryRun) {
      log('Dry run: would update asset ' + asset.asset_tag + ' fields: ' + plan.changed.concat([fieldNames.LastInventory]).join(', '));
      return 0;
    }
    api.call('PATCH', 'hardware/' + asset.id, plan.payload);
    log('Updated asset ' + asset.asset_tag + ': ' + (plan.changed.length ? plan.changed.join(', ') : 'heartbeat only'));
    return 0;
  } catch (e) {
    log(e.message, 'ERROR');
    return 1;
  } finally {
    if (api) api.cleanup();
  }
}

// Entry points
function run(argv) { // called by osascript
  var code = main(argv || []);
  if (code) platform.exit(code);
}
if (!IS_JXA && typeof module !== 'undefined') {
  module.exports = { parseSerial: parseSerial, parseHardwareModel: parseHardwareModel, parseStorage: parseStorage, parseApps: parseApps, formatApps: formatApps,
    buildPayload: buildPayload, normalize: normalize, main: main };
  if (require.main === module) process.exit(main(process.argv.slice(2)));
}
