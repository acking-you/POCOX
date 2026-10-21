// Preloaded only in the owned npm process. Never emits URLs, headers or bodies.
'use strict';
let bytes = 0;
let active = 0;
const emit = () => process.stdout.write(`\nPOCOX_DOWNLOAD ${bytes} ${active}\n`);
for (const name of ['node:http', 'node:https']) {
  const transport = require(name);
  const request = transport.request;
  transport.request = function (...args) {
    const req = Reflect.apply(request, this, args);
    req.prependOnceListener('response', (res) => {
      if (!/\.tgz(?:[?#]|$)/.test(req.path) || res.statusCode < 200 || res.statusCode >= 300) return;
      active++;
      emit();
      const push = res.push;
      res.push = function (chunk, encoding) {
        if (chunk != null) bytes += Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(chunk, encoding);
        return Reflect.apply(push, this, [chunk, encoding]);
      };
      let ended = false;
      const end = () => {
        if (ended) return;
        ended = true;
        active--;
        emit();
      };
      res.once('end', end);
      res.once('close', end);
    });
    return req;
  };
}
// No keepalive: npm still exits normally, including from a warm cache.
setInterval(emit, 250).unref();
process.once('exit', emit);
