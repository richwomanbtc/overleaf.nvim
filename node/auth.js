'use strict';

const https = require('https');
const http = require('http');

const BASE_URL = process.env.OVERLEAF_URL || 'https://www.overleaf.com';

function normalizeCookie(cookie) {
  const trimmed = (cookie || '').trim();

  // Common user mistake: paste only the raw value from DevTools.
  if (trimmed.startsWith('s%3A') || trimmed.startsWith('s:')) {
    console.log('Cookie format: normalized (was missing name prefix)');
    return {
      cookie: 'overleaf_session2=' + trimmed,
      normalized: true,
    };
  }

  console.log('Cookie format: ok');
  return {
    cookie: trimmed,
    normalized: false,
  };
}

function httpGet(url, cookie) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const httpModule = parsed.protocol === 'http:' ? http : https;
    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'http:' ? 80 : 443),
      path: parsed.pathname + parsed.search,
      method: 'GET',
      headers: {
        'Cookie': cookie,
        'User-Agent': 'overleaf-neovim/0.1',
        'Accept': 'text/html,application/xhtml+xml',
      },
    };

    const req = httpModule.request(options, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        resolve({ status: res.statusCode, headers: res.headers, body });
      });
    });

    req.on('error', reject);
    req.setTimeout(15000, () => {
      req.destroy(new Error('Request timeout'));
    });
    req.end();
  });
}

async function fetchProjectPage(cookie, options = {}) {
  const cookieSource = options.cookieSource || 'unknown';
  const normalized = normalizeCookie(cookie);
  const normalizedCookie = normalized.cookie;

  const projectUrl = BASE_URL + '/project';
  const res = await httpGet(projectUrl, normalizedCookie);
  console.log(`Auth request: GET ${projectUrl} -> ${res.status}`);

  if (res.status === 302) {
    if (res.headers && res.headers.location) {
      console.log(`Redirect location: ${res.headers.location}`);
    }
    throw {
      code: 'AUTH_FAILED',
      message: `Cookie rejected by Overleaf (HTTP 302 -> login page). Cookie source: ${cookieSource}. Run with log_level='debug' for details. If using .env, ensure format is: OVERLEAF_COOKIE=overleaf_session2=s%3A...`,
    };
  }

  if (res.status !== 200) {
    throw { code: 'AUTH_FAILED', message: `Unexpected status: ${res.status}` };
  }

  const cheerio = require('cheerio');
  const $ = cheerio.load(res.body);

  const csrfToken = $('meta[name="ol-csrfToken"]').attr('content');
  const userId = $('meta[name="ol-user_id"]').attr('content');
  const userEmail = $('meta[name="ol-usersEmail"]').attr('content') || '';

  if (!csrfToken || !userId) {
    throw { code: 'PARSE_ERROR', message: 'Failed to extract CSRF token or user ID from /project page' };
  }

  // Extract project list from prefetched blob
  let projects = [];
  const prefetchedBlob = $('meta[name="ol-prefetchedProjectsBlob"]').attr('content');
  if (prefetchedBlob) {
    try {
      const parsed = JSON.parse(prefetchedBlob);
      projects = (parsed.projects || parsed || []).map((p) => ({
        id: p._id || p.id,
        name: p.name,
        lastUpdated: p.lastUpdated,
        accessLevel: p.accessLevel || p.privileges || 'unknown',
        owner: p.owner_ref || p.owner || null,
      }));
    } catch (e) {
      console.log('Failed to parse prefetchedProjectsBlob:', e.message);
    }
  }

  // Fallback: try ol-projects meta tag
  if (projects.length === 0) {
    const projectsMeta = $('meta[name="ol-projects"]').attr('content');
    if (projectsMeta) {
      try {
        const parsed = JSON.parse(projectsMeta);
        projects = parsed.map((p) => ({
          id: p._id || p.id,
          name: p.name,
          lastUpdated: p.lastUpdated,
          accessLevel: p.accessLevel || 'unknown',
          owner: p.owner_ref || null,
        }));
      } catch (e) {
        console.log('Failed to parse ol-projects:', e.message);
      }
    }
  }

  return {
    csrfToken,
    userId,
    userEmail,
    projects,
    normalizedCookie,
    cookieWasNormalized: normalized.normalized,
    cookieSource,
  };
}

