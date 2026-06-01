module AptLarder
  module Admin
    # Serves the embedded HTML/CSS/JS assets for the web UI.
    # Assets are compiled into the binary at build time via Crystal macros.
    class Handler
      HTML = {{ read_file "#{__DIR__}/../../assets/admin/index.html" }}
      JS   = {{ read_file "#{__DIR__}/../../assets/admin/app.js" }}
      CSS  = {{ read_file "#{__DIR__}/../../assets/admin/style.css" }}

      # Serves `/admin.js`, `/admin.css`, or the HTML shell for all other paths.
      # All assets are embedded at compile time — no filesystem access at runtime.
      def handle(ctx : HTTP::Server::Context) : Nil
        res = ctx.response
        case ctx.request.path
        when "/admin.js"
          res.content_type = "application/javascript"
          res.print JS
        when "/admin.css"
          res.content_type = "text/css"
          res.print CSS
        else
          res.content_type = "text/html"
          res.print HTML
        end
      end
    end
  end
end
