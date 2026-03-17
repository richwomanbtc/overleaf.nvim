# Spec: Linux Chrome Cookie Extraction & Auth Diagnostics

## Status

Draft

## Problem

1. **Chrome cookie auto-extraction is macOS-only.** Linux users must manually copy
   cookies from DevTools, which is error-prone and undiscoverable.
2. **Manual cookie format is a pitfall.** DevTools shows the cookie *value* (`s%3A...`)
   separately from its *name* (`overleaf_session2`). Users naturally copy just the
   value, but the code expects `overleaf_session2=s%3A...`. The resulting auth failure
   message ("Cookie expired or invalid") gives no hint about the actual cause.
3. **No diagnostic output.** The auth flow logs almost nothing: no cookie source, no
   format validation, no HTTP response details. Debugging requires reading source code.

## Goals

- Support automatic Chrome/Chromium cookie extraction on Linux
- Auto-fix the common manual cookie format mistake with a warning
- Add debug-level logging throughout the auth flow

## Non-Goals

- Firefox or non-Chromium browser support
- KDE KWallet keyring support (can be added later)
- Windows support

---

## Design

### 1. Linux Chrome Cookie Extraction

#### 1.1 Browser Detection

Check directories in order, use the first one that exists:

| Browser  | Path                        |
|----------|-----------------------------|
| Chrome   | `~/.config/google-chrome`   |
| Chromium | `~/.config/chromium`        |

If both exist, prefer Chrome. The selected browser name is logged at debug level.

#### 1.2 Profile Listing

Reuse the existing `listProfiles()` logic. On Linux the profile directory structure
is identical to macOS (`Default/`, `Profile 1/`, etc.). The `Preferences` JSON file
has the same schema for `account_info` and `profile.name`.

Platform branch in `listProfiles()`:

```
if (darwin)  -> CHROME_BASE_DIR = ~/Library/Application Support/Google/Chrome
if (linux)   -> CHROME_BASE_DIR = ~/.config/google-chrome or ~/.config/chromium
else         -> throw UNSUPPORTED
```

#### 1.3 Encryption Key Retrieval

Chrome on Linux retrieves its encryption password from the system keyring, falling
back to a hardcoded password when no keyring is available.

**Strategy: GNOME Keyring first, then hardcoded fallback.**

1. Try `secret-tool lookup application chrome`:
   - If `secret-tool` is not installed or returns empty, fall through.
   - If it returns a password, use it.
2. Fall back to the hardcoded password `peanuts` (Chrome's built-in default when
   no keyring is detected).

Log at debug level which method succeeded.

#### 1.4 Key Derivation

Linux uses different PBKDF2 parameters than macOS:

| Parameter  | macOS | Linux  |
|------------|-------|--------|
| Password   | Keychain (`security` CLI) | Keyring / `peanuts` |
| Salt       | `saltysalt` | `saltysalt` |
| Iterations | 1003  | 1      |
| Key length | 16 bytes | 16 bytes |
| Hash       | SHA-1 | SHA-1  |

Platform branch in `getEncryptionKey()`:

```javascript
if (darwin) {
  password = execSync('security find-generic-password -w -s "Chrome Safe Storage" -a "Chrome"');
  iterations = 1003;
} else {
  password = trySecretTool() || 'peanuts';
  iterations = 1;
}
key = pbkdf2Sync(password, 'saltysalt', iterations, 16, 'sha1');
```

#### 1.5 Cookie Decryption

Support both `v10` and `v11` encrypted cookie prefixes:

**v10 (AES-128-CBC)** -- existing logic, works on both platforms:
- Strip 3-byte `v10` prefix
- IV: 16 bytes of `0x20` (space)
- Decrypt with AES-128-CBC using the derived key

**v11 (AES-256-GCM)** -- new, increasingly common on newer Linux Chrome:
- Strip 3-byte `v11` prefix
- Next 12 bytes: nonce
- Last 16 bytes: authentication tag
- Middle bytes: ciphertext
- Key: For v11, Chrome uses a different key derivation -- the raw 256-bit key is
  stored directly in the keyring under `Chrome Safe Storage` (or equivalent).
  On Linux with `secret-tool`, look up `xdg:schema chrome_libsecret_os_crypt_password_v2`
  first for the v11 key. If not found, fall back to v10 decryption.
