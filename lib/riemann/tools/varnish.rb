# frozen_string_literal: true

require 'open3'
require 'riemann/tools'

# Reports varnish stats to Riemann.
module Riemann
  module Tools
    class Varnish
      include Riemann::Tools

      opt :varnish_host, 'Varnish hostname', default: `hostname`.chomp

      def initialize
        super

        cmd = 'varnishstat -V'
        Open3.popen3(cmd) do |_stdin, _stdout, stderr, _wait_thr|
          @ver = /varnishstat \(varnish-(\d+)/.match(stderr.read)[1].to_i
        end

        @vstats = if @ver >= 4
                    ['MAIN.sess_conn',
                     'MAIN.sess_drop ',
                     'MAIN.client_req',
                     'MAIN.cache_hit',
                     'MAIN.cache_miss',]
                  else
                    %w[client_conn
                       client_drop
                       client_req
                       cache_hit
                       cache_miss]
                  end
      end

      def tick
        stats = if @ver >= 4
                  `varnishstat -1 -f #{@vstats.join(' -f ')}`
                else
                  `varnishstat -1 -f #{@vstats.join(',')}`
                end
        stats.each_line do |stat|
          m = stat.split
          report(
            host: opts[:varnish_host].dup,
            service: "varnish #{m[0]}",
            metric: m[1].to_f,
            state: 'ok',
            description: m[3..].join(' ').to_s,
            tags: ['varnish'],
          )
        end
      end
    end
  end
end
