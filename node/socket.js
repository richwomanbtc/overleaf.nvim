'use strict';

const crypto = require('crypto');

// Monkey-patch socket.io-client v0.9 to support extraHeaders in Node.js.
// The stock v0.9 client does not send Cookie/Origin headers in its
// handshake (xmlhttprequest blocks Cookie) or WebSocket transport.
(function patchSocketIO() {
  const io = require('socket.io-client');

  // 1. Replace handshake to use Node.js https (bypasses xmlhttprequest)
  io.Socket.prototype.handshake = function (fn) {
    const self = this;
    const options = this.options;
    const extraHeaders = options.extraHeaders || {};

    const scheme = options.secure === false ? 'http:/' : 'https:/';
    const handshakeUrl = [
      scheme,
      options.host + ':' + options.port,
      options.resource,
      io.protocol,
      '?t=' + Date.now(),
    ].join('/');
    const queryStr = options.query || '';
    const fullUrl = queryStr ? handshakeUrl + '&' + queryStr : handshakeUrl;
    const parsed = new (require('url').URL)(fullUrl);

    const httpModule = parsed.protocol === 'http:' ? require('http') : require('https');
    const req = httpModule.request({
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === 'http:' ? 80 : 443),
      path: parsed.pathname + parsed.search,
      method: 'GET',
      headers: Object.assign({}, extraHeaders),
    }, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        if (res.statusCode === 200) {
          fn.apply(null, body.split(':'));
        } else {
          self.connecting = false;
          self.onError(new Error('Handshake failed: ' + res.statusCode));
        }
      });
    });
    req.on('error', (err) => { self.connecting = false; self.onError(err); });
    req.setTimeout(15000, () => req.destroy(new Error('Handshake timeout')));
    req.end();
  };

  // 2. Replace WebSocket open to pass extraHeaders
  io.Transport.websocket.prototype.open = function () {
    const query = io.util.query(this.socket.options.query);
    const WS = require('ws');
    const wsOpts = {};
    if (this.socket.options.extraHeaders) {
      wsOpts.headers = this.socket.options.extraHeaders;
    }
    this.websocket = new WS(this.prepareUrl() + query, wsOpts);

    const self = this;
    this.websocket.onopen = function () { self.onOpen(); self.socket.setBuffer(false); };
    this.websocket.onmessage = function (ev) { self.onData(ev.data); };
    this.websocket.onclose = function () { self.onClose(); self.socket.setBuffer(true); };
    this.websocket.onerror = function (e) { self.onError(e); };
    return this;
  };
})();

// Convert Unicode codepoint offset to UTF-16 code unit index.
// JS strings are UTF-16; non-BMP characters (emoji etc.) use surrogate pairs
// (2 code units per codepoint). Lua sends codepoint-based offsets, so we need
// this conversion for correct String.slice() indexing. (Fix 4)
function codepointToUtf16Offset(str, cpOffset) {
  let utf16Idx = 0;
  let cpCount = 0;
  while (cpCount < cpOffset && utf16Idx < str.length) {
    const code = str.charCodeAt(utf16Idx);
    utf16Idx += (code >= 0xD800 && code <= 0xDBFF) ? 2 : 1;
    cpCount++;
  }
  return utf16Idx;
}

class SocketManager {
  constructor(cookie, projectId, sendEvent) {
    this.cookie = cookie;
    this.projectId = projectId;
    this.sendEvent = sendEvent;
    this.socket = null;
    this.connected = false;
  }

