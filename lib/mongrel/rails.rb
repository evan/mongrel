# Copyright (c) 2005 Zed A. Shaw 
# You can redistribute it and/or modify it under the same terms as Ruby.
#
# Additional work donated by contributors.  See http://mongrel.rubyforge.org/attributions.html 
# for more information.

require 'mongrel'


module Mongrel
  module Rails
    # Implements a handler that can run Rails and serve files out of the
    # Rails application's public directory.  This lets you run your Rails
    # application with Mongrel during development and testing, then use it
    # also in production behind a server that's better at serving the 
    # static files.
    #
    # The RailsHandler takes a mime_map parameter which is a simple suffix=mimetype
    # mapping that it should add to the list of valid mime types.
    #
    # It also supports page caching directly and will try to resolve a request
    # in the following order:
    #
    # * If the requested exact PATH_INFO exists as a file then serve it.
    # * If it exists at PATH_INFO+".html" exists then serve that.
    # * Finally, run the Rails application Rack handler.
    #
    # This means that if you are using page caching it will actually work with Mongrel
    # and you should see a decent speed boost (but not as fast as if you use a static
    # server like Apache or Litespeed).
    class RailsHandler < Mongrel::HttpHandler
      attr_reader :files
      attr_reader :guard
      @@file_only_methods = ["GET","HEAD"]

      def initialize(dir, mime_map = {})
        rails_app = Rails.respond_to?(:application) ? ::Rails.application : ActionController::Dispatcher.new
        @app = Rack::Chunked.new(Rack::ContentLength.new(rails_app))

        @files = Mongrel::DirHandler.new(dir,false)

        # Register the requested MIME types
        mime_map.each {|k,v| Mongrel::DirHandler::add_mime_type(k,v) }
      end

      # Attempts to resolve the request as follows:
      #
      # * If the requested exact PATH_INFO exists as a file then serve it.
      # * If it exists at PATH_INFO+".html" exists then serve that.
      # * Finally, construct a Mongrel::CGIWrapper and run Dispatcher.dispatch to have Rails go.
      def process(request, response)
        return if response.socket.closed?
        
        path_info = request.params[Mongrel::Const::PATH_INFO]
        rest_operator = request.params[Mongrel::Const::REQUEST_URI][/^#{Regexp.escape path_info}(;[^\?]+)/, 1].to_s
        path_info.chomp!("/")
        
        page_cached = path_info + rest_operator + ActionController::Base.page_cache_extension
        get_or_head = @@file_only_methods.include? request.params[Mongrel::Const::REQUEST_METHOD]

        if get_or_head and @files.can_serve(path_info)
          # File exists as-is so serve it up
          @files.process(request,response)
        elsif get_or_head and @files.can_serve(page_cached)
          # Possible cached page, serve it up
          request.params[Mongrel::Const::PATH_INFO] = page_cached
          @files.process(request,response)
        else
          env = {}.replace(request.params)
          env.delete "HTTP_CONTENT_TYPE"
          env.delete "HTTP_CONTENT_LENGTH"

          env["SCRIPT_NAME"] = ""  if env["SCRIPT_NAME"] == "/"

          rack_input = request.body || StringIO.new('')
          rack_input.set_encoding(Encoding::BINARY) if rack_input.respond_to?(:set_encoding)

          env.update({"rack.version" => Rack::VERSION,
                       "rack.input" => rack_input,
                       "rack.errors" => $stderr,

                       "rack.multithread" => true,
                       "rack.multiprocess" => false, # ???
                       "rack.run_once" => false,

                       "rack.url_scheme" => "http",
                     })
          env["QUERY_STRING"] ||= ""

          status, headers, body = @app.call(env)

          begin
            response.status = status.to_i
            response.send_status(nil)

            headers.each { |k, vs|
              vs.split("\n").each { |v|
                response.header[k] = v
              }
            }
            response.send_header

            body.each { |part|
              response.write part
              response.socket.flush
            }
          ensure
            body.close  if body.respond_to? :close
          end
        end
      end
    end

    # Creates Rails specific configuration options for people to use 
    # instead of the base Configurator.
    class RailsConfigurator < Mongrel::Configurator

      # Creates a single rails handler and returns it so you
      # can add it to a URI. You can actually attach it to 
      # as many URIs as you want, but this returns the 
      # same RailsHandler for each call.
      #
      # Requires the following options:
      #
      # * :docroot => The public dir to serve from.
      # * :environment => Rails environment to use.
      # * :cwd => The change to working directory
      #
      # And understands the following optional settings:
      #
      # * :mime => A map of mime types.
      #
      # Because of how Rails is designed you can only have
      # one installed per Ruby interpreter (talk to them 
      # about thread safety).  Because of this the first
      # time you call this function it does all the config
      # needed to get your Rails working.  After that
      # it returns the one handler you've configured.
      # This lets you attach Rails to any URI(s) you want,
      # but it still protects you from threads destroying
      # your handler.
      def rails(options={})

        return @rails_handler if @rails_handler

        ops = resolve_defaults(options)

        # fix up some defaults
        ops[:environment] ||= "development"
        ops[:docroot] ||= "public"
        ops[:mime] ||= {}

        ENV['RAILS_ENV'] = ops[:environment]
        env_location = "#{ops[:cwd]}/config/environment"
        require env_location

# TODO: Is there some Rails 3 equivalent
#        ActionController::AbstractRequest.relative_url_root = ops[:prefix] if ops[:prefix]

        @rails_handler = RailsHandler.new(ops[:docroot], ops[:mime])
      end
    end
  end
end
