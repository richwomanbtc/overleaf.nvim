'use strict';

const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execSync } = require('child_process');

/**
 * Extract Overleaf session cookie from Chrome/Chromium on macOS and Linux.
 */

const CHROME_MAC_BASE_DIR = 'Library/Application Support/Google/Chrome';
const CHROME_LINUX_PATHS = [
  { browser: 'chrome', path: '.config/google-chrome' },
  { browser: 'chromium', path: '.config/chromium' },
];
let secretToolMissingHintShown = false;

function isSecretToolMissingError(err) {
  // shell returns 127 when command is missing; ENOENT may appear in some environments
  return err && (err.status === 127 || err.code === 'ENOENT');
}

function trimTrailingNewlines(buffer) {
  if (!buffer || buffer.length === 0) return buffer;
  let end = buffer.length;
  while (end > 0 && (buffer[end - 1] === 0x0a || buffer[end - 1] === 0x0d)) {
    end--;
  }
  return buffer.slice(0, end);
}

function resolveChromeBaseDir(options = {}) {
  const platform = options.platform || os.platform();
  const homeDir = options.homeDir || os.homedir();
  const existsSync = options.existsSync || fs.existsSync;

  if (platform === 'darwin') {
    const baseDir = path.join(homeDir, CHROME_MAC_BASE_DIR);
    return { browser: 'chrome', baseDir };
  }

  if (platform === 'linux') {
    for (const candidate of CHROME_LINUX_PATHS) {
      const baseDir = path.join(homeDir, candidate.path);
      if (existsSync(baseDir)) {
        console.log(`Chrome base dir: ${baseDir} (browser: ${candidate.browser})`);
        return { browser: candidate.browser, baseDir };
      }
    }
    throw { code: 'NOT_FOUND', message: 'Chrome/Chromium data directory not found' };
  }

  throw {
    code: 'UNSUPPORTED',
    message: 'Chrome cookie extraction only supported on macOS and Linux',
  };
}

function trySecretToolLookup(args, asBuffer) {
  const options = {
    stdio: ['ignore', 'pipe', 'ignore'],
  };
  if (asBuffer) {
    options.encoding = 'buffer';
  } else {
    options.encoding = 'utf-8';
  }

  try {
    const result = execSync(`secret-tool lookup ${args}`, options);
    if (asBuffer) {
      const raw = trimTrailingNewlines(result);
      return raw && raw.length > 0 ? raw : null;
    }
    const trimmed = result.trim();
    return trimmed || null;
  } catch (e) {
    if (isSecretToolMissingError(e) && !secretToolMissingHintShown) {
      console.log('Keyring: secret-tool not found (libsecret-tools is not installed)');
      console.log('Keyring: install with: sudo apt install libsecret-tools');
      secretToolMissingHintShown = true;
    }
    return null;
  }
}

function normalizeV11Key(secretBuffer) {
  if (!secretBuffer || secretBuffer.length === 0) {
    return null;
  }

  const raw = trimTrailingNewlines(secretBuffer);
  if (raw.length === 32) {
    return Buffer.from(raw);
  }

  const asText = raw.toString('utf-8').trim();
  if (!asText) {
    return null;
  }

  if (/^[0-9a-fA-F]{64}$/.test(asText)) {
    return Buffer.from(asText, 'hex');
  }

  if (/^[A-Za-z0-9+/=]+$/.test(asText)) {
    try {
      const decoded = Buffer.from(asText, 'base64');
      if (decoded.length === 32) {
        return decoded;
      }
    } catch (e) {
      // ignore base64 decode errors
    }
  }

  return null;
}

function getLinuxPassword() {
  const password = trySecretToolLookup('application chrome', false);
  if (password) {
    console.log('Keyring: secret-tool succeeded');
    return password;
  }

  console.log('Keyring: falling back to hardcoded password');
  return 'peanuts';
}

