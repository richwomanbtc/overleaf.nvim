#!/usr/bin/env node
'use strict';

const readline = require('readline');
const auth = require('./auth');
const SocketManager = require('./socket');
const { getOverleafCookie, listProfiles } = require('./chrome-cookie');

// Redirect console.log to stderr (stdout is the RPC channel)
const origLog = console.log;
console.log = (...args) => console.error('[bridge]', ...args);

let requestId = 0;
let socketManager = null;
let pendingRequests = 0;
let stdinClosed = false;

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function sendResult(id, result) {
  send({ id, result });
}

function sendError(id, code, message) {
  send({ id, error: { code, message } });
}

function sendEvent(event, data) {
  send({ event, data });
}

const handlers = {
  async ping(params) {
    return { status: 'ok' };
  },

  async listChromeProfiles(params) {
    const profiles = listProfiles();
    return { profiles };
  },

  async getCookie(params) {
    const cookie = await getOverleafCookie(params.profile);
    return { cookie };
  },

  async auth(params) {
    const { cookie } = params;
    if (!cookie) throw { code: 'MISSING_PARAM', message: 'cookie is required' };
    return await auth.fetchProjectPage(cookie);
  },

  async connect(params) {
    let { cookie, projectId } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }

    // Fetch GCLB cookie for load balancer stickiness
    cookie = await auth.updateCookies(cookie);
    console.log('Updated cookies for socket connection');

    if (socketManager) {
      socketManager.disconnect();
    }

    socketManager = new SocketManager(cookie, projectId, sendEvent);
    return await socketManager.connect();
  },

  async joinDoc(params) {
    const { docId } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId) throw { code: 'MISSING_PARAM', message: 'docId is required' };
    return await socketManager.joinDoc(docId);
  },

  async leaveDoc(params) {
    const { docId } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId) throw { code: 'MISSING_PARAM', message: 'docId is required' };
    return await socketManager.leaveDoc(docId);
  },

  async applyOtUpdate(params) {
    const { docId, op, v, content } = params;
    if (!socketManager) throw { code: 'NOT_CONNECTED', message: 'Not connected to a project' };
    if (!docId || op === undefined || v === undefined) {
      throw { code: 'MISSING_PARAM', message: 'docId, op, and v are required' };
    }
    return await socketManager.applyOtUpdate(docId, op, v, content);
  },

  async compile(params) {
    const { cookie, csrfToken, projectId } = params;
    if (!cookie || !csrfToken || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, and projectId are required' };
    }

    const compileRes = await auth.httpPost(
      `https://www.overleaf.com/project/${projectId}/compile?auto_compile=true`,
      cookie, csrfToken,
      { check: 'silent', draft: false, incrementalCompilesEnabled: true, stopOnFirstError: false }
    );

    if (compileRes.status !== 200) {
      throw { code: 'COMPILE_ERROR', message: `Compile request failed with status ${compileRes.status}` };
    }

    const parsed = JSON.parse(compileRes.body);

    // Download log if available
    const logFile = (parsed.outputFiles || []).find(f => f.path === 'output.log');
    let log = '';
    if (logFile) {
      const logUrl = `https://www.overleaf.com${logFile.url}`;
      const logRes = await auth.httpGet(logUrl, cookie);
      log = logRes.body;
    }

    return { status: parsed.status, outputFiles: parsed.outputFiles || [], log };
  },

  async downloadUrl(params) {
    const { cookie, url, fileName } = params;
    if (!cookie || !url) {
      throw { code: 'MISSING_PARAM', message: 'cookie and url are required' };
    }

    const tmpPath = require('path').join(require('os').tmpdir(), 'overleaf_' + (fileName || 'download'));
    const https = require('https');
    const fs = require('fs');

    await new Promise((resolve, reject) => {
      const parsed = new URL(url);
      https.get({
        hostname: parsed.hostname,
        path: parsed.pathname + parsed.search,
        headers: { 'Cookie': cookie },
      }, (res) => {
        const ws = fs.createWriteStream(tmpPath);
        res.pipe(ws);
        ws.on('finish', () => { ws.close(); resolve(); });
        ws.on('error', reject);
      }).on('error', reject);
    });

    return { path: tmpPath };
  },

  async downloadFile(params) {
    const { cookie, projectId, fileId, fileName } = params;
    if (!cookie || !projectId || !fileId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, projectId, and fileId are required' };
    }

    const url = `https://www.overleaf.com/project/${projectId}/file/${fileId}`;
    const tmpPath = require('path').join(require('os').tmpdir(), 'overleaf_' + (fileName || fileId));

    // Download binary file
    const https = require('https');
    const fs = require('fs');
    await new Promise((resolve, reject) => {
      const parsed = new URL(url);
      https.get({
        hostname: parsed.hostname,
        path: parsed.pathname,
        headers: { 'Cookie': cookie },
      }, (res) => {
        if (res.statusCode === 302 && res.headers.location) {
          // Follow redirect
          https.get(res.headers.location, { headers: { 'Cookie': cookie } }, (res2) => {
            const ws = fs.createWriteStream(tmpPath);
            res2.pipe(ws);
            ws.on('finish', () => { ws.close(); resolve(); });
            ws.on('error', reject);
          }).on('error', reject);
        } else {
          const ws = fs.createWriteStream(tmpPath);
          res.pipe(ws);
          ws.on('finish', () => { ws.close(); resolve(); });
          ws.on('error', reject);
        }
      }).on('error', reject);
    });

    return { path: tmpPath };
  },

  async createDoc(params) {
    const { cookie, csrfToken, projectId, name, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !name) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and name are required' };
    }
    const res = await auth.httpPost(
      `https://www.overleaf.com/project/${projectId}/doc`,
      cookie, csrfToken,
      { name, parent_folder_id: parentFolderId || null }
    );
    if (res.status !== 200) {
      throw { code: 'CREATE_FAILED', message: `Create doc failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async createFolder(params) {
    const { cookie, csrfToken, projectId, name, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !name) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and name are required' };
    }
    const res = await auth.httpPost(
      `https://www.overleaf.com/project/${projectId}/folder`,
      cookie, csrfToken,
      { name, parent_folder_id: parentFolderId || null }
    );
    if (res.status !== 200) {
      throw { code: 'CREATE_FAILED', message: `Create folder failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async renameEntity(params) {
    const { cookie, csrfToken, projectId, entityId, entityType, newName } = params;
    if (!cookie || !csrfToken || !projectId || !entityId || !entityType || !newName) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, entityId, entityType, and newName are required' };
    }
    const res = await auth.httpPost(
      `https://www.overleaf.com/project/${projectId}/${entityType}/${entityId}/rename`,
      cookie, csrfToken,
      { name: newName }
    );
    if (res.status !== 204 && res.status !== 200) {
      throw { code: 'RENAME_FAILED', message: `Rename failed: ${res.status} ${res.body}` };
    }
    return {};
  },

  async deleteEntity(params) {
    const { cookie, csrfToken, projectId, entityId, entityType } = params;
    if (!cookie || !csrfToken || !projectId || !entityId || !entityType) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, entityId, and entityType are required' };
    }
    const res = await auth.httpDelete(
      `https://www.overleaf.com/project/${projectId}/${entityType}/${entityId}`,
      cookie, csrfToken
    );
    if (res.status !== 204 && res.status !== 200) {
      throw { code: 'DELETE_FAILED', message: `Delete failed: ${res.status}` };
    }
    return {};
  },

  async uploadFile(params) {
    const { cookie, csrfToken, projectId, filePath, fileName, parentFolderId } = params;
    if (!cookie || !csrfToken || !projectId || !filePath) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and filePath are required' };
    }
    const fs = require('fs');
    if (!fs.existsSync(filePath)) {
      throw { code: 'FILE_NOT_FOUND', message: `File not found: ${filePath}` };
    }
    const folderId = parentFolderId || 'rootFolder';
    const url = `https://www.overleaf.com/project/${projectId}/upload?folder_id=${folderId}`;
    const res = await auth.httpPostMultipart(url, cookie, csrfToken, filePath, fileName);
    if (res.status !== 200) {
      throw { code: 'UPLOAD_FAILED', message: `Upload failed: ${res.status} ${res.body}` };
    }
    return JSON.parse(res.body);
  },

  async getHistory(params) {
    const { cookie, projectId, minCount } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }
    const res = await auth.httpGet(
      `https://www.overleaf.com/project/${projectId}/updates?min_count=${minCount || 15}`,
      cookie
    );
    if (res.status !== 200) {
      throw { code: 'HISTORY_FAILED', message: `History request failed: ${res.status}` };
    }
    return JSON.parse(res.body);
  },

  async getThreads(params) {
    const { cookie, projectId } = params;
    if (!cookie || !projectId) {
      throw { code: 'MISSING_PARAM', message: 'cookie and projectId are required' };
    }
    const res = await auth.httpGet(
      `https://www.overleaf.com/project/${projectId}/threads`,
      cookie
    );
    if (res.status !== 200) {
      throw { code: 'THREADS_FAILED', message: `Get threads failed: ${res.status}` };
    }
    return JSON.parse(res.body);
  },

  async addComment(params) {
    const { cookie, csrfToken, projectId, threadId, content } = params;
    if (!cookie || !csrfToken || !projectId || !threadId || !content) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, threadId, and content are required' };
    }
    const res = await auth.httpPost(
      `https://www.overleaf.com/project/${projectId}/thread/${threadId}/messages`,
      cookie, csrfToken,
      { content }
    );
    if (res.status !== 200 && res.status !== 201 && res.status !== 204) {
      throw { code: 'COMMENT_FAILED', message: `Add comment failed: ${res.status}` };
    }
    try { return JSON.parse(res.body); } catch (e) { return {}; }
  },

  async resolveThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `https://www.overleaf.com/project/${projectId}/doc/${docId}/thread/${threadId}/resolve`
      : `https://www.overleaf.com/project/${projectId}/thread/${threadId}/resolve`;
    const res = await auth.httpPost(url, cookie, csrfToken, {});
    if (res.status < 200 || res.status >= 300) {
      throw { code: 'RESOLVE_FAILED', message: `Resolve thread failed: ${res.status}` };
    }
    return {};
  },

  async reopenThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `https://www.overleaf.com/project/${projectId}/doc/${docId}/thread/${threadId}/reopen`
      : `https://www.overleaf.com/project/${projectId}/thread/${threadId}/reopen`;
    const res = await auth.httpPost(url, cookie, csrfToken, {});
    if (res.status < 200 || res.status >= 300) {
      throw { code: 'REOPEN_FAILED', message: `Reopen thread failed: ${res.status}` };
    }
    return {};
  },

  async deleteThread(params) {
    const { cookie, csrfToken, projectId, docId, threadId } = params;
    if (!cookie || !csrfToken || !projectId || !threadId) {
      throw { code: 'MISSING_PARAM', message: 'cookie, csrfToken, projectId, and threadId are required' };
    }
    const url = docId
      ? `https://www.overleaf.com/project/${projectId}/doc/${docId}/thread/${threadId}`
      : `https://www.overleaf.com/project/${projectId}/thread/${threadId}`;
    const res = await auth.httpDelete(url, cookie, csrfToken);
    if (res.status !== 200 && res.status !== 204) {
      throw { code: 'DELETE_FAILED', message: `Delete thread failed: ${res.status}` };
    }
    return {};
  },

  async disconnect() {
    if (socketManager) {
      socketManager.disconnect();
      socketManager = null;
    }
    return {};
  },
};

