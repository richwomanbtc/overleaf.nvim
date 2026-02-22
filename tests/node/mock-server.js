#!/usr/bin/env node
'use strict';

/**
 * Mock Overleaf OT server for integration testing.
 *
 * Speaks the Socket.IO v0.9 wire protocol over HTTP + WebSocket,
 * matching the real Overleaf real-time server behavior:
 *   - joinProjectResponse on connect
 *   - joinDoc / leaveDoc / applyOtUpdate
 *   - Hash validation (SHA1, git-blob format)
 *   - Version tracking per document
 *   - otUpdateError on hash mismatch
 *   - Broadcasting remote ops to other clients
 */

const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');
const WebSocket = require('ws');

// ── In-memory document store ───────────────────────────────────────────
const docs = {};

function getOrCreateDoc(docId, lines) {
  if (!docs[docId]) {
    docs[docId] = {
      lines: lines || [''],
      version: 0,
      content: (lines || ['']).join('\n'),
      clients: new Set(),
    };
  }
  return docs[docId];
}

function resetDocs() {
  for (const k of Object.keys(docs)) delete docs[k];
}

function computeHash(content) {
  return crypto
    .createHash('sha1')
    .update('blob ' + content.length + '\x00' + content)
    .digest('hex');
}

function applyOps(content, ops) {
  for (const o of ops) {
    if (o.d) {
      content = content.slice(0, o.p) + content.slice(o.p + o.d.length);
    }
    if (o.i) {
      content = content.slice(0, o.p) + o.i + content.slice(o.p);
    }
  }
  return content;
}

// ── Socket.IO v0.9 wire protocol helpers ───────────────────────────────
// Packet types: 0=disconnect, 1=connect, 2=heartbeat, 5=event, 6=ack

function encodeEvent(name, args) {
  return '5:::' + JSON.stringify({ name, args });
}

function encodeAck(ackId, args) {
  // Socket.IO v0.9 ack format: 6:::<id>+<json_data>
  // Strip trailing '+' from ackId (client adds it to request data ack)
  const id = String(ackId).replace(/\+$/, '');
  return '6:::' + id + '+' + JSON.stringify(args);
}

function decodePacket(data) {
  const str = typeof data === 'string' ? data : data.toString();
  const type = parseInt(str[0], 10);

  if (type === 2) return { type: 'heartbeat' };
  if (type === 0) return { type: 'disconnect' };

  if (type === 5) {
    // Socket.IO v0.9 event format: 5:<id(+?)>:<endpoint>:<json>
    // Parse by finding colon positions (don't split - JSON may contain colons)
    const firstColon = str.indexOf(':');
    const secondColon = str.indexOf(':', firstColon + 1);
    const thirdColon = str.indexOf(':', secondColon + 1);
    const id = str.slice(firstColon + 1, secondColon).replace(/\+$/, '') || null;
    const jsonStr = str.slice(thirdColon + 1);
    if (!jsonStr) return { type: 'unknown' };
    const payload = JSON.parse(jsonStr);
    return {
      type: 'event',
      id: id,
      name: payload.name,
      args: payload.args || [],
    };
  }

  return { type: 'unknown', raw: str };
}

// ── Client connection handler ──────────────────────────────────────────
let nextClientId = 1;

class MockClient {
  constructor(ws, projectId) {
    this.ws = ws;
    this.id = nextClientId++;
    this.projectId = projectId;
    this.joinedDocs = new Set();
  }

  send(data) {
    if (this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    }
  }

  sendEvent(name, ...args) {
    this.send(encodeEvent(name, args));
  }

  sendAck(ackId, ...args) {
    this.send(encodeAck(ackId, args));
  }

  handlePacket(packet) {
    if (packet.type === 'heartbeat') {
      this.send('2::');
      return;
    }

    if (packet.type === 'event') {
      this.handleEvent(packet);
      return;
    }
  }

  handleEvent(packet) {
    const { name, args, id } = packet;

    switch (name) {
      case 'joinDoc':
        this.onJoinDoc(args, id);
        break;
      case 'leaveDoc':
        this.onLeaveDoc(args, id);
        break;
      case 'applyOtUpdate':
        this.onApplyOtUpdate(args, id);
        break;
      default:
        console.log(`[mock] Unknown event: ${name}`);
        if (id) this.sendAck(id, null);
    }
  }

