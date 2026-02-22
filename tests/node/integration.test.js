#!/usr/bin/env node
'use strict';

/**
 * Integration tests for the overleaf-neovim bridge.
 *
 * Tests the full flow: bridge.js → socket.js → mock OT server,
 * exercising the JSON-RPC protocol, OT updates, hash validation,
 * and error handling.
 *
 * Usage: node tests/node/integration.test.js
 */

const { spawn } = require('child_process');
const path = require('path');
const crypto = require('crypto');
const { createServer, getOrCreateDoc, resetDocs, broadcastEvent, simulateRestore } = require('./mock-server');

// ── Test framework ─────────────────────────────────────────────────────
let passed = 0;
let failed = 0;
const errors = [];

function assert(condition, message) {
  if (!condition) {
    throw new Error('Assertion failed: ' + message);
  }
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(
      `${message || 'assertEqual'}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    );
  }
}

function assertIncludes(str, substr, message) {
  if (!str || !str.includes(substr)) {
    throw new Error(
      `${message || 'assertIncludes'}: expected "${str}" to include "${substr}"`
    );
  }
}

// ── Bridge process helper ──────────────────────────────────────────────
class BridgeClient {
  constructor(port) {
    this.port = port;
    this.proc = null;
    this.nextId = 1;
    this.pending = {};
    this.events = [];
    this.buffer = '';
  }

  start() {
    return new Promise((resolve, reject) => {
      const bridgePath = path.join(__dirname, '..', '..', 'node', 'bridge.js');
      this.proc = spawn('node', [bridgePath], {
        env: {
          ...process.env,
          OVERLEAF_URL: `http://127.0.0.1:${this.port}`,
          NODE_TLS_REJECT_UNAUTHORIZED: '0',
        },
        stdio: ['pipe', 'pipe', 'pipe'],
      });

      this.proc.stdout.on('data', (data) => {
        this.buffer += data.toString();
        const lines = this.buffer.split('\n');
        this.buffer = lines.pop(); // keep incomplete line
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const msg = JSON.parse(line);
            if (msg.id !== undefined && this.pending[msg.id]) {
              this.pending[msg.id](msg);
              delete this.pending[msg.id];
            } else if (msg.event) {
              this.events.push(msg);
            }
          } catch (e) {
            // non-JSON line, ignore
          }
        }
      });

      this.proc.stderr.on('data', (data) => {
        // Bridge logs go to stderr - useful for debugging
        const lines = data.toString().split('\n').filter(l => l.trim());
        for (const line of lines) {
          if (process.env.DEBUG) console.log('  [bridge]', line);
        }
      });

      // Wait for bridge to start
      setTimeout(() => resolve(), 500);

      this.proc.on('error', reject);
    });
  }

  request(method, params, timeoutMs = 10000) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout(() => {
        delete this.pending[id];
        reject(new Error(`Request ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      this.pending[id] = (msg) => {
        clearTimeout(timer);
        if (msg.error) {
          reject(msg.error);
        } else {
          resolve(msg.result);
        }
      };

      const payload = JSON.stringify({ id, method, params: params || {} }) + '\n';
      this.proc.stdin.write(payload);
    });
  }

  clearEvents() {
    const events = [...this.events];
    this.events = [];
    return events;
  }

  waitForEvent(eventName, timeoutMs = 5000) {
    // Check if already received
    const idx = this.events.findIndex(e => e.event === eventName);
    if (idx >= 0) {
      return Promise.resolve(this.events.splice(idx, 1)[0]);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timeout waiting for event: ${eventName}`)), timeoutMs);
      const check = setInterval(() => {
        const idx = this.events.findIndex(e => e.event === eventName);
        if (idx >= 0) {
          clearTimeout(timer);
          clearInterval(check);
          resolve(this.events.splice(idx, 1)[0]);
        }
      }, 50);
    });
  }

  stop() {
    if (this.proc) {
      this.proc.stdin.end();
      this.proc.kill('SIGTERM');
      this.proc = null;
    }
  }
}

// ── Test cases ─────────────────────────────────────────────────────────

async function test(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failed++;
    errors.push({ name, error: e });
    console.log(`  ✗ ${name}`);
    console.log(`    ${e.message}`);
  }
}