function getLinuxV11Key() {
  const raw = trySecretToolLookup('xdg:schema chrome_libsecret_os_crypt_password_v2', true);
  if (!raw) {
    return null;
  }

  const key = normalizeV11Key(raw);
  if (key) {
    console.log('Keyring: secret-tool v11 key lookup succeeded');
    return key;
  }

  console.log('Keyring: secret-tool v11 key lookup returned unusable key');
  return null;
}

function getEncryptionKeys(options = {}) {
  const platform = options.platform || os.platform();

  if (platform === 'darwin') {
    const password = execSync(
      'security find-generic-password -w -s "Chrome Safe Storage" -a "Chrome"',
      { encoding: 'utf-8' }
    ).trim();

    return {
      keyV10: crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1'),
      keyV11: null,
    };
  }

  if (platform === 'linux') {
    const password = getLinuxPassword();
    return {
      keyV10: crypto.pbkdf2Sync(password, 'saltysalt', 1, 16, 'sha1'),
      keyV11: getLinuxV11Key(),
    };
  }

  throw {
    code: 'UNSUPPORTED',
    message: 'Chrome cookie extraction only supported on macOS and Linux',
  };
}

function ensureSqlite3Available(options = {}) {
  const run = options.execSyncFn || execSync;
  const platform = options.platform || os.platform();

  try {
    run('command -v sqlite3', {
      stdio: ['ignore', 'pipe', 'ignore'],
      encoding: 'utf-8',
    });
  } catch (e) {
    if (platform === 'linux') {
      console.log('sqlite3 check: sqlite3 not found in PATH');
      console.log('sqlite3 check: install with: sudo apt install sqlite3');
      throw {
        code: 'SQLITE3_MISSING',
        message: 'Chrome cookie extraction requires sqlite3. Install with: sudo apt install sqlite3',
      };
    }
    console.log('sqlite3 check: sqlite3 not found in PATH');
    throw {
      code: 'SQLITE3_MISSING',
      message: 'Chrome cookie extraction requires sqlite3',
    };
  }
}

/**
 * List available Chrome profiles.
 * Returns array of { dir: 'Default', name: 'Person 1' }
 */
function listProfiles() {
  const { baseDir } = resolveChromeBaseDir();
  if (!fs.existsSync(baseDir)) {
    throw { code: 'NOT_FOUND', message: 'Chrome data directory not found' };
  }

  const profiles = [];
  const entries = fs.readdirSync(baseDir, { withFileTypes: true });

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    // Chrome profiles are 'Default', 'Profile 1', 'Profile 2', etc.
    if (entry.name !== 'Default' && !entry.name.startsWith('Profile ')) continue;

    const cookiesDb = path.join(baseDir, entry.name, 'Cookies');
    if (!fs.existsSync(cookiesDb)) continue;

    let displayName = entry.name;
    let email = '';
    try {
      const prefsPath = path.join(baseDir, entry.name, 'Preferences');
      if (fs.existsSync(prefsPath)) {
        const prefs = JSON.parse(fs.readFileSync(prefsPath, 'utf-8'));
        // Try to get email from account_info
        if (prefs.account_info && Array.isArray(prefs.account_info) && prefs.account_info[0]) {
          email = prefs.account_info[0].email || '';
        }
        if (prefs.profile && prefs.profile.name) {
          displayName = email || prefs.profile.name;
        }
      }
    } catch (e) {
      // Use directory name as fallback
    }

    profiles.push({ dir: entry.name, name: displayName, email });
  }

  return profiles;
}