/**
 * Fetch /socket.io/socket.io.js to get GCLB (load balancer) cookie.
 * This is required for session stickiness during Socket.IO handshake.
 * Returns the updated cookie string with GCLB appended.
 */
async function updateCookies(cookie) {
  const res = await httpGet(BASE_URL + '/socket.io/socket.io.js', cookie);

  // Extract set-cookie header
  const setCookie = res.headers['set-cookie'];
  if (setCookie) {
    const cookies = Array.isArray(setCookie) ? setCookie : [setCookie];
    for (const c of cookies) {
      const name_value = c.split(';')[0].trim();
      if (name_value) {
        cookie = cookie + '; ' + name_value;
      }
    }
  }

  return cookie;
}

function httpPost(url, cookie, csrfToken, body) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const httpModule = parsed.protocol === 'http:' ? http : https;
    const data = JSON.stringify(body);
    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'http:' ? 80 : 443),
      path: parsed.pathname + parsed.search,
      method: 'POST',
      headers: {
        'Cookie': cookie,
        'X-Csrf-Token': csrfToken,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data),
        'User-Agent': 'overleaf-neovim/0.1',
        'Accept': 'application/json',
      },
    };

    const req = httpModule.request(options, (res) => {
      let responseBody = '';
      res.on('data', (chunk) => { responseBody += chunk; });
      res.on('end', () => {
        resolve({ status: res.statusCode, headers: res.headers, body: responseBody });
      });
    });

    req.on('error', reject);
    req.setTimeout(30000, () => {
      req.destroy(new Error('Request timeout'));
    });
    req.write(data);
    req.end();
  });
}

function httpDelete(url, cookie, csrfToken) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const httpModule = parsed.protocol === 'http:' ? http : https;
    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'http:' ? 80 : 443),
      path: parsed.pathname + parsed.search,
      method: 'DELETE',
      headers: {
        'Cookie': cookie,
        'X-Csrf-Token': csrfToken,
        'User-Agent': 'overleaf-neovim/0.1',
        'Accept': 'application/json',
      },
    };

    const req = httpModule.request(options, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        resolve({ status: res.statusCode, headers: res.headers, body });
      });
    });

    req.on('error', reject);
    req.setTimeout(15000, () => {
      req.destroy(new Error('Request timeout'));
    });
    req.end();
  });
}

function httpPostMultipart(url, cookie, csrfToken, filePath, fileName) {
  return new Promise((resolve, reject) => {
    const fs = require('fs');
    const path = require('path');
    const parsed = new URL(url);
    const httpModule = parsed.protocol === 'http:' ? http : https;
    const boundary = '----OverleafNeovim' + Date.now().toString(36);
    fileName = fileName || path.basename(filePath);

    const fileData = fs.readFileSync(filePath);

    // Build multipart body
    const parts = [];
    parts.push(`--${boundary}\r\n`);
    parts.push(`Content-Disposition: form-data; name="qqfile"; filename="${fileName}"\r\n`);
    parts.push(`Content-Type: application/octet-stream\r\n\r\n`);
    const header = Buffer.from(parts.join(''));
    const footer = Buffer.from(`\r\n--${boundary}--\r\n`);
    const body = Buffer.concat([header, fileData, footer]);

    const options = {
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'http:' ? 80 : 443),
      path: parsed.pathname + parsed.search,
      method: 'POST',
      headers: {
        'Cookie': cookie,
        'X-Csrf-Token': csrfToken,
        'Content-Type': `multipart/form-data; boundary=${boundary}`,
        'Content-Length': body.length,
        'User-Agent': 'overleaf-neovim/0.1',
        'Accept': 'application/json',
      },
    };

    const req = httpModule.request(options, (res) => {
      let responseBody = '';
      res.on('data', (chunk) => { responseBody += chunk; });
      res.on('end', () => {
        resolve({ status: res.statusCode, headers: res.headers, body: responseBody });
      });
    });

    req.on('error', reject);
    req.setTimeout(60000, () => {
      req.destroy(new Error('Upload timeout'));
    });
    req.write(body);
    req.end();
  });
}

module.exports = {
  fetchProjectPage,
  normalizeCookie,
  updateCookies,
  httpPost,
  httpGet,
  httpDelete,
  httpPostMultipart,
};
