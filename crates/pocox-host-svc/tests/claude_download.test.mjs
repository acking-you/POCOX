import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

const hook = fileURLToPath(new URL('../src/acp/claude_download.cjs', import.meta.url));

test('counts only received package bodies, including chunked transfers, without altering bytes', async () => {
  const server = http.createServer((req, res) => {
    if (req.url === '/package.tgz') {
      res.write(Buffer.alloc(100, 1));
      setTimeout(() => res.write(Buffer.alloc(200, 2)), 300);
      setTimeout(() => res.end(Buffer.alloc(700, 3)), 650);
    } else {
      res.statusCode = req.url === '/failed.tgz' ? 403 : 200;
      res.end('private metadata');
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  const child = spawn(process.execPath, ['--require', hook, '-e', `
    const http = require('node:http');
    (async () => {
      for (const path of ['/metadata', '/failed.tgz', '/package.tgz']) {
        await new Promise((resolve, reject) => {
          const req = http.request({host:'127.0.0.1',port:${port},path}, res => {
            const chunks=[];
            res.on('data', x => chunks.push(x));
            res.on('end', () => {
              if (path === '/package.tgz') {
                const actual = Buffer.concat(chunks);
                const expected = Buffer.concat([Buffer.alloc(100,1),Buffer.alloc(200,2),Buffer.alloc(700,3)]);
                if (!actual.equals(expected)) { process.exitCode=9; }
              }
              resolve();
            });
          });
          req.on('error',reject);req.end();
        });
      }
    })().catch(() => {process.exitCode=10;});
  `], {stdio:['ignore','pipe','pipe']});
  let output = ''; let errors = '';
  child.stdout.on('data', c => output += c);
  child.stderr.on('data', c => errors += c);
  try {
    const [code] = await once(child, 'close');
    assert.equal(code, 0, errors);
    const samples = [...output.matchAll(/^POCOX_DOWNLOAD (\d+) (\d+)$/gm)].map(m => [Number(m[1]),Number(m[2])]);
    assert.ok(samples.some(([bytes,active]) => bytes > 0 && bytes < 1000 && active === 1));
    assert.deepEqual(samples.at(-1), [1000,0]);
    assert.ok(samples.every(([n],i) => i === 0 || n >= samples[i-1][0]));
    assert.ok(!output.includes('private metadata'));
  } finally {
    child.kill();
    await new Promise(resolve => server.close(resolve));
  }
});
