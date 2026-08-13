function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri === '/api' || uri.indexOf('/api/') === 0 || uri.indexOf('/assets/') === 0) {
    return request;
  }

  var lastSegment = uri.substring(uri.lastIndexOf('/') + 1);
  if (lastSegment.indexOf('.') !== -1) {
    return request;
  }

  request.uri = '/index.html';
  return request;
}
