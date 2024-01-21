# frozen_string_literal: true

require 'English'
require 'riemann/tools'
require 'riemann/tools/version'

# Forwards information on a Riak node to Riemann.
module Riemann
  module Tools
    class Riak
      include Riemann::Tools
      require 'net/http'
      require 'net/https'
      require 'yajl/json_gem'

      opt :riak_host, 'Riak host for stats <IP> or SSL http(s)://<IP>', default: Socket.gethostname
      opt :data_dir, 'Riak data directory', default: '/var/lib/riak'
      opt :stats_port, 'Riak HTTP port for stats', default: 8098
      opt :stats_path, 'Riak HTTP stats path', default: '/stats'
      opt :node_name, 'Riak erlang node name', default: "riak@#{Socket.gethostname}"
      opt :cookie, 'Riak cookie to use', default: 'riak'

      opt :get_50_warning, 'FSM 50% get time warning threshold (ms)', default: 1000
      opt :put_50_warning, 'FSM 50% put time warning threshold (ms)', default: 1000
      opt :get_95_warning, 'FSM 95% get time warning threshold (ms)', default: 2000
      opt :put_95_warning, 'FSM 95% put time warning threshold (ms)', default: 2000
      opt :get_99_warning, 'FSM 99% get time warning threshold (ms)', default: 10_000
      opt :put_99_warning, 'FSM 99% put time warning threshold (ms)', default: 10_000

      opt :user_agent, 'User-Agent header for HTTP requests', short: :none, default: "#{File.basename($PROGRAM_NAME)}/#{Riemann::Tools::VERSION} (+https://github.com/riemann/riemann-tools)"

      def initialize
        detect_features

        @httpstatus = true

        begin
          uri = URI.parse(opts[:riak_host])
          uri.host = opts[:riak_host] if uri.host.nil?
          http = ::Net::HTTP.new(uri.host, opts[:stats_port])
          http.use_ssl = uri.scheme == 'https'
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?
          http.start do |h|
            h.get(opts[:stats_path], { 'user-agent' => opts[:user_agent] })
          end
        rescue StandardError => _e
          @httpstatus = false
        end

        # we're going to override the emulator setting to allow users to
        # dynamically input the cookie
        # this is done only once - hopefully it doesn't get overridden.
        ENV['ERL_AFLAGS'] = "-setcookie #{opts[:cookie]}"
      end

      # Identifies whether escript and riak-admin are installed
      def detect_features
        @escript = true # Whether escript is present on this machine
        @riakadmin = true # Whether riak-admin is present

        @escript = false if `which escript` =~ /^\s*$/

        @riakadmin = false if `which riak-admin` =~ /^\s*$/
      end

      def check_ring
        str = if @escript
                `riemann-riak-ring #{opts[:node_name]}`.chomp
              elsif @riakadmin
                `riak-admin ringready`
              end

        return if str.nil?

        if str =~ /^TRUE/
          report(
            host: opts[:riak_host],
            service: 'riak ring',
            state: 'ok',
            description: str,
          )
        else
          report(
            host: opts[:riak_host],
            service: 'riak ring',
            state: 'warning',
            description: str,
          )
        end
      end

      def check_keys
        keys = `riemann-riak-keys #{opts[:node_name]}`.chomp
        if keys =~ /^\d+$/
          report(
            host: opts[:riak_host],
            service: 'riak keys',
            state: 'ok',
            metric: keys.to_i,
            description: keys,
          )
        else
          report(
            host: opts[:riak_host],
            service: 'riak keys',
            state: 'unknown',
            description: keys,
          )
        end
      end

      def check_transfers
        str = (`riak-admin transfers` if @riakadmin)

        return if str.nil?

        if str =~ /'#{opts[:node_name]}' waiting to handoff (\d+) partitions/
          report(
            host: opts[:riak_host],
            service: 'riak transfers',
            state: 'critical',
            metric: Regexp.last_match(1).to_i,
            description: "waiting to handoff #{Regexp.last_match(1)} partitions",
          )
        else
          report(
            host: opts[:riak_host],
            service: 'riak transfers',
            state: 'ok',
            metric: 0,
            description: 'No pending transfers',
          )
        end
      end

      def check_disk
        gb = `du -Ls #{opts[:data_dir]}`.split(/\s+/).first.to_i / (1024.0**2)
        report(
          host: opts[:riak_host],
          service: 'riak disk',
          state: 'ok',
          metric: gb,
          description: "#{gb} GB in #{opts[:data_dir]}",
        )
      end

      # Returns the riak stat for the given fsm type and percentile.
      def fsm_stat(type, property, percentile)
        "node_#{type}_fsm_#{property}_#{percentile == 50 ? 'median' : percentile}"
      end

      # Returns the alerts state for the given fsm.
      def fsm_state(type, percentile, val)
        limit = opts[:"#{type}_#{percentile}_warning"]
        case val
        when 0..limit
          'ok'
        when limit..limit * 2
          'warning'
        else
          'critical'
        end
      end

      # Get current stats via HTTP
      def stats_http
        begin
          uri = URI.parse(opts[:riak_host])
          uri.host = opts[:riak_host] if uri.host.nil?
          http = ::Net::HTTP.new(uri.host, opts[:stats_port])
          http.use_ssl = uri.scheme == 'https'
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?
          res = http.start do |h|
            h.get(opts[:stats_path], { 'user-agent' => opts[:user_agent] })
          end
        rescue StandardError => e
          report(
            host: opts[:riak_host],
            service: 'riak',
            state: 'critical',
            description: "error fetching #{opts[:riak_host]}:#{opts[:stats_port]} #{e.class}, #{e.message}",
          )
          raise
        end

        if res.code.to_i == 200
          JSON.parse(res.body)
        else
          report(
            host: opts[:riak_host],
            service: 'riak',
            state: 'critical',
            description: "stats returned HTTP #{res.code}:\n\n#{res.body}",
          )
          raise "Can't fetch stats via HTTP: #{res.core}:\n\n#{res.body}"
        end
      end

      # Get current stats via riak-admin
      def stats_riak_admin
        str = `riak-admin status`
        raise 'riak-admin failed' unless $CHILD_STATUS == 0

        str.split("\n").map { |i| i.split(' : ') }.to_h
      end

      # Get current stats as a hash
      def stats
        if @httpstatus
          stats_http
        elsif @riakadmin
          stats_riak_admin
        else
          report(
            host: opts[:riak_host],
            service: 'riak',
            state: 'critical',
            description: 'No mechanism for fetching Riak stats: neither HTTP nor riak-admin available.',
          )
          raise 'No mechanism for fetching Riak stats: neither HTTP nor riak-admin available.'
        end
      end

      def core_services
        %w[vnode_gets
           vnode_puts
           node_gets
           node_puts
           node_gets_set
           node_puts_set
           read_repairs]
      end

      def fsm_types
        [{ 'get' => 'time' }, { 'put' => 'time' },
         { 'get' => 'set_objsize' },]
      end

      def fsm_percentiles
        [50, 95, 99]
      end

      # Reports current stats to Riemann
      def check_stats
        begin
          stats = self.stats
        rescue StandardError => e
          event = {
            state: 'critical',
            description: e.message,
            host: opts[:riak_host],
          }
          # Report errors
          report(event.merge(service: 'riak'))
          core_services.each do |s|
            report(event.merge(service: "riak #{s}"))
          end
          fsm_types.each do |typespec|
            typespec.each do |type, prop|
              fsm_percentiles.each do |percentile|
                report(event.merge(service: "riak #{type} #{prop} #{percentile}"))
              end
            end
          end
          return
        end

        # Riak itself
        report(
          host: opts[:riak_host],
          service: 'riak',
          state: 'ok',
        )

        # Gets/puts/rr
        core_services.each do |s|
          report(
            host: opts[:riak_host],
            service: "riak #{s}",
            state: 'ok',
            metric: stats[s].to_i / 60.0,
            description: "#{stats[s].to_i / 60.0}/sec",
          )
        end

        # FSMs
        fsm_types.each do |typespec|
          typespec.each do |type, prop|
            fsm_percentiles.each do |percentile|
              val = stats[fsm_stat(type, prop, percentile)].to_i || 0
              val = 0 if val == 'undefined'
              val /= 1000.0 if prop == 'time' # Convert us to ms
              state = if prop == 'time'
                        fsm_state(type, percentile, val)
                      else
                        'ok'
                      end
              report(
                host: opts[:riak_host],
                service: "riak #{type} #{prop} #{percentile}",
                state: state,
                metric: val,
                description: "#{val} ms",
              )
            end
          end
        end
      end

      def tick
        # This can utterly destroy a cluster, so we disable
        # check_keys
        check_stats
        check_ring
        check_disk
        check_transfers
      end
    end
  end
end
