# Vendored browser libraries

Third-party files compiled into the binary by `src/apt_larder/admin/handler.cr`,
so the admin UI works on a network with no Internet access and never loads
code from a CDN. They are unmodified upstream builds: do not edit them.

| File | Version | License | Source | SHA-256 |
|------|---------|---------|--------|---------|
| `jquery-3.7.1.min.js` | 3.7.1 | MIT | `https://code.jquery.com/jquery-3.7.1.min.js` | `fc9a93dd241f6b045cbff0481cf4e1901becd0e12fb45166a8f17f95823f0b1a` |
| `dataTables-2.1.8.min.js` | 2.1.8 | MIT | `https://cdn.datatables.net/2.1.8/js/dataTables.min.js` | `69306f7b554a5a8ce68e8f4d6f613bdd1bcfe2df313962e7fc83cf5f6be5e085` |
| `dataTables-2.1.8.min.css` | 2.1.8 | MIT | `https://cdn.datatables.net/2.1.8/css/dataTables.dataTables.min.css` | `10587c5eacd75926baec92990840987da4a8fb66b91c8c43ac955e7b174f21b0` |

## Updating

1. Download the new build from the source above (and from a second mirror,
   e.g. jsDelivr, to cross-check the hash).
2. Replace the file, keeping the version in its name.
3. Update the `read_file` paths in `src/apt_larder/admin/handler.cr`, the
   `<link>` / `<script>` tags in `src/assets/admin/index.html`, and this table.

Verify the files against this table with:

```sh
cd src/assets/admin/vendor && sha256sum *.js *.css
```
