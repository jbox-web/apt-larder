module AptLarder
  module Admin
    # Serves the embedded HTML/CSS/JS assets for the web UI.
    #
    # Everything the page loads is compiled into the binary at build time via
    # Crystal macros — the UI's own files and the two libraries it depends on
    # (see `src/assets/admin/vendor/README.md`). Nothing is read from disk at
    # runtime and nothing is fetched from a CDN: the UI works on a network
    # with no Internet access, and no third party can run code on the admin
    # origin.
    class Handler
      HTML = {{ read_file "#{__DIR__}/../../assets/admin/index.html" }}
      JS   = {{ read_file "#{__DIR__}/../../assets/admin/app.js" }}
      CSS  = {{ read_file "#{__DIR__}/../../assets/admin/style.css" }}

      JQUERY_JS      = {{ read_file "#{__DIR__}/../../assets/admin/vendor/jquery-3.7.1.min.js" }}
      DATATABLES_JS  = {{ read_file "#{__DIR__}/../../assets/admin/vendor/dataTables-2.1.8.min.js" }}
      DATATABLES_CSS = {{ read_file "#{__DIR__}/../../assets/admin/vendor/dataTables-2.1.8.min.css" }}

      # Path → {content type, body} of every asset.
      ASSETS = {
        "/"                          => {"text/html", HTML},
        "/index.html"                => {"text/html", HTML},
        "/admin.js"                  => {"application/javascript", JS},
        "/admin.css"                 => {"text/css", CSS},
        "/vendor/jquery.min.js"      => {"application/javascript", JQUERY_JS},
        "/vendor/dataTables.min.js"  => {"application/javascript", DATATABLES_JS},
        "/vendor/dataTables.min.css" => {"text/css", DATATABLES_CSS},
      }

      # Serves the asset at the request path, or 404.
      def handle(ctx : HTTP::Server::Context) : Nil
        res = ctx.response
        asset = ASSETS[ctx.request.path]?
        unless asset
          res.respond_with_status(HTTP::Status::NOT_FOUND)
          return
        end
        content_type, body = asset
        res.content_type = content_type
        res.content_length = body.bytesize
        res.print body
      end
    end
  end
end