function maybeExit() {
  if (stdinClosed && pendingRequests === 0 && !socketManager) {
    process.exit(0);
  }
}

async function handleMessage(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    console.log('Failed to parse message:', line);
    return;
  }

  const { id, method, params } = msg;
  if (!method || id === undefined) {
    console.log('Invalid message format:', line);
    return;
  }

  const handler = handlers[method];
  if (!handler) {
    sendError(id, 'UNKNOWN_METHOD', `Unknown method: ${method}`);
    return;
  }

  pendingRequests++;
  try {
    const result = await handler(params || {});
    sendResult(id, result);
  } catch (err) {
    const code = err.code || 'INTERNAL_ERROR';
    const message = err.message || String(err);
    sendError(id, code, message);
  } finally {
    pendingRequests--;
    maybeExit();
  }
}

// stdin line reader
const rl = readline.createInterface({
  input: process.stdin,
  terminal: false,
});

rl.on('line', (line) => {
  if (line.trim()) {
    handleMessage(line.trim());
  }
});

rl.on('close', () => {
  console.log('stdin closed');
  stdinClosed = true;
  if (socketManager) {
    socketManager.disconnect();
    socketManager = null;
  }
  maybeExit();
  // Force exit after 5s if pending requests don't complete
  setTimeout(() => process.exit(0), 5000).unref();
});

process.on('SIGTERM', () => {
  console.log('SIGTERM received');
  if (socketManager) {
    socketManager.disconnect();
  }
  process.exit(0);
});

process.on('uncaughtException', (err) => {
  console.log('Uncaught exception:', err.message);
  sendEvent('error', { message: err.message });
});

console.log('Bridge started');