  onJoinDoc(args, ackId) {
    const [docId] = args;
    const doc = getOrCreateDoc(docId);
    doc.clients.add(this);
    this.joinedDocs.add(docId);

    // Encode lines as Latin-1 (matching real Overleaf behavior)
    const encodedLines = doc.lines.map(line =>
      Buffer.from(line, 'utf-8').toString('latin1')
    );

    if (ackId) {
      // [error, lines, version, updates, ranges]
      this.sendAck(ackId, null, encodedLines, doc.version, [], {});
    }
  }

  onLeaveDoc(args, ackId) {
    const [docId] = args;
    const doc = docs[docId];
    if (doc) {
      doc.clients.delete(this);
    }
    this.joinedDocs.delete(docId);
    if (ackId) this.sendAck(ackId, null);
  }

  onApplyOtUpdate(args, ackId) {
    const [docId, update] = args;
    const doc = docs[docId];

    if (!doc) {
      this.sendEvent('otUpdateError', { doc: docId, message: 'doc not found' });
      if (ackId) this.sendAck(ackId, { message: 'doc not found' });
      return;
    }

    // Version check
    if (update.v !== doc.version) {
      this.sendEvent('otUpdateError', {
        doc: docId,
        message: `version mismatch: expected ${doc.version}, got ${update.v}`,
      });
      if (ackId) this.sendAck(ackId, { message: 'version mismatch' });
      return;
    }

    // Apply ops to document content
    const ops = update.op || [];
    let newContent;
    try {
      newContent = applyOps(doc.content, ops);
    } catch (e) {
      this.sendEvent('otUpdateError', { doc: docId, message: 'op apply failed: ' + e.message });
      if (ackId) this.sendAck(ackId, { message: 'op apply failed' });
      return;
    }

    // Hash validation
    if (update.hash) {
      const expectedHash = computeHash(newContent);
      if (update.hash !== expectedHash) {
        console.log(`[mock] Hash mismatch for ${docId}: got ${update.hash}, expected ${expectedHash}`);
        this.sendEvent('otUpdateError', {
          doc: docId,
          message: `hash mismatch: got ${update.hash.slice(0, 8)}..., expected ${expectedHash.slice(0, 8)}...`,
        });
        if (ackId) this.sendAck(ackId, { message: 'hash mismatch' });
        return;
      }
    }

    // Apply update
    doc.content = newContent;
    doc.lines = newContent.split('\n');
    doc.version++;

    // ACK to sender (no op field = own ACK)
    this.sendEvent('otUpdateApplied', { doc: docId, v: doc.version });

    // Broadcast to other clients (with op field = remote update)
    for (const client of doc.clients) {
      if (client !== this && client.joinedDocs.has(docId)) {
        client.sendEvent('otUpdateApplied', {
          doc: docId,
          op: ops,
          v: update.v, // version the op was applied at
          meta: { user_id: 'user_' + this.id },
        });
      }
    }

    if (ackId) this.sendAck(ackId, null);
  }

  cleanup() {
    for (const docId of this.joinedDocs) {
      const doc = docs[docId];
      if (doc) doc.clients.delete(this);
    }
    this.joinedDocs.clear();
  }
}

// ── HTTP + WebSocket server ────────────────────────────────────────────
const clients = new Set();
let sessionCounter = 0;
const sessions = {};