function decryptCookieValue(encryptedValue, keyV10, keyV11) {
  if (!encryptedValue || encryptedValue.length === 0) {
    return '';
  }

  const prefix = encryptedValue.slice(0, 3).toString('utf-8');

  if (prefix === 'v11' && keyV11) {
    try {
      const nonce = encryptedValue.slice(3, 15);
      const ciphertext = encryptedValue.slice(15, encryptedValue.length - 16);
      const tag = encryptedValue.slice(encryptedValue.length - 16);

      const decipher = crypto.createDecipheriv('aes-256-gcm', keyV11, nonce);
      decipher.setAuthTag(tag);
      const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      return decrypted.toString('utf-8');
    } catch (e) {
      console.log('Cookie decryption: v11 failed, trying v10 fallback');
    }
  }

  if (prefix === 'v10' || prefix === 'v11') {
    try {
      const encrypted = encryptedValue.slice(3);
      const iv = Buffer.alloc(16, ' ');

      const decipher = crypto.createDecipheriv('aes-128-cbc', keyV10, iv);
      let decrypted = decipher.update(encrypted);
      decrypted = Buffer.concat([decrypted, decipher.final()]);
      const raw = decrypted.toString('utf-8');

      // Chrome's CBC decryption may produce garbage in the first block
      // due to IV mismatch on newer versions. Overleaf session cookies
      // always contain 's%3A' (URL-encoded 's:' Express session prefix).
      const idx = raw.indexOf('s%3A');
      if (idx >= 0) {
        return raw.substring(idx);
      }

      return raw;
    } catch (e) {
      console.log('Cookie decryption: v10 failed');
    }
  }

  return encryptedValue.toString('utf-8');
}

/**
 * Extract Overleaf cookie from a specific Chrome profile.
 * @param {string} profileDir - Profile directory name (e.g. 'Default', 'Profile 1')
 */
async function getOverleafCookie(profileDir) {
  profileDir = profileDir || 'Default';
  const { baseDir } = resolveChromeBaseDir();
  const cookiesDb = path.join(baseDir, profileDir, 'Cookies');
  if (!fs.existsSync(cookiesDb)) {
    throw { code: 'NOT_FOUND', message: `Chrome Cookies database not found for profile: ${profileDir}` };
  }

  ensureSqlite3Available();

  const { keyV10, keyV11 } = getEncryptionKeys();

  const tmpDb = path.join(os.tmpdir(), 'overleaf_chrome_cookies_' + process.pid + '.db');
  fs.copyFileSync(cookiesDb, tmpDb);

  try {
    // Extract domain from OVERLEAF_URL for self-hosted instances
    let cookieDomain = 'overleaf.com';
    if (process.env.OVERLEAF_URL) {
      try {
        const parsedUrl = new URL(process.env.OVERLEAF_URL);
        cookieDomain = parsedUrl.hostname;
      } catch (e) { /* keep default */ }
    }
    const query = `SELECT name, hex(encrypted_value) FROM cookies WHERE host_key LIKE '%${cookieDomain}' AND name = 'overleaf_session2' ORDER BY expires_utc DESC LIMIT 1;`;
    const result = execSync(
      `sqlite3 "${tmpDb}" "${query}"`,
      { encoding: 'utf-8' }
    ).trim();

    if (!result) {
      throw { code: 'NO_COOKIE', message: 'No overleaf_session2 cookie found in Chrome. Log in to overleaf.com in Chrome first.' };
    }

    const [name, hexValue] = result.split('|');
    if (!hexValue) {
      throw { code: 'NO_COOKIE', message: 'Cookie value is empty' };
    }

    const encryptedValue = Buffer.from(hexValue, 'hex');
    const value = decryptCookieValue(encryptedValue, keyV10, keyV11);

    if (!value || !value.startsWith('s%3A')) {
      throw { code: 'DECRYPT_FAILED', message: 'Failed to decrypt cookie. Try setting cookie manually.' };
    }

    return `${name}=${value}`;
  } finally {
    try { fs.unlinkSync(tmpDb); } catch (e) { /* ignore */ }
  }
}

module.exports = {
  getOverleafCookie,
  listProfiles,
  _internal: {
    resolveChromeBaseDir,
    decryptCookieValue,
    normalizeV11Key,
    ensureSqlite3Available,
  },
};
