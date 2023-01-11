# frozen_string_literal: true

require 'riemann/tools'

# Gathers load balancer statistics from Cloudant.com (shared cluster) and submits them to Riemann.
module Riemann
  module Tools
    class Cloudant
      include Riemann::Tools
      require 'net/http'
      require 'json'

      opt :cloudant_username, 'Cloudant username', type: :string, required: true
      opt :cloudant_password, 'Cloudant pasword', type: :string, required: true
      opt :user_agent, 'User-Agent header for HTTP requests', short: :none, default: "#{File.basename($PROGRAM_NAME)}/#{Riemann::Tools::VERSION} (+https://github.com/riemann/riemann-tools)"

      def tick
        json.each do |node|
          break if node['svname'] == 'BACKEND' # this is just a sum of all nodes.

          ns = "cloudant #{node['pxname']}"
          cluster_name = node['tracked'].split('.')[0] # ie: meritage.cloudant.com

          # report health of each node.
          report(
            service: ns,
            state: (node['status'] == 'UP' ? 'ok' : 'critical'),
            tags: ['cloudant', cluster_name],
          )

          # report property->metric of each node.
          node.each do |property, metric|
            next if %w[pxname svname status tracked].include?(property)

            report(
              host: node['tracked'],
              service: "#{ns} #{property}",
              metric: metric.to_f,
              state: (node['status'] == 'UP' ? 'ok' : 'critical'),
              tags: ['cloudant', cluster_name],
            )
          end
        end
      end

      def json
        http = ::Net::HTTP.new('cloudant.com', 443)
        http.use_ssl = true
        http.start do |h|
          get = ::Net::HTTP::Get.new('/api/load_balancer', { 'user-agent' => opts[:user_agent] })
          get.basic_auth opts[:cloudant_username], opts[:cloudant_password]
          h.request get
        end
        JSON.parse(http.boby)
      end
    end
  end
end
