'use strict';

const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execSync } = require('child_process');

/**
 * Extract Overleaf session cookie from Chrome on macOS.
 * Chrome encrypts cookies using AES-128-CBC with a key derived from
 * the Keychain password via PBKDF2.
 */

const CHROME_BASE_DIR = path.join(
  os.homedir(),
  'Library/Application Support/Google/Chrome'
);

/**
 * List available Chrome profiles.
 * Returns array of { dir: 'Default', name: 'Person 1' }
 */
function listProfiles() {
  if (os.platform() !== 'darwin') {
    throw { code: 'UNSUPPORTED', message: 'Chrome cookie extraction only supported on macOS' };
  }

  if (!fs.existsSync(CHROME_BASE_DIR)) {
    throw { code: 'NOT_FOUND', message: 'Chrome data directory not found' };
  }

  const profiles = [];
  const entries = fs.readdirSync(CHROME_BASE_DIR, { withFileTypes: true });

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    // Chrome profiles are 'Default', 'Profile 1', 'Profile 2', etc.
    if (entry.name !== 'Default' && !entry.name.startsWith('Profile ')) continue;

    const cookiesDb = path.join(CHROME_BASE_DIR, entry.name, 'Cookies');
    if (!fs.existsSync(cookiesDb)) continue;

    let displayName = entry.name;
    let email = '';
    try {
      const prefsPath = path.join(CHROME_BASE_DIR, entry.name, 'Preferences');
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

function getEncryptionKey() {
  const password = execSync(
    'security find-generic-password -w -s "Chrome Safe Storage" -a "Chrome"',
    { encoding: 'utf-8' }
  ).trim();

  return crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
}

function decryptCookieValue(encryptedValue, key) {
  if (!encryptedValue || encryptedValue.length === 0) {
    return '';
  }

  const prefix = encryptedValue.slice(0, 3).toString('utf-8');
  if (prefix !== 'v10') {
    return encryptedValue.toString('utf-8');
  }

  const encrypted = encryptedValue.slice(3);
  const iv = Buffer.alloc(16, ' ');

  const decipher = crypto.createDecipheriv('aes-128-cbc', key, iv);
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
}

/**
 * Extract Overleaf cookie from a specific Chrome profile.
 * @param {string} profileDir - Profile directory name (e.g. 'Default', 'Profile 1')
 */
async function getOverleafCookie(profileDir) {
  profileDir = profileDir || 'Default';

  if (os.platform() !== 'darwin') {
    throw { code: 'UNSUPPORTED', message: 'Chrome cookie extraction only supported on macOS' };
  }

  const cookiesDb = path.join(CHROME_BASE_DIR, profileDir, 'Cookies');
  if (!fs.existsSync(cookiesDb)) {
    throw { code: 'NOT_FOUND', message: `Chrome Cookies database not found for profile: ${profileDir}` };
  }

  const key = getEncryptionKey();

  const tmpDb = path.join(os.tmpdir(), 'overleaf_chrome_cookies_' + process.pid + '.db');
  fs.copyFileSync(cookiesDb, tmpDb);

  try {
    const query = `SELECT name, hex(encrypted_value) FROM cookies WHERE host_key LIKE '%overleaf.com' AND name = 'overleaf_session2' ORDER BY expires_utc DESC LIMIT 1;`;
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
    const value = decryptCookieValue(encryptedValue, key);

    if (!value || !value.startsWith('s%3A')) {
      throw { code: 'DECRYPT_FAILED', message: 'Failed to decrypt cookie. Try setting cookie manually.' };
    }

    return `${name}=${value}`;
  } finally {
    try { fs.unlinkSync(tmpDb); } catch (e) { /* ignore */ }
  }
}

module.exports = { getOverleafCookie, listProfiles };