  connect() {
    return new Promise((resolve, reject) => {
      const io = require('socket.io-client');
      const url = process.env.OVERLEAF_URL || 'https://www.overleaf.com';

      // Connect with v2 scheme (projectId in query) - used by overleaf.com
      const queryUrl = `${url}?projectId=${this.projectId}&t=${Date.now()}`;
      this.socket = io.connect(queryUrl, {
        reconnect: false,
        'force new connection': true,
        extraHeaders: {
          'Cookie': this.cookie,
          'Origin': url,
        },
      });

      const timeout = setTimeout(() => {
        reject({ code: 'TIMEOUT', message: 'Connection timeout (15s)' });
      }, 15000);

      // v2 scheme: server sends joinProjectResponse automatically
      this.socket.on('joinProjectResponse', (data) => {
        clearTimeout(timeout);
        this.connected = true;
        this._setupEventHandlers();
        resolve({
          publicId: data.publicId,
          project: data.project,
          permissionsLevel: data.permissionsLevel,
          protocolVersion: data.protocolVersion,
        });
      });

      // v1 scheme fallback: connectionAccepted (for self-hosted instances)
      this.socket.on('connectionAccepted', (_, publicId) => {
        console.log('connectionAccepted (v1), joining project...');
        this.socket.emit('joinProject', { project_id: this.projectId }, (err, project, permissionsLevel, protocolVersion) => {
          clearTimeout(timeout);
          if (err) {
            reject({ code: 'JOIN_FAILED', message: err.message || String(err) });
            return;
          }
          this.connected = true;
          this._setupEventHandlers();
          resolve({
            publicId,
            project,
            permissionsLevel,
            protocolVersion,
          });
        });
      });

      this.socket.on('connect_failed', () => {
        clearTimeout(timeout);
        reject({ code: 'CONNECT_FAILED', message: 'Socket.IO connection failed' });
      });

      this.socket.on('error', (err) => {
        clearTimeout(timeout);
        reject({ code: 'SOCKET_ERROR', message: String(err) });
      });
    });
  }

  _setupEventHandlers() {
    // Log ALL incoming socket events for debugging
    const originalOnevent = this.socket.onevent;
    this.socket.onevent = (packet) => {
      const eventName = packet.data ? packet.data[0] : 'unknown';
      if (!['clientTracking.clientUpdated'].includes(eventName)) {
        console.log('[socket event]', eventName);
      }
      originalOnevent.call(this.socket, packet);
    };

    this.socket.on('otUpdateApplied', (update) => {
      console.log('[otUpdateApplied] doc=' + (update && update.doc) + ' v=' + (update && update.v) + ' hasOp=' + !!(update && update.op));
      this.sendEvent('otUpdateApplied', update);
    });

    this.socket.on('otUpdateError', (err) => {
      console.log('[otUpdateError]', JSON.stringify(err));
      this.sendEvent('otUpdateError', err);
    });

    this.socket.on('disconnect', (reason) => {
      console.log('[disconnect] reason=' + reason);
      this.connected = false;
      this.sendEvent('disconnect', { reason: reason || 'server disconnected' });
    });

    this.socket.on('forceDisconnect', (message, delay) => {
      console.log('[forceDisconnect] message=' + message);
      this.connected = false;
      this.sendEvent('disconnect', { reason: `force disconnect: ${message}` });
    });

    // File tree events (forward for future use)
    this.socket.on('reciveNewDoc', (parentFolderId, doc, meta, userId) => {
      this.sendEvent('reciveNewDoc', { parentFolderId, doc, meta: meta || {} });
    });

    this.socket.on('reciveNewFile', (parentFolderId, file, meta, userId) => {
      this.sendEvent('reciveNewFile', { parentFolderId, file, meta: meta || {} });
    });

    this.socket.on('removeEntity', (entityId, meta) => {
      this.sendEvent('removeEntity', { entityId, meta: meta || {} });
    });

    this.socket.on('rootDocUpdated', (newRootDocId) => {
      this.sendEvent('rootDocUpdated', { docId: newRootDocId });
    });

    // Comment/thread events
    this.socket.on('new-comment', (threadId, comment) => {
      this.sendEvent('newComment', { threadId, comment });
    });

    this.socket.on('resolve-thread', (threadId, user) => {
      this.sendEvent('resolveThread', { threadId, user });
    });

    this.socket.on('reopen-thread', (threadId) => {
      this.sendEvent('reopenThread', { threadId });
    });

    this.socket.on('delete-thread', (threadId) => {
      this.sendEvent('deleteThread', { threadId });
    });

    // Collaborator tracking
    this.socket.on('clientTracking.clientUpdated', (user) => {
      this.sendEvent('clientUpdated', user);
    });

    this.socket.on('clientTracking.clientDisconnected', (id) => {
      this.sendEvent('clientDisconnected', { id });
    });
  }

