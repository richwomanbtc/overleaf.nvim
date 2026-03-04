#!/usr/bin/env node
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const { normalizeCookie } = require('../../node/auth');
const chromeCookie = require('../../node/chrome-cookie');

const {
  decryptCookieValue,
  resolveChromeBaseDir,
  ensureSqlite3Available,
} = chromeCookie._internal;

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  [PASS] ${name}`);
  } catch (e) {
    failed++;
    console.log(`  [FAIL] ${name}`);
    console.log(`    ${e.message}`);
  }
}

function encryptV10(plaintext, keyV10) {
  const iv = Buffer.alloc(16, ' ');
  const cipher = crypto.createCipheriv('aes-128-cbc', keyV10, iv);
  const encrypted = Buffer.concat([cipher.update(Buffer.from(plaintext, 'utf-8')), cipher.final()]);
  return Buffer.concat([Buffer.from('v10', 'utf-8'), encrypted]);
}

function encryptV11(plaintext, keyV11) {
  const nonce = Buffer.from('00112233445566778899aabb', 'hex');
  const cipher = crypto.createCipheriv('aes-256-gcm', keyV11, nonce);
  const ciphertext = Buffer.concat([cipher.update(Buffer.from(plaintext, 'utf-8')), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([Buffer.from('v11', 'utf-8'), nonce, ciphertext, tag]);
}

function run() {
  console.log('\nAuth/Cookie Unit Tests:');

  test('normalizeCookie prefixes URL-encoded value without cookie name', () => {
    const normalized = normalizeCookie('  s%3Aabc123  ');
    assert.equal(normalized.cookie, 'overleaf_session2=s%3Aabc123');
    assert.equal(normalized.normalized, true);
  });

  test('normalizeCookie prefixes raw s: value without cookie name', () => {
    const normalized = normalizeCookie('s:abc123');
    assert.equal(normalized.cookie, 'overleaf_session2=s:abc123');
    assert.equal(normalized.normalized, true);
  });

  test('normalizeCookie keeps full cookie unchanged', () => {
    const normalized = normalizeCookie('overleaf_session2=s%3Aalready_named');
    assert.equal(normalized.cookie, 'overleaf_session2=s%3Aalready_named');
    assert.equal(normalized.normalized, false);
  });

  test('decryptCookieValue decrypts v10 cookie payloads', () => {
    const keyV10 = crypto.pbkdf2Sync('peanuts', 'saltysalt', 1, 16, 'sha1');
    const payload = encryptV10('s%3Av10_cookie', keyV10);
    const value = decryptCookieValue(payload, keyV10, null);
    assert.equal(value, 's%3Av10_cookie');
  });

  test('decryptCookieValue decrypts v11 cookie payloads with keyV11', () => {
    const keyV10 = crypto.pbkdf2Sync('peanuts', 'saltysalt', 1, 16, 'sha1');
    const keyV11 = Buffer.from('00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff', 'hex');
    const payload = encryptV11('s%3Av11_cookie', keyV11);
    const value = decryptCookieValue(payload, keyV10, keyV11);
    assert.equal(value, 's%3Av11_cookie');
  });

  test('resolveChromeBaseDir prefers chrome over chromium on Linux', () => {
    const homeDir = '/tmp/fake-home';
    const chromePath = `${homeDir}/.config/google-chrome`;
    const chromiumPath = `${homeDir}/.config/chromium`;
    const existsSync = (candidate) => candidate === chromePath || candidate === chromiumPath;
    const resolved = resolveChromeBaseDir({ platform: 'linux', homeDir, existsSync });
    assert.equal(resolved.browser, 'chrome');
    assert.equal(resolved.baseDir, chromePath);
  });

  test('resolveChromeBaseDir falls back to chromium on Linux', () => {
    const homeDir = '/tmp/fake-home';
    const chromiumPath = `${homeDir}/.config/chromium`;
    const existsSync = (candidate) => candidate === chromiumPath;
    const resolved = resolveChromeBaseDir({ platform: 'linux', homeDir, existsSync });
    assert.equal(resolved.browser, 'chromium');
    assert.equal(resolved.baseDir, chromiumPath);
  });

  test('ensureSqlite3Available throws linux install guidance when sqlite3 is missing', () => {
    assert.throws(
      () => ensureSqlite3Available({
        platform: 'linux',
        execSyncFn: () => { throw new Error('not found'); },
      }),
      (err) => (
        err
        && err.code === 'SQLITE3_MISSING'
        && String(err.message).includes('sudo apt install sqlite3')
      )
    );
  });

  console.log(`\nPassed: ${passed}, Failed: ${failed}`);
  if (failed > 0) {
    process.exit(1);
  }
}

run();
