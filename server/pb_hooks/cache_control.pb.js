/// <reference path="../pb_data/types.d.ts" />

// Keep the web app fresh. PocketBase serves the Flutter bundle from pb_public
// with only a Last-Modified header, which lets browsers heuristically cache the
// entry point — so a new release wasn't picked up until a hard refresh.
//
// Force the version-determining files (the HTML shell + its bootstrap/main
// scripts) to revalidate on every load. They carry Last-Modified, so when
// unchanged this is a cheap 304; a new build changes them and the browser
// fetches fresh. Content-hashed assets and the API are left untouched.
//
// NOTE: the map is declared INSIDE the handler — PocketBase runs hook callbacks
// in an isolated VM that can't see file-scope variables.
routerUse((e) => {
  const noCache = {
    "/": true,
    "/index.html": true,
    "/flutter_bootstrap.js": true,
    "/flutter.js": true,
    "/main.dart.js": true,
    "/manifest.json": true,
  };
  // Coerce to a primitive JS string — the JSVM exposes the path as a Go-wrapped
  // value that won't match plain object keys otherwise.
  const path = String(e.request.url.path);
  if (noCache[path]) {
    e.response.header().set("Cache-Control", "no-cache");
  }
  return e.next();
});