- Decrypt with AES-256-GCM

```javascript
function decryptCookieValue(encryptedValue, key, keyV2) {
  const prefix = encryptedValue.slice(0, 3).toString('utf-8');

  if (prefix === 'v11' && keyV2) {
    const nonce = encryptedValue.slice(3, 3 + 12);
    const tag = encryptedValue.slice(encryptedValue.length - 16);
    const ciphertext = encryptedValue.slice(3 + 12, encryptedValue.length - 16);
    const decipher = crypto.createDecipheriv('aes-256-gcm', keyV2, nonce);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf-8');
  }

  if (prefix === 'v10') {
    // existing AES-128-CBC logic (unchanged)
  }

  return encryptedValue.toString('utf-8');
}
```

#### 1.6 SQLite Dependency

The existing code uses the `sqlite3` CLI (`execSync('sqlite3 ...')`). On Linux this
requires the `sqlite3` package. This is pre-installed on most Ubuntu/Debian systems.
If `sqlite3` is not found, throw a clear error:

```
Chrome cookie extraction requires sqlite3. Install with: sudo apt install sqlite3
```

---

### 2. Cookie Format Auto-Fix

In `auth.js`, before making the HTTP request, validate and normalize the cookie:

```javascript
function normalizeCookie(cookie) {
  cookie = cookie.trim();
  // User pasted just the value without the cookie name
  if (cookie.startsWith('s%3A') || cookie.startsWith('s:')) {
    console.log('[overleaf] Cookie value missing "overleaf_session2=" prefix, auto-prepending');
    return 'overleaf_session2=' + cookie;
  }
  return cookie;
}
```

This runs for all cookie sources (Chrome extraction, .env, config). The Chrome path
already returns the correct format, so normalization is a no-op there.

The `console.log` message is forwarded to Neovim as a warning-level notification
so the user knows their `.env` format is being corrected.

---

### 3. Auth Diagnostics

Add debug-level logging at these points (only visible when `log_level = 'debug'`):

| Location | Log message |
|----------|-------------|
| `_get_cookie()` | `Cookie source: chrome / env-file / config` |
| `_get_cookie_fallback()` | `.env path checked: {path} (found: yes/no)` |
| `config.load_cookie()` | `Loaded cookie from {path}: overleaf_session2=s%3A...{first 8 chars}...` (truncated) |
| `normalizeCookie()` | `Cookie format: normalized (was missing name prefix)` or `Cookie format: ok` |
| `fetchProjectPage()` | `Auth request: GET {url} -> {status}` |
| `fetchProjectPage()` | On 302: `Redirect location: {headers.location}` |
| `getEncryptionKey()` (Linux) | `Keyring: secret-tool succeeded` or `Keyring: falling back to hardcoded password` |
| `listProfiles()` (Linux) | `Chrome base dir: {path} (browser: chrome/chromium)` |

On auth failure, upgrade the error message:

```
Current:  "Cookie expired or invalid (redirected to login)"
Proposed: "Cookie rejected by Overleaf (HTTP 302 -> login page).
           Cookie source: {source}. Run with log_level='debug' for details.
           If using .env, ensure format is: OVERLEAF_COOKIE=overleaf_session2=s%3A..."
```

---

## File Changes

| File | Change |
|------|--------|
| `node/chrome-cookie.js` | Add Linux platform branches for `listProfiles()`, `getEncryptionKey()`, `decryptCookieValue()`, `getOverleafCookie()`. Add v11 decryption. Add sqlite3 availability check. |
| `node/auth.js` | Add `normalizeCookie()`. Enrich error messages. Add debug logging. |
| `lua/overleaf/init.lua` | Add debug logging in `_get_cookie()` and `_get_cookie_fallback()`. |
| `lua/overleaf/config.lua` | Add debug logging in `load_cookie()`. |
| `README.md` | Update Authentication section: document Linux Chrome support, clarify .env cookie format. |

## Testing

- Manual test on Ubuntu 24.04 with Chrome and Chromium
- Test with `secret-tool` available and unavailable
- Test with v10 and v11 encrypted cookies
- Test `.env` with `s%3A...` (should auto-fix) and `overleaf_session2=s%3A...` (should pass through)
- Test on macOS to verify no regression
