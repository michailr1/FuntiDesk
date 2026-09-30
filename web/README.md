# FuntiDesk Web

Static public site for `desk.funti.cc`.

Routes:
- `/` — landing page
- `/download/` — downloads
- `/docs/` — user documentation
- `/web/` — reserved for a future browser client

The site deliberately has no dependency on the desktop client build. Brand source of truth is `design/brand/`; `web/assets/funtidesk-mark.svg` is a deployable copy of approved emblem C.

## Local preview

Serve the `web/` directory with any static HTTP server. Example:

```bash
python3 -m http.server 8080 -d web
```

No build step is required.