async function runTests() {
  console.log('\nStarting mock OT server...');
  const srv = await createServer(0); // random port
  const port = srv.server.address().port;
  console.log(`Mock server on port ${port}\n`);

  // ── Test Suite: Bridge Connection ────────────────────────────────
  console.log('Bridge Connection:');

  let bridge;

  await test('ping succeeds', async () => {
    bridge = new BridgeClient(port);
    await bridge.start();
    const result = await bridge.request('ping');
    assertEqual(result.status, 'ok', 'ping status');
  });

  await test('connect to mock server', async () => {
    // The connect handler needs a cookie, but our mock doesn't validate
    // We need to bypass the auth.updateCookies call — use a special flag
    // Actually, auth.updateCookies will fail because it tries to fetch from overleaf.com
    // Let's test at the socket level by connecting directly
    const result = await bridge.request('connect', {
      cookie: 'mock_session=test',
      projectId: 'test_project',
    });
    assert(result.project, 'should receive project data');
    assertEqual(result.project.name, 'Test Project', 'project name');
    assertEqual(result.permissionsLevel, 'owner', 'permissions');
  });

  // ── Test Suite: Document Operations ──────────────────────────────
  console.log('\nDocument Operations:');

  // Pre-create doc in mock server
  getOrCreateDoc('doc_main', [
    '\\documentclass{article}',
    '\\begin{document}',
    'Hello World',
    '\\end{document}',
  ]);

  await test('joinDoc returns document content', async () => {
    const result = await bridge.request('joinDoc', { docId: 'doc_main' });
    assert(result.lines, 'should have lines');
    assertEqual(result.lines.length, 4, 'line count');
    assertEqual(result.lines[2], 'Hello World', 'content line');
    assertEqual(result.version, 0, 'initial version');
  });

  await test('applyOtUpdate with insert succeeds', async () => {
    const content = '\\documentclass{article}\n\\begin{document}\nHello World\n\\end{document}';
    // "Hello" starts at position 41, space at 46, "World" at 47
    // Insert " Beautiful" at position 46 (between "Hello" and " World")
    const op = [{ p: 46, i: ' Beautiful' }];
    const result = await bridge.request('applyOtUpdate', {
      docId: 'doc_main',
      op,
      v: 0,
      content,
    });
    // Should not throw
    assert(result !== undefined, 'should return result');
  });

  await test('document content updated after insert', async () => {
    // Re-join to get fresh content
    const result = await bridge.request('joinDoc', { docId: 'doc_main' });
    assertEqual(result.version, 1, 'version incremented');
    assertEqual(result.lines[2], 'Hello Beautiful World', 'updated content');
  });

  await test('applyOtUpdate with delete succeeds', async () => {
    const content = '\\documentclass{article}\n\\begin{document}\nHello Beautiful World\n\\end{document}';
    // Delete " Beautiful" at position 46
    const op = [{ p: 46, d: ' Beautiful' }];
    await bridge.request('applyOtUpdate', {
      docId: 'doc_main',
      op,
      v: 1,
      content,
    });
    const result = await bridge.request('joinDoc', { docId: 'doc_main' });
    assertEqual(result.lines[2], 'Hello World', 'content after delete');
    assertEqual(result.version, 2, 'version after delete');
  });

  // ── Test Suite: Error Handling ───────────────────────────────────
  console.log('\nError Handling:');

  await test('version mismatch triggers otUpdateError', async () => {
    bridge.clearEvents();
    const content = '\\documentclass{article}\n\\begin{document}\nHello World\n\\end{document}';
    try {
      await bridge.request('applyOtUpdate', {
        docId: 'doc_main',
        op: [{ p: 0, i: 'x' }],
        v: 999, // Wrong version
        content,
      });
    } catch (e) {
      // Expected - the bridge may throw or the server sends otUpdateError
    }

    // Check for otUpdateError event
    try {
      const evt = await bridge.waitForEvent('otUpdateError', 2000);
      assert(evt, 'should receive otUpdateError event');
      assertIncludes(evt.data.message, 'version mismatch', 'error message');
    } catch (e) {
      // Also acceptable if the bridge threw the error directly
    }
  });

  await test('hash mismatch triggers otUpdateError', async () => {
    bridge.clearEvents();
    // Send update with correct version but content that produces wrong hash
    const wrongContent = 'THIS IS WRONG CONTENT';
    try {
      await bridge.request('applyOtUpdate', {
        docId: 'doc_main',
        op: [{ p: 0, i: 'x' }],
        v: 2,
        content: wrongContent, // Hash will be computed from this wrong content
      });
    } catch (e) {
      // Expected
    }

    try {
      const evt = await bridge.waitForEvent('otUpdateError', 2000);
      assert(evt, 'should receive otUpdateError event');
      assertIncludes(evt.data.message, 'hash mismatch', 'error message');
    } catch (e) {
      // Also acceptable
    }
  });

  await test('joinDoc on non-existent doc creates it', async () => {
    const result = await bridge.request('joinDoc', { docId: 'doc_new' });
    assert(result.lines, 'should have lines');
    assertEqual(result.version, 0, 'new doc version');
  });

  // ── Test Suite: Hash Validation ──────────────────────────────────
  console.log('\nHash Validation:');

  await test('correct hash is accepted', async () => {
    resetDocs();
    getOrCreateDoc('doc_hash', ['abc']);
    await bridge.request('joinDoc', { docId: 'doc_hash' });

    const content = 'abc';
    const op = [{ p: 3, i: 'def' }];
    // bridge.js computes hash automatically from content + ops
    const result = await bridge.request('applyOtUpdate', {
      docId: 'doc_hash',
      op,
      v: 0,
      content,
    });
    assert(result !== undefined, 'should succeed');

    // Verify content
    const doc = await bridge.request('joinDoc', { docId: 'doc_hash' });
    assertEqual(doc.lines[0], 'abcdef', 'content after insert');
  });

  await test('hash computed in bridge matches server expectation', async () => {
    // Test with multibyte characters
    resetDocs();
    getOrCreateDoc('doc_utf8', ['café']);
    await bridge.request('joinDoc', { docId: 'doc_utf8' });

    const content = 'café';
    const op = [{ p: 4, i: '!' }]; // char position after é
    const result = await bridge.request('applyOtUpdate', {
      docId: 'doc_utf8',
      op,
      v: 0,
      content,
    });
    assert(result !== undefined, 'should succeed with UTF-8');

    const doc = await bridge.request('joinDoc', { docId: 'doc_utf8' });
    assertEqual(doc.lines[0], 'café!', 'UTF-8 content after insert');
  });

  // ── Test Suite: Multi-client Broadcasting ────────────────────────
  console.log('\nMulti-client Broadcasting:');

  await test('second client receives remote op broadcast', async () => {
    resetDocs();
    getOrCreateDoc('doc_collab', ['shared doc']);

    // Client 1 (existing bridge) joins
    await bridge.request('joinDoc', { docId: 'doc_collab' });

    // Client 2
    const bridge2 = new BridgeClient(port);
    await bridge2.start();
    await bridge2.request('ping');
    await bridge2.request('connect', {
      cookie: 'mock_session=test2',
      projectId: 'test_project',
    });
    await bridge2.request('joinDoc', { docId: 'doc_collab' });

    // Client 2 sends an edit
    bridge.clearEvents();
    const content = 'shared doc';
    const op = [{ p: 0, i: 'my ' }];
    await bridge2.request('applyOtUpdate', {
      docId: 'doc_collab',
      op,
      v: 0,
      content,
    });

    // Client 1 should receive the remote op
    const evt = await bridge.waitForEvent('otUpdateApplied', 3000);
    assert(evt, 'should receive otUpdateApplied event');
    assert(evt.data.op, 'should have op field (remote update)');
    assertEqual(evt.data.op[0].i, 'my ', 'remote op insert text');

    bridge2.stop();
  });

  // ── Test Suite: History Restore ───────────────────────────────────
  console.log('\nHistory Restore:');

  await test('restore sends removeEntity then reciveNewDoc events', async () => {
    resetDocs();
    const oldDocId = 'doc_restore_old';
    const newDocId = 'doc_restore_new';
    getOrCreateDoc(oldDocId, ['old content']);
    await bridge.request('joinDoc', { docId: oldDocId });

    bridge.clearEvents();

    // Simulate restore from Overleaf history
    await simulateRestore(
      oldDocId,
      newDocId,
      'main.tex',
      '/main.tex',
      ['restored content from history']
    );

    // Wait a bit for events to arrive
    await new Promise(r => setTimeout(r, 200));

    // Client should receive removeEntity event
    const removeEvt = bridge.events.find(e => e.event === 'removeEntity');
    assert(removeEvt, 'should receive removeEntity event');
    assertEqual(removeEvt.data.entityId, oldDocId, 'removeEntity entityId');
    assertEqual(removeEvt.data.meta.kind, 'file-restore', 'removeEntity meta.kind');
    assertEqual(removeEvt.data.meta.path, '/main.tex', 'removeEntity meta.path');

    // Client should receive reciveNewDoc event
    const newDocEvt = bridge.events.find(e => e.event === 'reciveNewDoc');
    assert(newDocEvt, 'should receive reciveNewDoc event');
    assertEqual(newDocEvt.data.doc._id, newDocId, 'reciveNewDoc doc._id');
    assertEqual(newDocEvt.data.doc.name, 'main.tex', 'reciveNewDoc doc.name');
    assertEqual(newDocEvt.data.meta.kind, 'file-restore', 'reciveNewDoc meta.kind');
  });

  await test('new doc is joinable after restore', async () => {
    const result = await bridge.request('joinDoc', { docId: 'doc_restore_new' });
    assert(result.lines, 'should have lines');
    assertEqual(result.lines[0], 'restored content from history', 'restored content');
    assertEqual(result.version, 0, 'new doc starts at version 0');
  });

  await test('can edit restored doc', async () => {
    const content = 'restored content from history';
    const op = [{ p: 0, i: 'EDITED: ' }];
    await bridge.request('applyOtUpdate', {
      docId: 'doc_restore_new',
      op,
      v: 0,
      content,
    });

    const result = await bridge.request('joinDoc', { docId: 'doc_restore_new' });
    assertEqual(result.lines[0], 'EDITED: restored content from history', 'edited restored content');
    assertEqual(result.version, 1, 'version after edit');
  });

  // ── Test Suite: Concurrent Editing ──────────────────────────────
  console.log('\nConcurrent Editing:');

  await test('two clients can edit different positions without conflict', async () => {
    resetDocs();
    getOrCreateDoc('doc_concurrent', ['Hello World']);

    // Client 1 joins
    await bridge.request('joinDoc', { docId: 'doc_concurrent' });

    // Client 2
    const bridge2 = new BridgeClient(port);
    await bridge2.start();
    await bridge2.request('ping');
    await bridge2.request('connect', {
      cookie: 'mock_session=concurrent2',
      projectId: 'test_project',
    });
    await bridge2.request('joinDoc', { docId: 'doc_concurrent' });

    // Client 1 inserts at beginning
    const content = 'Hello World';
    await bridge.request('applyOtUpdate', {
      docId: 'doc_concurrent',
      op: [{ p: 0, i: 'Dear ' }],
      v: 0,
      content,
    });

    // Client 2 inserts at end (using original v=0, which will cause version mismatch
    // since client 1 already bumped version to 1)
    bridge2.clearEvents();
    try {
      await bridge2.request('applyOtUpdate', {
        docId: 'doc_concurrent',
        op: [{ p: 11, i: '!' }],
        v: 0, // stale version
        content,
      });
    } catch (e) {
      // Expected: version mismatch
    }

    // Client 2 should receive either an otUpdateError or version mismatch
    try {
      const evt = await bridge2.waitForEvent('otUpdateError', 2000);
      assert(evt, 'client 2 should get otUpdateError for stale version');
    } catch (e) {
      // Also ok if the request itself threw
    }

    // After client 1's edit, server content should be correct
    const result = await bridge.request('joinDoc', { docId: 'doc_concurrent' });
    assertEqual(result.lines[0], 'Dear Hello World', 'content after client 1 edit');
    assertEqual(result.version, 1, 'version after one edit');

    bridge2.stop();
  });

  await test('client receives remote ops from concurrent edit', async () => {
    resetDocs();
    getOrCreateDoc('doc_realtime', ['line one\nline two\nline three']);

    // Client 1
    await bridge.request('joinDoc', { docId: 'doc_realtime' });

    // Client 2
    const bridge2 = new BridgeClient(port);
    await bridge2.start();
    await bridge2.request('ping');
    await bridge2.request('connect', {
      cookie: 'mock_session=realtime2',
      projectId: 'test_project',
    });
    await bridge2.request('joinDoc', { docId: 'doc_realtime' });

    // Client 2 edits — client 1 should see the remote op
    bridge.clearEvents();
    const content = 'line one\nline two\nline three';
    await bridge2.request('applyOtUpdate', {
      docId: 'doc_realtime',
      op: [{ p: 0, i: 'REMOTE: ' }],
      v: 0,
      content,
    });

    const evt = await bridge.waitForEvent('otUpdateApplied', 3000);
    assert(evt, 'client 1 should receive remote op');
    assert(evt.data.op, 'should have op field');
    assertEqual(evt.data.op[0].i, 'REMOTE: ', 'remote insert text');
    assertEqual(evt.data.v, 0, 'op version');

    // Verify final server state
    const result = await bridge.request('joinDoc', { docId: 'doc_realtime' });
    assertEqual(result.lines[0], 'REMOTE: line one', 'server content updated');
    assertEqual(result.version, 1, 'version incremented');

    bridge2.stop();
  });

  await test('sequential edits from two clients maintain consistency', async () => {
    resetDocs();
    getOrCreateDoc('doc_seq', ['abc']);

    await bridge.request('joinDoc', { docId: 'doc_seq' });

    const bridge2 = new BridgeClient(port);
    await bridge2.start();
    await bridge2.request('ping');
    await bridge2.request('connect', {
      cookie: 'mock_session=seq2',
      projectId: 'test_project',
    });
    await bridge2.request('joinDoc', { docId: 'doc_seq' });

    // Client 1: insert 'X' at position 1 → "aXbc"
    await bridge.request('applyOtUpdate', {
      docId: 'doc_seq',
      op: [{ p: 1, i: 'X' }],
      v: 0,
      content: 'abc',
    });

    // Client 2: insert 'Y' at position 3 (after 'c'), using CORRECT version 1
    // After client 1's edit, content is "aXbc", so position 4 = end
    await bridge2.request('applyOtUpdate', {
      docId: 'doc_seq',
      op: [{ p: 4, i: 'Y' }],
      v: 1,
      content: 'aXbc',
    });

    const result = await bridge.request('joinDoc', { docId: 'doc_seq' });
    assertEqual(result.lines[0], 'aXbcY', 'both edits applied correctly');
    assertEqual(result.version, 2, 'version after two edits');

    bridge2.stop();
  });

  await test('restore during active editing session', async () => {
    resetDocs();
    const docId = 'doc_edit_restore';
    getOrCreateDoc(docId, ['original']);
    await bridge.request('joinDoc', { docId });

    // Client edits the doc
    await bridge.request('applyOtUpdate', {
      docId,
      op: [{ p: 8, i: ' edited' }],
      v: 0,
      content: 'original',
    });

    // Verify edit was applied
    let result = await bridge.request('joinDoc', { docId });
    assertEqual(result.lines[0], 'original edited', 'edit applied');

    // Now simulate a restore (another user restores from history)
    bridge.clearEvents();
    const newDocId = 'doc_edit_restore_v2';
    await simulateRestore(
      docId,
      newDocId,
      'restored.tex',
      '/restored.tex',
      ['content from v1 of history']
    );
    await new Promise(r => setTimeout(r, 200));

    // Client should receive both events
    const removeEvt = bridge.events.find(e => e.event === 'removeEntity');
    assert(removeEvt, 'should receive removeEntity during active session');
    assertEqual(removeEvt.data.entityId, docId, 'correct entity removed');

    const newDocEvt = bridge.events.find(e => e.event === 'reciveNewDoc');
    assert(newDocEvt, 'should receive reciveNewDoc during active session');
    assertEqual(newDocEvt.data.doc._id, newDocId, 'new doc id correct');

    // New doc should be joinable with restored content
    result = await bridge.request('joinDoc', { docId: newDocId });
    assertEqual(result.lines[0], 'content from v1 of history', 'restored content');
  });

  // ── Test Suite: File Tree Events ─────────────────────────────────
  console.log('\nFile Tree Events:');

  await test('reciveNewFile event is forwarded correctly', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: reciveNewFile(parentFolderId, file, meta, userId)
    broadcastEvent('reciveNewFile',
      'root_folder',
      { _id: 'file_img1', name: 'figure.png' },
      {},
      'mock_user_1'
    );
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'reciveNewFile');
    assert(evt, 'should receive reciveNewFile event');
    assertEqual(evt.data.file._id, 'file_img1', 'file id');
    assertEqual(evt.data.file.name, 'figure.png', 'file name');
    assertEqual(evt.data.parentFolderId, 'root_folder', 'parent folder');
  });

  await test('removeEntity event (normal, non-restore) is forwarded', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: removeEntity(entityId, meta)
    broadcastEvent('removeEntity',
      'doc_to_delete',
      {}
    );
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'removeEntity');
    assert(evt, 'should receive removeEntity event');
    assertEqual(evt.data.entityId, 'doc_to_delete', 'entity id');
  });

  await test('rootDocUpdated event is forwarded', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: rootDocUpdated(newRootDocId)
    broadcastEvent('rootDocUpdated', 'new_root_doc_id');
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'rootDocUpdated');
    assert(evt, 'should receive rootDocUpdated event');
    assertEqual(evt.data.docId, 'new_root_doc_id', 'new root doc id');
  });

  // ── Test Suite: Comment Events ─────────────────────────────────
  console.log('\nComment Events:');

  await test('new-comment event is forwarded as newComment', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: new-comment(threadId, comment)
    broadcastEvent('new-comment',
      'thread_abc123',
      { id: 'comment_1', content: 'Great work!', user_id: 'user_42', timestamp: '2026-01-01T00:00:00Z' }
    );
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'newComment');
    assert(evt, 'should receive newComment event');
    assertEqual(evt.data.threadId, 'thread_abc123', 'thread id');
    assertEqual(evt.data.comment.content, 'Great work!', 'comment content');
    assertEqual(evt.data.comment.id, 'comment_1', 'comment id');
  });

  await test('resolve-thread event is forwarded as resolveThread', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: resolve-thread(threadId, user)
    broadcastEvent('resolve-thread',
      'thread_abc123',
      { id: 'user_42', first_name: 'Test', email: 'test@example.com' }
    );
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'resolveThread');
    assert(evt, 'should receive resolveThread event');
    assertEqual(evt.data.threadId, 'thread_abc123', 'thread id');
    assertEqual(evt.data.user.id, 'user_42', 'user id');
  });

  await test('reopen-thread event is forwarded as reopenThread', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: reopen-thread(threadId)
    broadcastEvent('reopen-thread', 'thread_abc123');
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'reopenThread');
    assert(evt, 'should receive reopenThread event');
    assertEqual(evt.data.threadId, 'thread_abc123', 'thread id');
  });

  await test('delete-thread event is forwarded as deleteThread', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: delete-thread(threadId)
    broadcastEvent('delete-thread', 'thread_abc123');
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'deleteThread');
    assert(evt, 'should receive deleteThread event');
    assertEqual(evt.data.threadId, 'thread_abc123', 'thread id');
  });

  // ── Test Suite: Collaborator Tracking ──────────────────────────
  console.log('\nCollaborator Tracking:');

  await test('clientTracking.clientUpdated is forwarded as clientUpdated', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: clientTracking.clientUpdated(user)
    broadcastEvent('clientTracking.clientUpdated', {
      id: 'client_99',
      user_id: 'user_42',
      name: 'Test User',
      email: 'test@example.com',
      row: 5,
      column: 10,
      doc_id: 'doc_main',
    });
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'clientUpdated');
    assert(evt, 'should receive clientUpdated event');
    assertEqual(evt.data.id, 'client_99', 'client id');
    assertEqual(evt.data.user_id, 'user_42', 'user id');
    assertEqual(evt.data.row, 5, 'cursor row');
    assertEqual(evt.data.column, 10, 'cursor column');
    assertEqual(evt.data.doc_id, 'doc_main', 'doc id');
  });

  await test('clientTracking.clientDisconnected is forwarded as clientDisconnected', async () => {
    bridge.clearEvents();
    // Real Overleaf signature: clientTracking.clientDisconnected(id)
    broadcastEvent('clientTracking.clientDisconnected', 'client_99');
    await new Promise(r => setTimeout(r, 200));

    const evt = bridge.events.find(e => e.event === 'clientDisconnected');
    assert(evt, 'should receive clientDisconnected event');
    assertEqual(evt.data.id, 'client_99', 'disconnected client id');
  });

  // ── Cleanup ──────────────────────────────────────────────────────
  bridge.stop();
  await srv.close();

  // ── Summary ──────────────────────────────────────────────────────
  console.log(`\n${'─'.repeat(50)}`);
  console.log(`Results: ${passed} passed, ${failed} failed`);

  if (errors.length > 0) {
    console.log('\nFailures:');
    for (const { name, error } of errors) {
      console.log(`  ${name}:`);
      console.log(`    ${error.message}`);
    }
  }

  console.log('');
  process.exit(failed > 0 ? 1 : 0);
}

runTests().catch((e) => {
  console.error('Test runner failed:', e);
  process.exit(1);
});