  _promisifiedEmit(event, ...args) {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject({ code: 'TIMEOUT', message: `${event} timeout (10s)` });
      }, 10000);

      this.socket.emit(event, ...args, (err, ...data) => {
        clearTimeout(timeout);
        if (err) {
          console.log(`${event} error:`, JSON.stringify(err));
          reject({ code: 'EMIT_ERROR', message: err.message || String(err) });
        } else {
          resolve(data);
        }
      });
    });
  }

  async joinDoc(docId) {
    // Explicitly pass fromVersion=-1 to get full document (no incremental ops)
    const data = await this._promisifiedEmit('joinDoc', docId, -1, { encodeRanges: true });
    // data = [docLines[], version, updates, ranges]
    const [docLines, version, updates, ranges] = data;

    // Decode Latin-1 to UTF-8 (Overleaf transmits doc lines as Latin-1 encoded)
    const lines = (docLines || []).map((line) =>
      Buffer.from(line, 'latin1').toString('utf-8')
    );

    // Decode ranges if they're encoded as a JSON string
    let decodedRanges = ranges;
    if (typeof ranges === 'string') {
      try {
        decodedRanges = JSON.parse(ranges);
      } catch (e) {
        console.log('Failed to parse ranges:', e.message);
        decodedRanges = {};
      }
    }

    console.log('joinDoc ranges keys:', decodedRanges ? Object.keys(decodedRanges) : 'null');
    if (decodedRanges && decodedRanges.comments) {
      console.log('joinDoc comments count:', decodedRanges.comments.length);
      if (decodedRanges.comments.length > 0) {
        console.log('joinDoc first comment:', JSON.stringify(decodedRanges.comments[0]));
      }
    }

    return { lines, version, ranges: decodedRanges };
  }

  async leaveDoc(docId) {
    // leaveDoc is fire-and-forget (server may not send callback)
    this.socket.emit('leaveDoc', docId);
    return {};
  }

  async applyOtUpdate(docId, op, version, content) {
    const update = {
      doc: docId,
      op: op,
      v: version,
      lastV: version,
    };

    // Compute SHA1 hash on content AFTER applying ops (git blob format)
    // content param is the server_content BEFORE ops; apply ops to get new content
    if (content !== undefined && content !== null) {
      let newContent = content;
      for (const o of op) {
        // o.p is a Unicode codepoint offset from Lua; convert to UTF-16
        // index for JS String.slice() which uses UTF-16 code units (Fix 4)
        const p = codepointToUtf16Offset(newContent, o.p);
        if (o.d) {
          const dEnd = codepointToUtf16Offset(newContent, o.p + [...o.d].length);
          newContent = newContent.slice(0, p) + newContent.slice(dEnd);
        }
        if (o.i) {
          newContent = newContent.slice(0, p) + o.i + newContent.slice(p);
        }
      }
      // Use JS string length (character count) - matches Overleaf's sharejs
      update.hash = crypto
        .createHash('sha1')
        .update('blob ' + newContent.length + '\x00' + newContent)
        .digest('hex');
    }

    await this._promisifiedEmit('applyOtUpdate', docId, update);
    return {};
  }

  disconnect() {
    if (this.socket) {
      try {
        this.socket.disconnect();
      } catch (e) {
        console.log('Error during disconnect:', e.message);
      }
      this.socket = null;
      this.connected = false;
    }
  }
}

module.exports = SocketManager;