function createServer(port) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${port}`);

    // Socket.IO v0.9 handshake: GET /socket.io/1/?...
    if (url.pathname === '/socket.io/1/' || url.pathname === '/socket.io/1') {
      const sid = 'mock_' + (++sessionCounter);
      const queryStr = url.search || '';
      const projectId = url.searchParams.get('projectId') || 'test_project';
      sessions[sid] = { projectId };
      // Format: session_id:heartbeat_timeout:close_timeout:transports
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end(`${sid}:15:25:websocket`);
      return;
    }

    res.writeHead(404);
    res.end('Not found');
  });

  const wss = new WebSocket.Server({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    // Socket.IO v0.9 WebSocket path: /socket.io/1/websocket/<session_id>
    const match = req.url.match(/\/socket\.io\/1\/websocket\/([^?]+)/);
    if (!match) {
      socket.destroy();
      return;
    }

    const sid = match[1];
    const session = sessions[sid];
    if (!session) {
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      const client = new MockClient(ws, session.projectId);
      clients.add(client);

      // Send connect packet
      ws.send('1::');

      // Send joinProjectResponse (v2 scheme)
      client.sendEvent('joinProjectResponse', {
        publicId: 'mock_public_' + client.id,
        project: {
          _id: session.projectId,
          name: 'Test Project',
          rootFolder: [{
            _id: 'root_folder',
            name: 'rootFolder',
            docs: [
              { _id: 'doc_main', name: 'main.tex' },
            ],
            folders: [],
            fileRefs: [],
          }],
        },
        permissionsLevel: 'owner',
        protocolVersion: 2,
      });

      ws.on('message', (data) => {
        try {
          const packet = decodePacket(data);
          client.handlePacket(packet);
        } catch (e) {
          console.error('[mock] Error handling message:', e);
        }
      });

      ws.on('close', () => {
        client.cleanup();
        clients.delete(client);
      });
    });
  });

  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', () => {
      console.log(`[mock-server] Listening on http://127.0.0.1:${port}`);
      resolve({
        server,
        port,
        resetDocs,
        getDocs: () => docs,
        getOrCreateDoc,
        getClients: () => clients,
        close: () => new Promise((r) => {
          for (const c of clients) c.ws.close();
          clients.clear();
          server.close(r);
        }),
      });
    });
  });
}

// ── Server-side event simulation ───────────────────────────────────────

/**
 * Broadcast an event to all connected clients using positional args.
 * Socket.IO v0.9 events use positional arguments, not a single data object.
 * @param {string} name - Event name
 * @param {...any} args - Positional arguments for the event
 */
function broadcastEvent(name, ...args) {
  for (const client of clients) {
    client.sendEvent(name, ...args);
  }
}

/**
 * Simulate a history restore: removes old doc and creates a new one.
 *
 * Sequence (matches real Overleaf behavior):
 *   1. Send `removeEntity` with meta.kind='file-restore'
 *   2. Create new doc in store
 *   3. Send `reciveNewDoc` with meta.kind='file-restore' and new doc info
 *
 * Real Overleaf event signatures:
 *   removeEntity(entityId, meta)
 *   reciveNewDoc(parentFolderId, doc, meta, userId)
 *
 * @param {string} oldDocId - The doc ID being replaced
 * @param {string} newDocId - The new doc ID after restore
 * @param {string} docName - Document filename (e.g. 'main.tex')
 * @param {string} docPath - Document path (e.g. '/main.tex')
 * @param {string[]} newLines - Content lines for the restored document
 * @param {string} parentFolderId - Parent folder ID
 * @returns {Promise} Resolves after the reciveNewDoc event is sent
 */
function simulateRestore(oldDocId, newDocId, docName, docPath, newLines, parentFolderId) {
  parentFolderId = parentFolderId || 'root_folder';

  // Step 1: Send removeEntity(entityId, meta)
  broadcastEvent('removeEntity',
    oldDocId,
    { kind: 'file-restore', path: docPath }
  );

  // Step 2: Create the new doc in the store
  getOrCreateDoc(newDocId, newLines);

  // Step 3: Send reciveNewDoc(parentFolderId, doc, meta, userId) after a small delay
  return new Promise((resolve) => {
    setTimeout(() => {
      broadcastEvent('reciveNewDoc',
        parentFolderId,
        { _id: newDocId, name: docName },
        { kind: 'file-restore', path: docPath },
        'mock_user_restore'
      );
      resolve();
    }, 50);
  });
}

// If run directly, start server
if (require.main === module) {
  const port = parseInt(process.env.MOCK_PORT || '18080', 10);
  createServer(port).then((srv) => {
    // Pre-create a test doc
    getOrCreateDoc('doc_main', ['\\documentclass{article}', '\\begin{document}', 'Hello World', '\\end{document}']);
    console.log(`[mock-server] Ready with test doc (v${docs['doc_main'].version})`);
  });
}

module.exports = { createServer, getOrCreateDoc, resetDocs, broadcastEvent, simulateRestore };
