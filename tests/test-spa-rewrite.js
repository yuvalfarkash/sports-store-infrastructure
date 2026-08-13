const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('terraform/cloudfront/spa-rewrite.js', 'utf8');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);

function rewrite(uri, querystring = {}) {
  return context.handler({ request: { uri, querystring, headers: {} } });
}

const cases = [
  ['/products/example', '/index.html'],
  ['/cart', '/index.html'],
  ['/checkout', '/index.html'],
  ['/orders', '/index.html'],
  ['/', '/index.html'],
  ['/api/products', '/api/products'],
  ['/api', '/api'],
  ['/assets/index-abc123.js', '/assets/index-abc123.js'],
  ['/favicon.svg', '/favicon.svg'],
  ['/nested/file.json', '/nested/file.json'],
];

for (const [input, expected] of cases) {
  const querystring = { q: { value: 'kept' } };
  const result = rewrite(input, querystring);
  if (result.uri !== expected || result.querystring !== querystring) {
    throw new Error(`${input} rewrote incorrectly or lost its query string`);
  }
}

console.log('CloudFront SPA rewrite behavior validated.');
